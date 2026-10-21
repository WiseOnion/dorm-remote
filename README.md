# Dorm Remote

An iPhone app that controls the dorm lights from one screen. Same pipeline as Glasses Solver: GitHub Actions builds an **unsigned** `.ipa`, and you install it with Sideloadly.

| Light | How the app reaches it | Status |
|---|---|---|
| Daybetter strip (SKU TCF0223124G-JA02) | Bluetooth LE, service `E026` | Built |
| EcoSmart bulb (Hubspace) | Afero cloud API | Next |
| Xtreme Lit astronaut | IR, through an ESP32 bridge | Needs the ESP32 |

## Daybetter protocol

`A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>`

| Command | cmd | Payload |
|---|---|---|
| Power | `11` | `01` on, `00` off |
| Brightness | `13` | 1 to 100 |
| Color | `15` | `RR GG BB` |

Commands come from [homebridge-daybetter](https://github.com/shindekokoro/homebridge-daybetter). Its last two bytes were unexplained; they match CRC-16/MODBUS on every captured frame, so any color works.

## Install

1. Download `DormRemote-unsigned-ipa` from the latest **Build unsigned IPA** run in the Actions tab and unzip it.
2. Sideloadly: drag in the `.ipa`, enter your Apple ID, **Start**. Then on the iPhone, **Settings → General → VPN & Device Management → Trust**.
3. Free Apple ID: the app expires after 7 days (re-run Sideloadly), and you can have 3 sideloaded apps at once.

## Use

Fully close the DayBetter app first. The strip accepts one Bluetooth connection at a time. Open Dorm Remote, tap your strip in the list, and it reconnects automatically next time. If it can't find service `E026`, tap **Log** and share it.
