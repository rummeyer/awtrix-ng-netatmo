# @name    Netatmo
# @desc    Netatmo Weather Station, a page per room: temperature, humidity, CO2 and the last 24 hours
# @author  Oliver Rummeyer
# @version 5.0
# @oauth   authorize=https://api.netatmo.com/oauth2/authorize token=https://api.netatmo.com/oauth2/token api=api.netatmo.com scope="read_station" auth=body
# @config  rooms   text   "Rooms"          default="Wohnzimmer:8132, Arbeitszimmer:8135, Kinderzimmer:39884, Schlafzimmer:8136, Balkon:36855" help="Module[:icon] [short|medium|long], comma separated; the icon a LaMetric icon number or an icon's name on the clock" maxlen=256
# @config  seconds number "Short"          default=5 min=2 max=30 unit=s help="How long a short page stays; medium is twice, long three times"
# @config  chart   bool   "24-hour curve" default=true help="CO2 of the last 24 hours along the bottom; temperature where there is no CO2"
# @config  every   number "Update every"   default=10 min=5 max=60 unit=min
# @config  tlow    number "Comfortable from" default=18 min=-30 max=40 unit=°C group="Temperature"
# @config  thigh   number "Comfortable to" default=24 min=-30 max=40 unit=°C group="Temperature"
# @config  clow    number "Comfortable from" default=800 min=400 max=5000 step=50 unit=ppm group="CO2"
# @config  chigh   number "Comfortable to" default=1500 min=400 max=5000 step=50 unit=ppm group="CO2"
# @config  alert   select "Notify when uncomfortable" default=off options=off,silent,sound,voice
# @config  quiet   bool   "Quiet hours"    default=false group="Quiet hours" help="Left out of the rotation between these hours; the readings keep coming"
# @config  qfrom   number "From"           default=23 min=0 max=23 unit=h group="Quiet hours"
# @config  qto     number "To"             default=8 min=0 max=23 unit=h group="Quiet hours"
# @config  tclient text   "Client ID"      default="" group="Token, on a clock without sign-in (TC001)" help="Of your app at dev.netatmo.com"
# @config  tsecret text   "Client secret"  default="" group="Token, on a clock without sign-in (TC001)"
# @config  trefresh text  "Refresh token"  default="" group="Token, on a clock without sign-in (TC001)" help="From the Token generator of your app, scope read_station; the app renews it and keeps the new one here"
import string
import json

