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

- Fully close the DayBetter app first. A strip accepts one Bluetooth connection at a time.
- **Add → DayBetter LED strip** for each strip. Strips you've added stay connected and reconnect by themselves.
- Pull down on the home screen to reconnect anything that dropped.
- **⋯ → Schedules & automations** has Shortcuts recipes: wake-up light, bedtime fade, Action Button, Control Center, Siri.
- If a strip won't connect, **⋯ → Show log** and share it.
