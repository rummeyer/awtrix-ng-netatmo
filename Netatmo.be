# @name    Netatmo
# @desc    Netatmo Weather Station, a page per room: temperature, humidity, CO2 and the last 24 hours
# @author  Oliver Rummeyer
# @version 5.0
# @display 52x16
# @oauth   authorize=https://api.netatmo.com/oauth2/authorize token=https://api.netatmo.com/oauth2/token api=api.netatmo.com scope="read_station" auth=body
# @config  rooms   text   "Rooms"          default="Wohnzimmer:sofa, Arbeitszimmer:office, Kinderzimmer:teddy, Schlafzimmer:bed, Balkon:terrace" help="Module[:icon] [short|medium|long], comma separated; icons: sofa, office, teddy, bed, terrace" maxlen=256
# @config  seconds number "Short"          default=5 min=2 max=30 unit=s help="How long a short page stays; medium is twice, long three times"
# @config  chart   bool   "Temperature curve" default=true help="The last 24 hours along the bottom"
# @config  every   number "Update every"   default=10 min=5 max=60 unit=min
# @config  tlow    number "Comfortable from" default=18 min=-30 max=40 unit=°C group="Temperature"
# @config  thigh   number "Comfortable to" default=24 min=-30 max=40 unit=°C group="Temperature"
# @config  clow    number "Comfortable from" default=800 min=400 max=5000 step=50 unit=ppm group="CO2"
# @config  chigh   number "Comfortable to" default=1500 min=400 max=5000 step=50 unit=ppm group="CO2"
# @config  alert   select "Notify when uncomfortable" default=off options=off,silent,sound,voice
import string
import json
import oauth

