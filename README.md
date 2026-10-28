# Dorm Remote

An iPhone app that controls the dorm lights from one screen. Same pipeline as Glasses Solver: GitHub Actions builds an **unsigned** `.ipa`, and you install it with Sideloadly.

| Light | How the app reaches it | Status |
|---|---|---|
| Daybetter strips (SKU TCF0223124G-JA02), any number | Bluetooth LE, QC controller revisions, CCHIP unlock when needed | Built |
| EcoSmart bulb (Hubspace) | Afero cloud API, login as in [aioafero](https://github.com/Expl0dingBanana/aioafero) | Built; the bulb must be on Wi-Fi |
| Triones / ELK-BLEDOM bulbs | Bluetooth LE | Built |
| Xtreme Lit astronaut and other IR devices | IR, through the ESP32 DormBridge | Needs the board |

Design notes and sources: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Hubspace

Login is Keycloak with PKCE at `accounts.hubspaceconnect.com` (realm `thd`, client `hubspace_android`). The `id_token` is the bearer. Lights are read from `semantics2.afero.net/v1/accounts/{account}/metadevices` and changed with a PUT to `…/metadevices/{id}/state`. The refresh token is kept in the Keychain. A `424` reply means the bulb isn't on Wi-Fi; its tile says so and opens the fix.

## Daybetter protocol

`A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>`, as in [grimsteel/daybetter-led-strip](https://github.com/grimsteel/daybetter-led-strip) (written for the P031). Reference for other revisions: [DoudGeorges/daybetter-leds PROTOCOL.md](https://github.com/DoudGeorges/daybetter-leds).

| Command | cmd | Payload |
|---|---|---|
| Status | `10` | `00` |
| Power | `11` | `01` on, `00` off |
| Effect | `12` | effect id |
| Brightness | `13` | 1 to 100 |
| Color | `15` | `RR GG BB`, gamma and channel corrected |
| Effect speed | `16` | 1 to 100 |

On connect the app asks for status. A strip that answers is ready. A silent one gets the CCHIP unlock: send `CCHIP` (cmd `00`), XOR the reply bytes at index 8 and 9 with 36 and 76, send `CCHIP` plus those bytes (cmd `01`). The app remembers each strip's service and whether it needed the unlock, so reconnects are quicker. "Magic Light" segment controllers use another command set and are named, not driven.

## Install

1. Download `DormRemote-unsigned-ipa` from the latest **Build unsigned IPA** run in the Actions tab and unzip it.
2. Sideloadly: drag in the `.ipa`, enter your Apple ID, **Start**. Then on the iPhone, **Settings → General → VPN & Device Management → Trust**.
3. Free Apple ID: the app expires after 7 days (re-run Sideloadly), and you can have 3 sideloaded apps at once.

## Use

Three tabs:

- **Room**: power, scenes, and every light. A running effect shows live in a **Now playing** bar (each light's current color, speed, Stop). **⋯** has Add, Reduce flashing, Turn everything off, Hubspace sign-out, and the log.
- **Map**: where your lights are. **Find my lights with the camera**: tap the lights in the order you want, then aim the circle at each one as it blinks (it locks on by itself; without LiDAR it asks for a second aim from a step to the side). Tap a dot to make that light blink, drag dots and yourself into place. **How scenes travel** picks the sweep (around you, left to right, front to back, out from you, all at once). **Keep lights in sync**: Flash all together, then nudge any light that comes back late.
- **Automations**: **Walk in** (lights up when you get back; optional location backup that works even after you swipe the app away, an activity log, and Try it now) and the Shortcuts schedule recipes.

Also:

- Fully close the DayBetter app first. A strip accepts one Bluetooth connection at a time.
- Pull down on the Room tab to reconnect anything that dropped.
- If a strip won't connect, **⋯ → Show log** and share it.

## Keeping the cloud bulb in step

The Hubspace bulb takes commands through Home Depot's cloud, so it shows changes about a second after a strip would. The app measures Hubspace's round trip on every command and sends to the bulb that much earlier: room power, scenes, living scenes and Stop land together. A scene goes to the bulb as one command (power, brightness and color), and a tap goes out at once; only drags wait for a pause. In room effects the bulb runs its closest built-in effect, or gets a color every few seconds aimed ahead by its delay. If it still looks late, use **Map → Keep lights in sync**.
