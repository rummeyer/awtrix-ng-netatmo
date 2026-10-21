# netatmo-awtrix-ng

A Netatmo Weather Station on an [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng)
Ulanzi TC002 or TC001, in place of the LaMetric Time's Netatmo Weather app: a page per
room, the room's icon on the left, temperature and humidity beside it, CO2
under them, which halfway through the page give way to the CO2 of the last
24 hours as a curve. The pages slide up one after the other.

```
 ┌────────┐ 23.2°  51%            ┌────────┐ 23.2°  51%
 │  icon  │ 892 ppm        then   │  icon  │      ▂▄▆█▆▄▂
 │ 16×16  │                       │ 16×16  │  ▁▃▅████████▅▃▁
 └────────┘                       └────────┘▂▄███████████████▄▂
```

On the TC001's 32×8 the icon is 8×8, and beside it the temperature,
humidity, CO2 and the curve take turns, each sliding down for the next to
come up from the bottom:

```
 ┌──────┐               ┌──────┐               ┌──────┐               ┌──────┐
 │ icon │  23.2°   →    │ icon │   51%    →    │ icon │   892    →    │ icon │▁▂▄▆█▆▄▃▂▁▂
 └──────┘               └──────┘               └──────┘               └──────┘
```

The clock signs in to Netatmo itself. There is no bridge or server: the
clock asks `api.netatmo.com` for the readings and LaMetric's icon gallery
for the icons, nothing to install first.

## Installing