# A page per room: its icon, the temperature and humidity beside it, CO2 under
# them, and the CO2 of the last 24 hours as a curve under the temperature in
# the page's second half, in place of the CO2 (outdoors, with no CO2, the
# temperature for the whole page),
# drawn as the Weather app draws its forecast. On a display 8 rows high, as
# the TC001's, they take turns beside the icon instead. The pages slide up one
# after the other and the app stays as long as they take. The clock signs in
# to Netatmo itself: with the clock's sign-in where it has one, as the TC002,
# or with a token from the settings that the app renews, as on the TC001. A
# room not heard from is left out.
class Netatmo
  var rooms, live, fg, t0, signed, ticks, busy, chart, missing, st, thermo, x0, answered, oa, access, expires, failed, renewing

  def init()
    self.fg = settings.get("textColor")
    if self.fg == nil self.fg = 0xFFFFFF end
    # The Weather app's temperature colours: °C and colour, interpolated between.
    self.st = [-12, 0xD977DF, -6, 0x9545BC, -1, 0x4B379C, 0, 0xFEC4FF, 4, 0x31B8DB, 10, 0x31DB8B,
               15, 0x6ED228, 21, 0xFFFF28, 27, 0xF87E27, 32, 0xCF3927, 38, 0xA12527]
    self.chart = store.get("chart")
    self.t0 = 0
    self.signed = false
    self.ticks = 0
    self.busy = false
    self.missing = ""
    self.answered = false
    # The clock's sign-in, where it has one
    try
      import oauth
      self.oa = oauth
    except ..
      self.oa = nil
    end
    self.expires = 0
    self.failed = false
    self.live = []
    # The thermometer for a room without an icon: a row per number, the leftmost pixel the highest
    # bit, then the colour of each row. 12×12 a Material Symbol (Apache 2.0), 8×8 its likeness.
    var W = 0xE8E8E8
    var R = 0xFF3020
    if height() > 8
      self.thermo = [[0x060, 0x0F0, 0x0B0, 0x0B0, 0x0B0, 0x0F0, 0x0F0, 0x1F8, 0x1F8, 0x1F8, 0x0F0, 0x060],      # device_thermostat
                     [W, W, W, W, W, W, W, R, R, R, R, R]]
    else
      self.thermo = [[0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x3C, 0x18], [W, W, W, W, R, R, R, R]]
    end
    # Where the text starts: past the 16×16 icon, or the 8×8 one on a display 8 rows high.
    self.x0 = height() > 8 ? 18 : 9
    var times = {"short": 1, "medium": 2, "long": 3}
    var short = int(store.get("seconds")) * 1000
    self.rooms = []
    for item : re.matchall("[^,]+", store.get("rooms"))
      var m = re.search("^ *([^:]*[^: ]) *(: *([^ ]*))? *(short|medium|long)?", item)
      if m != nil
        var ic = m[3] == "" ? nil : m[3]
        # A number is an icon from LaMetric's gallery, drawn from its address where the clock can (the
        # TC002), else installed on the clock under that number (the TC001); a name, an icon on the clock.
        var url = nil
        if ic != nil && re.match("^[0-9]+$", ic) != nil
          url = "https://developer.lametric.com/content/apps/icon_thumbs/" + ic
        end
        self.rooms.push({"module": m[1], "icon": ic, "url": url,
                         "ms": short * (m[4] == nil ? 1 : times[m[4]]),
                         "temp": nil, "hum": nil, "co2": nil, "co2tint": self.fg,
                         "tint": self.fg, "kind": nil, "chart": nil, "chartAt": nil, "out": nil})
      end
    end
  end

  def setup()
    if size(self.rooms) == 0
      log("Netatmo: no rooms set; open the gear button on the Apps tab")
    end
  end

  # The station every few minutes; then, one at a time, any curve older than an hour.
  def loop()
    self.signed = self.ready()
    if !self.signed || self.busy return end
    self.ticks -= 1
    if self.ticks <= 0
      self.ticks = int(store.get("every")) * 60
      self.busy = self.get("https://api.netatmo.com/api/getstationsdata?get_favorites=false",
                            / b, s -> self.on_stations(b, s), {'cap': 65536})
      if !self.busy self.ticks = 5 end           # waiting for the token: again in a moment
      return
    end
    if !self.chart || epoch_ms() < 0 return end
    for r : self.rooms
      if r["kind"] != nil && (r["chartAt"] == nil || now_ms() - r["chartAt"] > 3600000)
        r["chartAt"] = now_ms()
        var url = "https://api.netatmo.com/api/getmeasure?scale=1hour&optimize=true&real_time=true" +
                  "&type=" + r["kind"] + "&device_id=" + string.replace(r["device"], ":", "%3A") +
                  "&date_begin=" + str(epoch_ms() / 1000 - 86400)
        if r["id"] != nil url += "&module_id=" + string.replace(r["id"], ":", "%3A") end
        self.busy = self.get(url, / b, s -> self.on_chart(r, b, s), {'cap': 16384})
        if !self.busy r["chartAt"] = nil end
        return
      end
    end
  end

  # Signed in: by the clock, or a token in the settings.
  def ready()
    if self.oa != nil return self.oa.ready() end
    return store.get("tclient") != "" && store.get("tsecret") != "" && store.get("trefresh") != ""
  end

  # A GET to Netatmo: through the clock's sign-in, or with the token, renewed first when it is about
  # to run out or was refused.
  def get(url, cb, opts)
    if self.oa != nil return self.oa.get(url, cb, opts) != false end
    if self.access == nil || now_ms() > self.expires
      if self.renewing return false end                  # one renewal at a time
      self.renewing = true
      self.renew(def (ok)
        self.renewing = false
        if ok self.fetch(url, cb, opts) else cb(nil, 401) end
      end)
    else
      self.fetch(url, cb, opts)
    end
    return true
  end

  def fetch(url, cb, opts)
    opts["headers"] = {"Authorization": "Bearer " + self.access}
    http.get(url, def (b, s)
      if s == 401 || s == 403 self.access = nil end
      cb(b, s)
    end, opts)
  end

  # A new access token for the refresh token; Netatmo hands out a new refresh token with it, which
  # replaces the old one in the settings.
  def renew(done)
    var body = "grant_type=refresh_token&refresh_token=" + self.enc(store.get("trefresh")) +
               "&client_id=" + self.enc(store.get("tclient")) + "&client_secret=" + self.enc(store.get("tsecret"))
    http.post("https://api.netatmo.com/oauth2/token", body, def (b, s)
      var j = s == 200 && b != nil ? json.load(b) : nil
      if j != nil && j.find("access_token") != nil
        self.access = j["access_token"]
        self.expires = now_ms() + (int(j.find("expires_in", 10800)) - 300) * 1000
        var fresh = j.find("refresh_token")
        if fresh != nil && fresh != store.get("trefresh") store.set("trefresh", fresh) end
        if self.failed log("Netatmo: token renewed") end
        self.failed = false
        done(true)
      elif s == 400 || s == 401 || s == 403
        # Said once, until it works again
        if !self.failed log("Netatmo: the token was refused (" + str(s) + "); make a new one at dev.netatmo.com") end
        self.failed = true
        done(false)
      else
        # No answer, as without Wi-Fi or memory for the connection: the token is still good.
        log("Netatmo: no answer renewing the token (" + str(s) + "); trying again")
        done(false)
      end
    end, {"headers": {"Content-Type": "application/x-www-form-urlencoded"}})
  end

  # A value for a form body: letters, digits and -._~ as they are, everything else as %XX.
  def enc(v)
    var out = ""
    for i : 0 .. size(v) - 1
      var c = v[i]
      if re.match("[A-Za-z0-9._~-]", c) != nil
        out += c
      else
        out += string.format("%%%02X", string.byte(c))
      end
    end
    return out
  end

  # getstationsdata: every module of every station, the rooms' readings taken out of it.
  def on_stations(body, status)
    self.busy = false
    if status != 200 || body == nil
      self.ticks = 60                          # again in a minute
      return
    end
    if string.find(body, '"devices"') < 0 return end
    self.answered = true
    for r : self.rooms r["seen"] = false end
    var names = []
    # Taken out of the answer's text module by module rather than with json.load(), whose whole
    # tree a clock with little memory, as the TC001, cannot spare. A module's part runs from its
    # "_id" to the next one's: a station first, then its modules.
    var device = nil
    var at = string.find(body, '"_id":"')
    while at >= 0
      var next = string.find(body, '"_id":"', at + 7)
      var part = body[at .. (next < 0 ? size(body) : next) - 1]
      at = next
      var id = re.search('^"_id":"([^"]*)"', part)
      var kind = re.search('"type":"([A-Za-z0-9]*)"', part)
      var name = re.search('"module_name":"([^"]*)"', part)
      if id == nil || kind == nil || name == nil continue end
      if kind[1] == "NAMain" device = id[1] end
      var mod = name[1]
      if string.find(mod, "\\") >= 0 mod = json.load('"' + mod + '"') end     # \u00fc and the like
      names.push(mod)
      var t = re.search('"Temperature":(-?[0-9.]+)', part)
      if t == nil continue end
      var data = {"Temperature": real(t[1])}
      var h = re.search('"Humidity":([0-9.]+)', part)
      var c = re.search('"CO2":([0-9.]+)', part)
      if h != nil data["Humidity"] = real(h[1]) end
      if c != nil data["CO2"] = real(c[1]) end
      for r : self.rooms
        if r["module"] != mod continue end
        r["device"] = device
        r["id"] = kind[1] == "NAMain" ? nil : id[1]
        r["seen"] = true
        self.reading(r, data, kind[1] == "NAModule1")
      end
    end
    # Out of reach, or not on the account: no page rather than an old one.
    var gone = []
    for r : self.rooms
      if !r["seen"]
        r["temp"] = nil
        gone.push(r["module"])
      end
    end
    # Said in the log once, until it changes: what is missing, and what the station has.
    var missing = size(gone) == 0 ? "" : gone.concat(", ") + " not found; the station has " + names.concat(", ")
    if missing != self.missing
      self.missing = missing
      log(missing == "" ? "Netatmo: every room found" : "Netatmo: " + missing)
    end
    if size(names) > 0
      shared.set("modules", names.concat(", "))
    end
  end

  # getmeasure: the last 24 hours of CO2 or temperature, as the curve's columns: each one's top
  # row, its colour and that colour dimmed for the area under it.
  def on_chart(r, body, status)
    self.busy = false
    if status != 200 || body == nil
      r["chartAt"] = now_ms() - 3300000        # again in five minutes
      return
    end
    var j = json.load(body)
    var vals = []
    for seg : (j == nil ? [] : j.find("body", []))
      for v : seg.find("value", [])
        if size(v) > 0 && v[0] != nil vals.push(real(v[0])) end
      end
    end
    while size(vals) > 24 vals.remove(0) end
    if size(vals) < 2 return end
    var lo = vals[0]
    var hi = vals[0]
    for v : vals
      lo = min(lo, v)
      hi = max(hi, v)
    end
    var n = size(vals)
    var co2 = r["kind"] == "co2"
    var bottom = height() - 1
    var span = 7                      # rows 8-15 under the temperature, or the whole 8 rows
    var w = width() - self.x0
    var rows = []
    var edge = []
    var fill = []
    var i = 0
    for x : 0 .. w - 1
      # Between the hours either side of this column
      var at = x * (n - 1) * 1.0 / (w - 1)
      i = int(at)
      if i >= n - 1 i = n - 2 end
      var v = vals[i] + (vals[i + 1] - vals[i]) * (at - i)
      rows.push(bottom - (hi == lo ? span / 2 : int((v - lo) * span / (hi - lo) + 0.5)))     # highest at the top
      var c = co2 ? self.co2colour(v) : self.colour(v)
      edge.push(c)
      fill.push(rgb(((c >> 16) & 255) * 30 / 100, ((c >> 8) & 255) * 30 / 100, (c & 255) * 30 / 100))
    end
    r["chart"] = [rows, edge, fill]
  end

  # A temperature's colour on the Weather app's scale.
  def colour(v)
    var s = self.st
    if v <= s[0] return s[1] end
    var j = 0
    while j < 20 && v >= s[j + 2] j += 2 end
    if j >= 20 return s[21] end
    var a = s[j + 1]
    var b = s[j + 3]
    var fr = (v - s[j]) * 1.0 / (s[j + 2] - s[j])
    return rgb(int(((a >> 16) & 255) + (((b >> 16) & 255) - ((a >> 16) & 255)) * fr),
               int(((a >> 8) & 255) + (((b >> 8) & 255) - ((a >> 8) & 255)) * fr),
               int((a & 255) + ((b & 255) - (a & 255)) * fr))
  end

  # A CO2 level's colour: green below the comfort zone, yellow in it, red above, as the LaMetric's leaf.
  def co2colour(c)
    return c < store.get("clow") ? 0x30C050 : (c > store.get("chigh") ? 0xFF3020 : 0xFFD000)
  end

  # A room's readings as they come: texts, colours and comfort worked out here, never in draw().
  def reading(r, data, outdoor)
    var t = data.find("Temperature")
    var h = data.find("Humidity")
    var c = data.find("CO2")
    var out = false
    var tint = self.fg
    if outdoor
      # The rooms' comfort zone means nothing outside: frost is blue, heat red.
      tint = t < 0 ? 0x2E9BFF : (t > 30 ? 0xFF3020 : self.fg)
    else
      out = t < store.get("tlow") || t > store.get("thigh")
      tint = t < store.get("tlow") ? 0x2E9BFF : (t > store.get("thigh") ? 0xFF3020 : self.fg)
    end
    var why = string.format("%.1f°", real(t))
    if settings.get("useCelsius") == false t = t * 1.8 + 32 end
    r["temp"] = string.format("%.1f°", real(t))
    r["tint"] = tint
    r["hum"] = h == nil ? nil : str(round(h)) + "%"
    r["co2"] = nil
    if c != nil && !outdoor
      r["co2tint"] = self.co2colour(c)
      r["co2"] = str(round(c))
      if c > store.get("chigh")
        out = true
        why = str(round(c)) + " ppm CO2"
      end
    end
    # The curve of what the page shows: CO2, or the temperature without it; a new one when that changes.
    var kind = r["co2"] != nil ? "co2" : "temperature"
    if kind != r["kind"]
      r["kind"] = kind
      r["chart"] = nil
      r["chartAt"] = nil
    end
    # Only a turn for the worse is news; the first reading after a start is not.
    var how = store.get("alert")
    if r["out"] == false && out && how != "off"
      var spec = {"text": r["module"] + " " + why, "textColor": 0xFF3020}
      var tune = {"rtttl": "alert:d=8,o=6,b=160:e,c,e,c"}
      if how == "sound"
        spec["sound"] = tune
      elif how == "voice"
        spec["sound"] = [{"speech": r["module"] + " is uncomfortable: " + why}, tune]
      end
      notify(spec)
    end
    r["out"] = out
  end

  # Within the quiet hours from the settings, across midnight too; never before the clock knows the time.
  def quiet()
    if !store.get("quiet") || epoch_ms() < 0 return false end
    var h = hour()
    var f = int(store.get("qfrom"))
    var t = int(store.get("qto"))
    return f > t ? (h >= f || h < t) : (h >= f && h < t)
  end

  def should_show()
    if self.quiet() return false end
    self.live = []
    for r : self.rooms
      if r["temp"] != nil self.live.push(r) end
    end
    # Until the station's first answer, as just after a restart, it says it is asked rather than
    # leave the rotation without the app for a round.
    return !self.signed || !self.answered || size(self.live) > 0
  end

  def duration()
    if !self.signed return 0 end
    var ms = 0
    for r : self.live ms += self.page(r) end
    return ms
  end

  # Brought up straight, as by the API or the menu, the rotation has not asked should_show().
  def on_show()
    self.should_show()
    self.t0 = now_ms()
  end

  def draw()
    clear()
    if !self.signed
      font("small")
      scroll_text(self.oa != nil ? "Netatmo: sign in in the app settings" : "Netatmo: set the token in the app settings", self.fg)
      return
    end
    var n = size(self.live)
    if n == 0
      # Brought up without the rotation asking should_show() or on_show(): pick the rooms now.
      self.on_show()
      n = size(self.live)
      if n == 0
        if !self.answered
          font("small")
          scroll_text(self.failed ? "Netatmo: token refused, make a new one at dev.netatmo.com" : "Netatmo: asking the station", self.fg)
        end
        return
      end
    end
    # The rotation keeps the app a moment past its time: the last page stays rather than the first
    # coming back for it. Kept on longer, as the only app, it rounds again from the first room.
    var d = self.duration()
    var el = (now_ms() - self.t0) % (d + 3000)
    if el >= d el = d - 1 end
    var i = 0
    var start = 0
    while i < n - 1 && el >= start + self.page(self.live[i])
      start += self.page(self.live[i])
      i += 1
    end
    var ph = el - start
    var h = height()
    if i > 0 && ph < 300
      var dy = h - ph * h / 300
      self.show(self.live[i - 1], dy - h, self.page(self.live[i - 1]) - 1)
      self.show(self.live[i], dy, 0)
    else
      self.show(self.live[i], 0, ph)
    end
  end

  # What a room shows one after the other on a display 8 rows high.
  def parts(r)
    var parts = ["temp"]
    if r["hum"] != nil parts.push("hum") end
    if r["co2"] != nil parts.push("co2") end
    if self.chart && r["chart"] != nil parts.push("curve") end
    return parts
  end

  # How long a room's page stays: its time from the settings, or 8 rows high, half of it for each
  # thing it shows.
  def page(r)
    return height() > 8 ? r["ms"] : r["ms"] * size(self.parts(r)) / 2
  end

  # One room, dy rows down, ph ms into its page.
  def show(r, dy, ph)
    self.picture(r, dy)
    font("small")
    if height() > 8
      # CO2 giving way to the curve in the 0.8 s around the page's middle
      var q = (ph - r["ms"] / 2 + 400) / 800.0
      self.paint(r, dy, q < 0 ? 0.0 : (q > 1 ? 1.0 : q))
    else
      self.paint_small(r, dy, ph)
    end
  end

  # The room's icon, from LaMetric or the clock; the thermometer without one, or when it is missing.
  # The clock fills a square as high as the display with a still one from an address, and plays an
  # animated one at its own size in the middle of that square.
  def picture(r, dy)
    if r["url"] != nil && icon(r["url"], 0, dy) return end
    if r["icon"] != nil && icon(r["icon"], 0, dy) return end
    var rows = self.thermo[0]
    var colours = self.thermo[1]
    var n = size(rows)
    var o = n > 8 ? (16 - n) / 2 : 0       # a 12×12 icon in the middle of the 16×16 square
    var left = 1 << (n - 1)
    var y = 0
    while y < n
      var bits = rows[y]
      if bits != 0
        var x = 0
        while x < n
          if bits & (left >> x) pixel(o + x, dy + o + y, colours[y]) end
          x += 1
        end
      end
      y += 1
    end
  end

  # The last 24 hours, dy rows lower: a bright edge, the area under it dim.
  def curve(r, dy)
    var ch = r["chart"]
    var bottom = height() - 1
    var rows = ch[0]
    var m = size(rows)
    var j = 0
    while j < m
      var y = rows[j] + dy
      pixel(self.x0 + j, y, ch[1][j])
      if rows[j] < bottom rect_fill(self.x0 + j, y + 1, 1, bottom - rows[j], ch[2][j]) end
      j += 1
    end
  end

  # 8 rows high: beside the icon one thing at a time, temperature, humidity, CO2 and the curve,
  # each for half the room's time; each slides down out of sight in its last 0.5 s, and the next
  # comes up from the bottom in its first.
  def paint_small(r, dy, ph)
    var parts = self.parts(r)
    var k = size(parts)
    var share = r["ms"] / 2
    var s = min(ph / share, k - 1)
    var into = ph - s * share
    var off = 0
    if s < k - 1 && share - into < 500
      off = (500 - (share - into)) * 9 / 500
    elif s > 0 && into < 500
      off = 8 - into * 8 / 500
    end
    var what = parts[s]
    if what == "curve"
      self.curve(r, dy + off)
      return
    end
    var txt = r["temp"] == nil ? "--" : r["temp"]      # gone while on screen
    var c = r["tint"]
    if what == "hum"
      txt = r["hum"]
      c = 0x31B8DB
    elif what == "co2"
      txt = r["co2"]
      c = r["co2tint"]
      if text_width(txt + "ppm") <= width() - self.x0 txt += "ppm" end
    end
    text(self.x0 + max(0, (width() - self.x0 - text_width(txt) + 1) / 2), dy + off + 6, txt, c)
  end

  # 16 rows high: temperature and humidity, under them CO2 giving way to the curve as q goes from
  # 0 to 1, or the curve alone without CO2.
  def paint(r, dy, q)
    var top = 2 + dy                         # two rows above the text, beside the middle of the icon
    var x0 = self.x0
    var t = r["temp"] == nil ? "--" : r["temp"]      # gone while on screen
    var x = x0 + text(x0, top + 5, t, r["tint"])
    if r["hum"] != nil text(x + 3, top + 5, r["hum"], 0x31B8DB) end
    var ch = r["chart"]
    if !self.chart || ch == nil q = 0.0 end
    if r["co2"] == nil q = 1.0 end
    # CO2 slides down out of sight in the first half, the curve up from the bottom in the second.
    if r["co2"] != nil && q < 0.5
      var down = int(q * 22)
      x = x0 + text(x0, top + 11 + down, r["co2"], r["co2tint"])
      text(x + 2, top + 11 + down, "ppm", r["co2tint"])
    end
    if ch != nil && q >= 0.5 self.curve(r, dy + int((1 - q) * 20)) end
  end
end
return Netatmo()
