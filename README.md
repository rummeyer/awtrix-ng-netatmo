# netatmo-awtrix-ng

A Netatmo Weather Station on an [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng)
Ulanzi TC002, in place of the LaMetric Time's Netatmo Weather app: a page per
room, the room's icon on the left, temperature and humidity beside it, CO2
under them, and the temperature of the last 24 hours as a curve along the
bottom. The pages slide up one after the other.

```
 ┌────────┐ 23.2°  51%
 │  icon  │ 892 ppm
 │ 16×16  │
 └────────┘ ▁▁▂▂▃▄▅▅▆▆▇▇▆▅▄▃▃▂▂▁▁▁▂▂
```

The clock signs in to Netatmo itself. There is no bridge or server, and the
icons are part of the script, so the clock asks nothing of anyone but
`api.netatmo.com`.

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

**The script.** In the clock's web UI, opened by its IP address or local
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

## Settings

Behind the same gear button:

| Setting | Default | |
|---|---|---|
| Rooms | see below | Which modules get a page, in order. |
| Short | 5 s | How long a page stays; `medium` is twice as long, `long` three times. |
| Temperature curve | on | The last 24 hours along the bottom. Off puts the values in the middle. |
| Update every | 10 min | The station sends to Netatmo every ten minutes. |
| Temperature comfortable from / to | 18 / 24 °C | Below is blue, above red. |
| CO2 comfortable from / to | 800 / 1500 ppm | Below is green, inside yellow, above red, as on the LaMetric. |
| Notify when uncomfortable | `off` | `silent`, with a `sound`, or the `voice` saying so, when a room turns too cold, too warm or too stuffy. |

**Rooms** are separated by commas. Each is the module's name as in the
Netatmo app, then optionally `:icon` and `short`, `medium` or `long`:

```
Wohnzimmer:sofa, Arbeitszimmer:office, Kinderzimmer:teddy, Schlafzimmer:bed, Balkon:terrace
```

The built-in icons are `sofa`, `office`, `teddy`, `bed` and `terrace`. Any
other name is an icon installed from the [AWTRIX Hub](https://awtrix.de/icons);
a room without one gets a thermometer.

## What it shows

**Temperature** in the colour of its comfort zone, **humidity** in blue
beside it, **CO2** under them in green, yellow or red. Temperatures follow
the clock's °C/°F setting.

**The curve** is the room's temperature of the last 24 hours, an hour per
few columns, with the latest at the right. It is drawn the way the
Weather script by Hank_the_Tank draws its forecast: a bright edge, the area under it
dim, both in that app's temperature colours, from violet in frost through
blue, green and yellow to red in heat. Netatmo keeps the hourly values, so
the curve is full from the first minute.

**An outdoor module** has no CO2, so its page shows temperature and humidity
only. The rooms' comfort zone means nothing outside: its temperature is blue
below 0 °C and red above 30 °C, and it never notifies.

A room out of reach of the station, or named differently from its module,
gets no page. The station's module names are published to the other scripts
as `Netatmo.modules`, readable at `http://<awtrix-ip>/api/v1/scripts/shared`,
which is the quickest way to see what the rooms have to be called.

Netatmo allows 500 requests an hour; the app makes six for the station and
one an hour for each room's curve.

## Licence

MIT. The room icons come from the [LaMetric icon gallery](https://developer.lametric.com/icons)
(8132 sofa, 8135 office, 39884 teddy, 8136 bed, 36855 umbrella), the
thermometer is a [Material Symbol](https://fonts.google.com/icons) (Apache
2.0), and the curve's colours are those of the Weather script by Hank_the_Tank
from the AWTRIX Hub.