# A page per room: its icon, the temperature and humidity beside it, CO2 under
# them, and the temperature of the last 24 hours as a curve along the bottom,
# drawn as the Weather app draws its forecast. The pages slide up one after the other
# and the app stays as long as they take. The clock signs in to Netatmo
# itself; a room not heard from is left out.
class Netatmo
  var rooms, live, fg, t0, signed, ticks, busy, chart, missing, st

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
    self.live = []
    # The rooms' icons from the LaMetric gallery, 8×8 drawn at double size: the ms per frame of an
    # animated one (0 for a still), then RGB per pixel of each frame. The thermometer for a room
    # without one is a Material Symbol (Apache 2.0), 12×12: a row per number, the leftmost pixel
    # the highest bit, then the colour of each row.
    var W = 0xE8E8E8
    var icons = {
      # LaMetric icon 8132
      "sofa": [0,
        bytes(
          "000000000000000000000000000000000000000000000000"
          "000000000000000000000000000000000000000000000000"
          "000000378CBF378CBF286A92378CBF378CBF286A92000000"
          "FFFFFF378CBF378CBF286A92378CBF378CBF286A92FFFFFF"
          "FFFFFF1F68951F68951F68951F68951F68951F6895FFFFFF"
          "FFFFFF378CBF378CBF378CBF378CBF378CBF378CBFFFFFFF"
          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
          "000000878787000000000000000000000000878787000000")],
      # LaMetric icon 8135, a screen row and column taken out to make it smaller
      "office": [0,
        bytes(
          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDDDDDDBFBFBF000000"
          "FFFFFF48BDFE48BDFE48BDFE48BDFE3B9AD0DDDDDD000000"
          "FFFFFF48BDFE3B9AD03B9AD03388B73388B7BFBFBF000000"
          "FFFFFF48BDFE3388B73388B73388B73388B7BFBFBF000000"
          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDDDDDDBFBFBF000000"
          "000000000000000000FFFFFFDDDDDD000000000000000000"
          "000000000000FFFFFFFFFFFFFFFFFFBFBFBF000000000000"
          "000000000000000000000000000000000000000000000000")],
      # LaMetric icon 8136
      "bed": [0,
        bytes(
          "000000000000000000000000000000000000000000000000"
          "000000000000000000000000000000000000000000378CBF"
          "000000000000000000000000000000000000FFFFFF378CBF"
          "378CBF000000000000000000000000D8D8D8B9B9B9378CBF"
          "378CBFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF378CBF"
          "378CBF378CBF378CBF378CBF378CBF378CBF378CBF378CBF"
          "0000002A6A910000000000000000000000002A6A91000000"
          "000000000000000000000000000000000000000000000000")],
      # LaMetric icon 36855
      "terrace": [0,
        bytes(
          "000000000000000000CCCCCC000000000000000000000000"
          "0000000000009000FE9000FE9000FE000000000000000000"
          "0000009000FE9000FE9000FE9000FE9000FE000000000000"
          "9000FE9000FE9000FE9000FE9000FE9000FE9000FE000000"
          "49BDFE00000049BDFECCCCCC49BDFE00000049BDFE000000"
          "000000000000000000CCCCCC000000000000000000000000"
          "000000000000000000CCCCCC000000CCCCCC000000000000"
          "000000000000000000CCCCCCCCCCCCCCCCCC000000000000")],
      # LaMetric icon 39884
      "teddy": [0,
        bytes(
          "F0AD57F0AD57000000000000000000000000F0AD57F0AD57"
          "F0AD57814D0AF0AD57F0AD57F0AD57F0AD57814D0AF0AD57"
          "000000F0AD57000000F0AD57F0AD57000000F0AD57000000"
          "000000F0AD57F0AD57000000000000F0AD57F0AD57000000"
          "000000F0AD57F0AD57000000000000F0AD57F0AD57000000"
          "000000F0AD57F0AD57F0AD57F0AD57F0AD57F0AD57000000"
          "000000000000F0AD57F0AD57F0AD57F0AD57000000000000"
          "000000000000000000000000000000000000000000000000")],
      "room": [[0x060, 0x0F0, 0x0B0, 0x0B0, 0x0B0, 0x0F0, 0x0F0, 0x1F8, 0x1F8, 0x1F8, 0x0F0, 0x060],      # device_thermostat
               [W, W, W, W, W, W, W, 0xFF3020, 0xFF3020, 0xFF3020, 0xFF3020, 0xFF3020]],
    }
    icons["child"] = icons["teddy"]
    icons["horse"] = icons["teddy"]
    var times = {"short": 1, "medium": 2, "long": 3}
    var short = int(store.get("seconds")) * 1000
    self.rooms = []
    for item : re.matchall("[^,]+", store.get("rooms"))
      var m = re.search("^ *([^:]*[^: ]) *(: *([^ ]*))? *(short|medium|long)?", item)
      if m != nil
        var ic = m[3] == "" ? nil : m[3]
        var g = icons.find(ic == nil ? "room" : ic, icons["room"])
        # A picture in the middle of the 16×16 square by the pixels it lights, not by its 8×8 frame.
        var ox = 0
        var oy = 0
        if type(g[0]) == "int"
          var x0 = 8
          var x1 = -1
          var y0 = 8
          var y1 = -1
          for f : 1 .. size(g) - 1
            for p : 0 .. 63
              if g[f][p * 3] | g[f][p * 3 + 1] | g[f][p * 3 + 2]
                x0 = min(x0, p & 7)
                x1 = max(x1, p & 7)
                y0 = min(y0, p >> 3)
                y1 = max(y1, p >> 3)
              end
            end
          end
          if x1 >= 0
            ox = (16 - 2 * (x1 - x0 + 1)) / 2 - 2 * x0
            oy = (16 - 2 * (y1 - y0 + 1)) / 2 - 2 * y0
          end
        end
        # A name not built in is an icon installed from the AWTRIX Hub.
        self.rooms.push({"module": m[1], "icon": g, "ox": ox, "oy": oy,
                         "hub": ic != nil && icons.find(ic) == nil ? ic : nil,
                         "ms": short * (m[4] == nil ? 1 : times[m[4]]),
                         "temp": nil, "hum": nil, "co2": nil, "co2tint": self.fg,
                         "tint": self.fg, "chart": nil, "chartAt": nil, "out": nil})
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
    self.signed = oauth.ready()
    if !self.signed || self.busy return end
    self.ticks -= 1
    if self.ticks <= 0
      self.ticks = int(store.get("every")) * 60
      self.busy = oauth.get("https://api.netatmo.com/api/getstationsdata?get_favorites=false",
                            / b, s -> self.on_stations(b, s), {'cap': 65536})
      return
    end
    if !self.chart || epoch_ms() < 0 return end
    for r : self.rooms
      if r.find("device") != nil && (r["chartAt"] == nil || now_ms() - r["chartAt"] > 3600000)
        r["chartAt"] = now_ms()
        var url = "https://api.netatmo.com/api/getmeasure?scale=1hour&optimize=true&real_time=true" +
                  "&type=temperature&device_id=" + string.replace(r["device"], ":", "%3A") +
                  "&date_begin=" + str(epoch_ms() / 1000 - 86400)
        if r["id"] != nil url += "&module_id=" + string.replace(r["id"], ":", "%3A") end
        self.busy = oauth.get(url, / b, s -> self.on_chart(r, b, s), {'cap': 16384})
        return
      end
    end
  end

  # getstationsdata: every module of every station, the rooms' readings taken out of it.
  def on_stations(body, status)
    self.busy = false
    if status != 200 || body == nil return end
    var j = json.load(body)
    var devices = j == nil ? nil : j.find("body", {}).find("devices")
    if devices == nil return end
    for r : self.rooms r["seen"] = false end
    var names = []
    for d : devices
      var mods = [d]
      for m : d.find("modules", []) mods.push(m) end
      for m : mods
        names.push(m.find("module_name", "?"))
        var data = m.find("dashboard_data")
        for r : self.rooms
          if r["module"] != m.find("module_name") || data == nil || data.find("Temperature") == nil continue end
          r["device"] = d.find("_id")
          r["id"] = m.find("type") == "NAMain" ? nil : m.find("_id")
          r["seen"] = true
          self.reading(r, data, m.find("type") == "NAModule1")
        end
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

  # getmeasure: the last 24 hours of temperature, as the curve's columns: each one's top row,
  # its colour and that colour dimmed for the area under it.
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
    var w = width() - 18
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
      rows.push(15 - (hi == lo ? 1 : int((v - lo) * 2 / (hi - lo) + 0.5)))     # rows 13 (warmest) .. 15
      var c = self.colour(v)
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
      # Green below the comfort zone, yellow in it, red above, as the LaMetric's leaf.
      r["co2tint"] = c < store.get("clow") ? 0x30C050 : (c > store.get("chigh") ? 0xFF3020 : 0xFFD000)
      r["co2"] = str(round(c))
      if c > store.get("chigh")
        out = true
        why = str(round(c)) + " ppm CO2"
      end
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

  def should_show()
    self.live = []
    for r : self.rooms
      if r["temp"] != nil self.live.push(r) end
    end
    return !self.signed || size(self.live) > 0
  end

  def duration()
    if !self.signed return 0 end
    var ms = 0
    for r : self.live ms += r["ms"] end
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
      scroll_text("Netatmo: sign in in the app settings", self.fg)
      return
    end
    var n = size(self.live)
    if n == 0
      # Brought up without the rotation asking should_show() or on_show(): pick the rooms now.
      self.on_show()
      n = size(self.live)
      if n == 0 return end
    end
    # Round again from the first room when the app is kept on longer than they take.
    var el = (now_ms() - self.t0) % self.duration()
    var i = 0
    var start = 0
    while i < n - 1 && el >= start + self.live[i]["ms"]
      start += self.live[i]["ms"]
      i += 1
    end
    var ph = el - start
    var h = height()
    if i > 0 && ph < 300
      var dy = h - ph * h / 300
      self.paint(self.live[i - 1], dy - h)
      self.paint(self.live[i], dy)
    else
      self.paint(self.live[i], 0)
    end
  end

  # One room, dy rows down: icon, temperature, humidity and CO2, the curve along the bottom.
  def paint(r, dy)
    var top = (self.chart ? 0 : 2) + dy
    var g = r["icon"]
    if r["hub"] != nil && icon(r["hub"], 0, top)
      g = nil
    end
    if g != nil && type(g[0]) == "int"
      # A picture: the frame for now, each pixel a 2×2 block
      var b = g[1]
      if g[0] > 0 b = g[1 + (now_ms() / g[0]) % (size(g) - 1)] end
      var p = 0
      while p < 64
        var c = (b[p * 3] << 16) | (b[p * 3 + 1] << 8) | b[p * 3 + 2]
        if c != 0 rect_fill(r["ox"] + (p & 7) * 2, dy + r["oy"] + (p >> 3) * 2, 2, 2, c) end
        p += 1
      end
    elif g != nil
      var rows = g[0]
      var colours = g[1]
      var n = size(rows)
      var o = (16 - n) / 2           # a 12×12 icon in the middle of the 16×16 square
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
    # Beside the icon: temperature and humidity, CO2 under them, in the small font.
    font("small")
    var x0 = 18
    var t = r["temp"] == nil ? "--" : r["temp"]      # gone while on screen
    var x = x0 + text(x0, top + 5, t, r["tint"])
    if r["hum"] != nil text(x + 3, top + 5, r["hum"], 0x31B8DB) end
    if r["co2"] != nil
      x = x0 + text(x0, top + 11, r["co2"], r["co2tint"])
      text(x + 2, top + 11, "ppm", r["co2tint"])
    end
    # The last 24 hours, rows 13-15, clear of the "ppm" above: a bright edge, the area under it dim.
    var ch = r["chart"]
    if self.chart && ch != nil
      var rows = ch[0]
      var m = size(rows)
      var j = 0
      while j < m
        var y = rows[j] + dy
        pixel(x0 + j, y, ch[1][j])
        if rows[j] < 15 rect_fill(x0 + j, y + 1, 1, 15 - rows[j], ch[2][j]) end
        j += 1
      end
    end
  end
end
return Netatmo()
