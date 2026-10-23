# @name    Netatmo
# @desc    Netatmo Weather Station, a page per room: temperature, humidity, CO2 and the last 24 hours
# @author  Oliver Rummeyer
# @version 6.2
# @oauth   authorize=https://api.netatmo.com/oauth2/authorize token=https://api.netatmo.com/oauth2/token api=api.netatmo.com scope="read_station" auth=body
# @icons   living-on, stove, meal, pctvon, bear, bed, showerflow, door, box, plant-watering
# @config  rooms   text   "Rooms"          default="Wohnzimmer:living-on, Küche:stove, Esszimmer:meal, Arbeitszimmer:pctvon, Kinderzimmer:bear, Schlafzimmer:bed, Badezimmer:showerflow, Flur:door, Keller:box, Balkon:plant-watering" help="Module[:icon] [short|medium|long], comma separated; the icon a LaMetric icon number or an icon's name on the clock" maxlen=256
# @config  seconds number "Short"          default=5 min=2 max=30 unit=s help="How long a short page stays; medium is twice, long three times"
# @config  chart   bool   "24-hour curve" default=true help="CO2 of the last 24 hours along the bottom; temperature where there is no CO2"
# @config  every   number "Update every"   default=10 min=5 max=60 unit=min
# @config  clow    number "Comfortable from" default=800 min=400 max=5000 step=50 unit=ppm group="CO2"
# @config  chigh   number "Comfortable to" default=1500 min=400 max=5000 step=50 unit=ppm group="CO2"
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
# room not heard from is left out. Written for little memory, as the TC001's:
# few methods, a room an object rather than a map, a curve a number a column.

# A room: what the settings say, the readings as they come, and the curve, a number per column with
# its top row in the bits above 24 and its colour below. temp, hum and co2u are pieces for text(),
# the value white and its unit grey; co2 is the number alone. parts are what it shows one after the
# other 8 rows high, 0 temperature, 1 humidity, 2 CO2 and 3 the curve; page is how long it stays;
# wait since when its icon has been on its way, 0 once it has come.
class Room
  var module, icon, url, ms, temp, hum, co2, co2u, kind, chart, chartAt, seen, device, id, parts, page, wait
end