**A Netatmo app.** Sign in at [dev.netatmo.com](https://dev.netatmo.com)
with the account that owns the station, open **My apps › Create**, give it
a name and a line of description, and enter as **Redirect URI**:

```
https://awtrix.de/oauth/callback
```

Without it, signing in fails with `invalid_client`, the same answer as for a
wrong client secret. Keep the page with the **Client ID** and **Client
Secret** open.

**The script.** On a TC002, from the AWTRIX Hub: open
[Netatmo on the Hub](https://awtrix.de/script/LVDogUoTjVxc), sign in, and
press **Send to AWTRIX**. The clock's web UI then offers each new version as
an update. Or by hand: in the clock's web UI, opened by its IP address or local
name, go to **Scripts**, create a script named `Netatmo`, paste in
[`Netatmo.be`](Netatmo.be) and save. Or from a computer on the same network:

```sh
curl -X PUT "http://<awtrix-ip>/api/v1/apps/script/Netatmo" \
  -H "Content-Type: text/plain" --data-binary @Netatmo.be
```

**Signing in.** On the **Apps** tab, press the gear button on the `Netatmo`
row. Paste Client ID and Client Secret into the **Sign-in** block, press
**Sign in**, sign in at Netatmo and allow access. The block then says
**Signed in**, and the first pages appear within a minute. Until then the
clock says it wants signing in. It keeps the sign-in and renews it by itself,
and asks for `read_station` only, so it can read the station and nothing
else.

**On a TC001.** Its firmware has no sign-in for scripts, so the app signs in
with a token instead. Install the script without its `@oauth` line, which
the TC001 cannot use and which would mark the app as not fitting the clock:

```sh
sed '/^# @oauth /d' Netatmo.be | curl -X PUT "http://<tc001-ip>/api/v1/apps/script/Netatmo" \
  -H "Content-Type: text/plain" --data-binary @-
```

Then at
[dev.netatmo.com](https://dev.netatmo.com) open your app, go to **Token
generator**, choose the scope `read_station` and press **Generate Token**.
On the clock's **Apps** tab, press the gear button on the `Netatmo` row and
paste **Client ID**, **Client secret** and the **Refresh token** into the
**Token** block. The app renews the token by itself and keeps the new
refresh token there, so it only needs doing once. If it ever stops working,
the clock says the token was refused: generate a new one. The secret and the
token are readable to anyone who can open the clock's web UI or a config
backup.

The TC001 cannot draw pictures from a web address, so its icons have to be
on the clock, named by their number. [`install-icons.py`](install-icons.py)
puts them there: it reads the rooms from the app's settings and installs
every icon number the clock does not have yet, a still PNG turned into a GIF.
It needs Python 3 and nothing else, leaves installed icons alone and skips a
TC002, so it can run after every change of the rooms, or from cron:

```sh
python3 install-icons.py <tc001-ip>
```

Saving a new version of the script on a TC001 can restart the clock and
leave the old one in place: it has too little memory for both. Then delete
the app, install the script again, and paste the token back in.

## Settings

Behind the same gear button:

| Setting | Default | |
|---|---|---|
| Rooms | see below | Which modules get a page, in order. |
| Short | 5 s | How long a page stays; `medium` is twice as long, `long` three times. |
| 24-hour curve | on | The last 24 hours along the bottom. Off puts the values in the middle. |
| Update every | 10 min | The station sends to Netatmo every ten minutes. |
| Temperature comfortable from / to | 18 / 24 °C | Below is blue, above red. |
| CO2 comfortable from / to | 800 / 1500 ppm | Below is green, inside yellow, above red, as on the LaMetric. |
| Quiet hours | off, 23 to 8 h | Left out of the rotation between these hours, across midnight too. The readings keep coming, so the pages are up to date in the morning. |
| Notify when uncomfortable | `off` | `silent`, with a `sound`, or the `voice` saying so, when a room turns too cold, too warm or too stuffy. |

**Rooms** are separated by commas. Each is the module's name as in the
Netatmo app, then optionally `:icon` and `short`, `medium` or `long`:

```
Wohnzimmer:8132, Arbeitszimmer:8135, Kinderzimmer:39884, Schlafzimmer:8136, Balkon:36855
```

**Icons** are numbers from the [LaMetric icon gallery](https://developer.lametric.com/icons):
the clock draws them from
`https://developer.lametric.com/content/apps/icon_thumbs/<number>`, a still
one filling the 16×16 square, an animated one at its own 8×8 in the middle
of it. On a TC001 the number names an icon installed on the clock, shown
at 8×8 (see Installing). Any other name is an icon on the clock, such as one installed from
the [AWTRIX Hub](https://awtrix.de/icons). A room without one, or whose icon
cannot be found, gets a thermometer.

## What it shows

**Temperature** in the colour of its comfort zone, **humidity** in blue
beside it, **CO2** under them in green, yellow or red. Temperatures follow
the clock's °C/°F setting.

**The curve** is the room's CO2 of the last 24 hours, an hour per few
columns, with the latest at the right, in the green, yellow and red of the
CO2 value. It takes the CO2 value's place for the second half of the page,
filling everything under the temperature. It is drawn the way the Weather script by Hank_the_Tank
draws its forecast: a bright edge, the area under it dim. Netatmo keeps the
hourly values, so the curve is full from the first minute.

**An outdoor module** has no CO2, so its page shows temperature and humidity
only, and its curve, shown for the whole page, is the temperature instead, in the Weather script's temperature colours from violet
in frost through blue, green and yellow to red in heat. The rooms' comfort
zone means nothing outside: its temperature is blue below 0 °C and red above
30 °C, and it never notifies.

A room out of reach of the station, or named differently from its module,
gets no page. The station's module names are published to the other scripts
as `Netatmo.modules`, readable at `http://<awtrix-ip>/api/v1/scripts/shared`,
which is the quickest way to see what the rooms have to be called.

Netatmo allows 500 requests an hour; the app makes six for the station and
one an hour for each room's curve.

## Licence

MIT. The room icons are drawn from the [LaMetric icon gallery](https://developer.lametric.com/icons)
and belong to their authors, the
thermometer is a [Material Symbol](https://fonts.google.com/icons) (Apache
2.0), and the outdoor curve's colours are those of the Weather script by Hank_the_Tank
from the AWTRIX Hub.