class Netatmo
  var rooms, live, total, fg, t0, signed, ticks, busy, chart, missing, st, thermo, x0, err, oa, access, expires, failed, renewing

  def init()
    self.fg = settings.get("textColor")
    if self.fg == nil self.fg = 0xFFFFFF end
    # The Weather app's temperature colours: °C and colour, interpolated between.
    self.st = [-12, 0xD977DF, -6, 0x9545BC, -1, 0x4B379C, 0, 0xFEC4FF, 4, 0x31B8DB, 10, 0x31DB8B,
               15, 0x6ED228, 21, 0xFFFF28, 27, 0xF87E27, 32, 0xCF3927, 38, 0xA12527]
    self.chart = store.get("chart")
    self.t0 = 0
    self.total = 0
    self.signed = false
    self.ticks = 0
    self.busy = false
    self.missing = ""
    self.err = false
    # The clock's sign-in, where it has one
    try
      import oauth
      self.oa = oauth
    except ..
      self.oa = nil
    end
    self.expires = 0
    self.failed = false
    self.renewing = false
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
    # Where the text starts: past the 16×16 icon and a gap, or past the 8×8 one and a dark column on
    # a display 8 rows high, where it is centred in the columns left.
    self.x0 = height() > 8 ? 18 : 9
    var times = {"short": 1, "medium": 2, "long": 3}
    var short = int(store.get("seconds")) * 1000
    self.rooms = []
    for item : re.matchall("[^,]+", store.get("rooms"))
      # The name up to the icon or a closing short, medium or long, so a room without an icon can have
      # a page length too; names may have spaces.
      var m = re.search("^ *([^:]*?[^: ]) *(: *([^ ]*))? *(short|medium|long)? *$", item)
      if m != nil
        var r = Room()
        r.module = m[1]
        r.icon = m[3] == "" ? nil : m[3]
        # A number is an icon from LaMetric's gallery, drawn from its address where the clock can (the
        # TC002), else installed on the clock under that number (the TC001); a name, an icon on the clock.
        if r.icon != nil && re.match("^[0-9]+$", r.icon) != nil
          r.url = "https://developer.lametric.com/content/apps/icon_thumbs/" + r.icon
        end
        r.ms = short * (m[4] == nil ? 1 : times[m[4]])
        r.parts = [0]
        r.page = r.ms
        self.rooms.push(r)
      end
    end
    if size(self.rooms) == 0 log("Netatmo: no rooms set; open the gear button on the Apps tab") end
  end

  # The station every few minutes; then, one at a time, any curve older than an hour. Signed in by
  # the clock, or with a token in the settings.
  def loop()
    self.signed = self.oa != nil ? self.oa.ready() :
                  store.get("tclient") != "" && store.get("tsecret") != "" && store.get("trefresh") != ""
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
      if r.kind != nil && (r.chartAt == nil || now_ms() - r.chartAt > 3600000)
        r.chartAt = now_ms()
        var url = "https://api.netatmo.com/api/getmeasure?scale=1hour&optimize=true&real_time=true" +
                  "&type=" + r.kind + "&device_id=" + string.replace(r.device, ":", "%3A") +
                  "&date_begin=" + str(epoch_ms() / 1000 - 86400)
        if r.id != nil url += "&module_id=" + string.replace(r.id, ":", "%3A") end
        self.busy = self.get(url, / b, s -> self.on_chart(r, b, s), {'cap': 16384})
        if !self.busy r.chartAt = nil end
        return
      end
    end
  end

  # A GET to Netatmo: through the clock's sign-in, or with the token, renewed first when it is about
  # to run out or was refused. Netatmo hands out a new refresh token with each new access token,
  # which replaces the old one in the settings.
  def get(url, cb, opts)
    if self.oa != nil return self.oa.get(url, cb, opts) != false end
    if self.access == nil || now_ms() > self.expires
      if self.renewing return false end                  # one renewal at a time
      self.renewing = true
      # The form body: letters, digits and -._~ as they are, everything else as %XX.
      var body = ""
      for kv : [["grant_type=", nil], ["&refresh_token=", "trefresh"], ["&client_id=", "tclient"], ["&client_secret=", "tsecret"]]
        body += kv[0]
        var v = kv[1] == nil ? "refresh_token" : store.get(kv[1])
        for i : 0 .. size(v) - 1
          var c = v[i]
          body += re.match("[A-Za-z0-9._~-]", c) != nil ? c : string.format("%%%02X", string.byte(c))
        end
      end
      http.post("https://api.netatmo.com/oauth2/token", body, def (b, s)
        self.renewing = false
        var j = s == 200 && b != nil ? json.load(b) : nil
        if j != nil && j.find("access_token") != nil
          self.access = j["access_token"]
          self.expires = now_ms() + (int(j.find("expires_in", 10800)) - 300) * 1000
          var fresh = j.find("refresh_token")
          if fresh != nil && fresh != store.get("trefresh") store.set("trefresh", fresh) end
          if self.failed log("Netatmo: token renewed") end
          self.failed = false
          self.get(url, cb, opts)
          return
        elif s == 400 || s == 401 || s == 403
          # Said once, until it works again
          if !self.failed log("Netatmo: the token was refused (" + str(s) + "); make a new one at dev.netatmo.com") end
          self.failed = true
        else
          # No answer, as without Wi-Fi or memory for the connection: the token is still good.
          log("Netatmo: no answer renewing the token (" + str(s) + "); trying again")
        end
        cb(nil, 401)
      end, {"headers": {"Content-Type": "application/x-www-form-urlencoded"}})
      return true
    end
    opts["headers"] = {"Authorization": "Bearer " + self.access}
    http.get(url, def (b, s)
      if s == 401 || s == 403 self.access = nil end
      cb(b, s)
    end, opts)
    return true
  end

  # getstationsdata: every module of every station, the rooms' readings taken out of it, with their
  # texts worked out here, never in draw().
  def on_stations(body, status)
    self.busy = false
    # No answer, or the token refused: the readings stay as they were, a red dot says so, and it
    # asks again in a minute.
    self.err = true
    if status != 200 || body == nil
      self.ticks = 60
      return
    end
    if string.find(body, '"devices"') < 0 return end
    self.err = false
    for r : self.rooms r.seen = false end
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
      if string.find(mod, "\\") >= 0 mod = json.load('"' + mod + '"') end     # ü and the like
      names.push(mod)
      var m = re.search('"Temperature":(-?[0-9.]+)', part)
      if m == nil continue end
      var t = real(m[1])
      m = re.search('"Humidity":([0-9.]+)', part)
      var h = m == nil ? nil : real(m[1])
      m = re.search('"CO2":([0-9.]+)', part)
      var c = m == nil ? nil : real(m[1])
      var outdoor = kind[1] == "NAModule1"
      for r : self.rooms
        if r.module != mod continue end
        r.device = device
        r.id = kind[1] == "NAMain" ? nil : id[1]
        r.seen = true
        var G = 0x909090
        r.temp = [[string.format("%.1f", settings.get("useCelsius") == false ? t * 1.8 + 32 : t), self.fg], ["°", G]]
        r.hum = h == nil ? nil : [[str(round(h)), self.fg], ["%", G]]
        r.co2 = nil
        if c != nil && !outdoor
          r.co2 = str(round(c))
          r.co2u = [[r.co2, self.fg], ["ppm", G]]
        end
        # The curve of what the page shows: CO2, or the temperature without it; a new one when that
        # changes.
        var k = r.co2 != nil ? "co2" : "temperature"
        if k != r.kind
          r.kind = k
          r.chart = nil
          r.chartAt = nil
        end
      end
    end
    # Out of reach, or not on the account: no page rather than an old one.
    var gone = []
    for r : self.rooms
      if !r.seen
        r.temp = nil
        gone.push(r.module)
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

  # getmeasure: the last 24 hours of CO2 or temperature, as the curve's columns: each one's top row
  # and its colour.
  def on_chart(r, body, status)
    self.busy = false
    if status != 200 || body == nil
      r.chartAt = now_ms() - 3300000        # again in five minutes
      return
    end
    var j = json.load(body)
    var vals = []
    for seg : (j == nil ? [] : j.find("body", []))
      for v : seg.find("value", [])
        if size(v) > 0 && v[0] != nil vals.push(real(v[0])) end
      end
    end
    j = nil
    while size(vals) > 24 vals.remove(0) end
    if size(vals) < 2 return end
    var lo = vals[0]
    var hi = vals[0]
    for v : vals
      lo = min(lo, v)
      hi = max(hi, v)
    end
    var n = size(vals)
    var co2 = r.kind == "co2"
    var bottom = height() - 1
    var span = 7                      # rows 8-15 under the temperature, or the whole 8 rows
    var w = width() - self.x0
    var ch = []
    var x = 0
    while x < w
      # Between the hours either side of this column
      var at = x * (n - 1) * 1.0 / (w - 1)
      var i = int(at)
      if i >= n - 1 i = n - 2 end
      var v = vals[i] + (vals[i + 1] - vals[i]) * (at - i)
      var row = bottom - (hi == lo ? span / 2 : int((v - lo) * span / (hi - lo) + 0.5))     # highest at the top
      ch.push((row << 24) | self.colour(v, co2))
      x += 1
    end
    r.chart = ch
  end

  # A temperature's colour on the Weather app's scale, or a CO2 level's: green below the comfort
  # zone, yellow in it, red above, as the LaMetric's leaf.
  def colour(v, co2)
    if co2 return v < store.get("clow") ? 0x30C050 : (v > store.get("chigh") ? 0xFF3020 : 0xFFD000) end
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

  # The rooms of this turn, what each shows and how long: worked out once a turn, never in draw().
  # Nothing in the quiet hours, across midnight too, though never before the clock knows the time.
  def should_show()
    if store.get("quiet") && epoch_ms() >= 0
      var h = hour()
      var f = int(store.get("qfrom"))
      var t = int(store.get("qto"))
      if f > t ? (h >= f || h < t) : (h >= f && h < t) return false end
    end
    self.live = []
    self.total = 0
    for r : self.rooms
      if r.temp != nil
        # 8 rows high one thing after the other, each for half the room's time
        r.parts = [0]
        if r.hum != nil r.parts.push(1) end
        if r.co2 != nil r.parts.push(2) end
        if self.chart && r.chart != nil r.parts.push(3) end
        r.page = height() > 8 ? r.ms : r.ms * size(r.parts) / 2
        self.total += r.page
        self.live.push(r)
      end
    end
    # Not signed in, it says so; until the station's first answer, as just after a restart, it
    # leaves the rotation to the others.
    return !self.signed || size(self.live) > 0
  end

  def duration()
    return self.signed ? self.total : 0
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
    # Brought up without the rotation asking should_show() or on_show(): pick the rooms now.
    if size(self.live) == 0 self.on_show() end
    var n = size(self.live)
    if n > 0
      # The rotation keeps the app a moment past its time: the last page stays rather than the first
      # coming back for it. Kept on longer, as the only app, it rounds again from the first room.
      var d = self.total
      var el = (now_ms() - self.t0) % (d + 3000)
      if el >= d el = d - 1 end
      var i = 0
      var start = 0
      while i < n - 1 && el >= start + self.live[i].page
        start += self.live[i].page
        i += 1
      end
      var ph = el - start
      var h = height()
      if i > 0 && ph < 300
        var dy = h - ph * h / 300
        self.show(self.live[i - 1], dy - h, self.live[i - 1].page - 1)
        self.show(self.live[i], dy, 0)
      else
        self.show(self.live[i], 0, ph)
      end
    end
    # A red dot in the upper right corner while the station is not heard from; 2×2 16 rows high.
    if self.err
      var s = height() > 8 ? 2 : 1
      rect_fill(width() - s, 0, s, s, 0xFF0000)
    end
  end

  # One room, dy rows down, ph ms into its page. Its icon, from LaMetric or the clock; the
  # thermometer without one, or when it is missing. The clock fills a square as high as the display
  # with a still one from an address, and plays an animated one at its own size in the middle of it.
  # One on the clock, as the Hub's 8×8 icons the defaults name, it draws at its own size from the
  # corner: in the middle of the TC002's 16×16 square, then.
  def show(r, dy, ph)
    var o = height() > 8 ? 4 : 0
    var ok = (r.url != nil && icon(r.url, 0, dy)) || (r.icon != nil && icon(r.icon, o, dy + o))
    # An icon not drawn may still be on its way, as on the first round after a start: an empty
    # square for up to 5 s rather than the thermometer flashing up before it.
    if ok
      r.wait = 0
    elif r.icon != nil && r.wait == nil
      r.wait = now_ms()
    end
    if !ok && (r.icon == nil || now_ms() - r.wait > 5000)
      var rows = self.thermo[0]
      var colours = self.thermo[1]
      var n = size(rows)
      var o = n > 8 ? (16 - n) / 2 : 0       # a 12×12 icon in the middle of the 16×16 square
      var y = 0
      while y < n
        var x = 0
        while rows[y] != 0 && x < n
          if rows[y] & (1 << (n - 1 - x)) pixel(o + x, dy + o + y, colours[y]) end
          x += 1
        end
        y += 1
      end
    end
    font("small")
    var x0 = self.x0
    var t = r.temp == nil ? [["--", self.fg]] : r.temp      # gone while on screen
    var ch = r.chart
    if !self.chart ch = nil end
    if height() > 8
      # Temperature and humidity, under them CO2 giving way to the curve in the 0.8 s around the
      # page's middle, or the curve alone without CO2: CO2 slides down out of sight in the first
      # half, the curve up from the bottom in the second.
      var q = (ph - r.ms / 2 + 400) / 800.0
      q = q < 0 ? 0.0 : (q > 1 ? 1.0 : q)
      if ch == nil q = 0.0 end
      if r.co2 == nil q = 1.0 end
      var top = 2 + dy                         # two rows above the text, beside the middle of the icon
      var x = x0 + text(x0, top + 5, t)
      if r.hum != nil text(x + 3, top + 5, r.hum) end
      if r.co2 != nil && q < 0.5
        var down = int(q * 22)
        x = x0 + text(x0, top + 11 + down, r.co2, self.fg)
        text(x + 2, top + 11 + down, "ppm", 0x909090)
      end
      if ch != nil && q >= 0.5 self.curve(ch, dy + int((1 - q) * 20)) end
      return
    end
    # 8 rows high one thing at a time beside the icon: each slides down out of sight in its last
    # 0.5 s, and the next comes up from the bottom in its first.
    var parts = r.parts
    var k = size(parts)
    var share = r.ms / 2
    var s = min(ph / share, k - 1)
    var into = ph - s * share
    var off = 0
    if s < k - 1 && share - into < 500
      off = (500 - (share - into)) * 9 / 500
    elif s > 0 && into < 500
      off = 8 - into * 8 / 500
    end
    var what = parts[s]
    if what == 3
      if ch != nil self.curve(ch, dy + off) end
      return
    end
    if what == 1
      t = r.hum
    elif what == 2
      t = text_ink_width(r.co2u) <= width() - x0 ? r.co2u : [[r.co2, self.fg]]
    end
    text(x0 + max(0, (width() - x0 - text_ink_width(t)) / 2), dy + off + 6, t)
  end

  # The last 24 hours, dy rows lower: a bright edge, the area under it dim.
  def curve(ch, dy)
    var bottom = height() - 1
    var j = 0
    while j < size(ch)
      var row = ch[j] >> 24
      var c = ch[j] & 0xFFFFFF
      pixel(self.x0 + j, row + dy, c)
      if row < bottom
        rect_fill(self.x0 + j, row + dy + 1, 1, bottom - row,
                  rgb(((c >> 16) & 255) * 30 / 100, ((c >> 8) & 255) * 30 / 100, (c & 255) * 30 / 100))
      end
      j += 1
    end
  end
end
return Netatmo()
