# Dorm Remote architecture

Goal: one iPhone app that runs every light in the room, works without campus Wi-Fi, and needs the fewest extra devices.

## The answer

**Phone + one $8 board.** Everything local runs over Bluetooth LE, so campus Wi-Fi never matters.

```
                       ┌──────────────── Bluetooth LE ───────────────┐
iPhone (Dorm Remote) ──┤                                             │
                       ├──► DayBetter strip P031 (direct, local)     │
                       ├──► DormBridge (M5Stack ATOM Lite) ──IR──► astronaut projector
                       └──► Hubspace cloud ──► Hubspace bulbs on Aggie_Guest Wi-Fi
```

| Light | Path | Local? | Extra hardware |
|---|---|---|---|
| DayBetter LED strip (P031, QC family) | Phone → strip over BLE, CCHIP unlock, `A0` frames | Yes | None |
| Xtreme Lit astronaut projector | Phone → DormBridge over BLE → IR LED | Yes | M5Stack ATOM Lite (~$8); optional IR Unit U002 (~$4) to learn codes |
| EcoSmart Hubspace bulbs | Bulb on Wi-Fi (Aggie_Guest) → Hubspace cloud ← phone | No | None |
| Replacement Triones / ELK-BLEDOM bulbs | Phone → bulb over BLE | Yes | Bulbs replace the Hubspace ones (not an extra device) |

## Why each choice

### DayBetter strips: direct BLE (done, any number of strips)
- Commands follow grimsteel/daybetter-led-strip, written for the P031: frame `A0 cmd len payload CRC16/MODBUS`, service `E031` →
  write `A031`, notify `F031`. Color `15 R G B` (gamma + channel balance), effect `12 id`, brightness `13`, power `11`, status `10 00`.
  Speed `16` comes from DoudGeorges/daybetter-leds PROTOCOL.md; controllers that don't know it ignore it.
- Connect: ask for status. A strip that replies is ready. A silent one gets the CCHIP unlock (XOR 36/76, PROTOCOL.md); a strip that
  answers neither still gets commands.
- "Magic Light" (HC) controllers (`AE30`, `E010`, `E019`, `E01A`, `E020`, `E028`, `E02A`, `E036`, `E044`) address segments with a
  different command set; the app names them instead of sending commands they ignore.
- Setup lists a device as a strip by name (`P0xx_…`, Smart Light, Magic Light, Wi-Fi Light, BLE Bulb, CCHIP) or by its advertised
  scan service (`C0xx`, `AF30`), so nameless controllers show up too.
- Each saved strip keeps its own pending connect. The managers use restore identifiers (`strips`, `bulbs`, `bridge`), so iOS
  relaunches the app when a light comes back (Apple TN3115; not after a force-quit or with Bluetooth off in Settings).
- Built-in effects run on each controller's clock and drift apart; "Rainbow in sync" and phone-mic music run from the app's clock.
- AccessorySetupKit is left out: once adopted, CoreBluetooth only sees accessories approved in Apple's picker, which would hide the
  bulbs, the bridge, and the "show all devices" list.
- Each strip takes one BLE connection at a time: close the DayBetter app.

### Projector: an IR bridge is the only way
- iPhones have no IR blaster, and the projector has no radio. Something has to emit infrared.
- **M5Stack ATOM Lite**: ESP32 with a built-in IR LED (G12), USB-C powered, no soldering. Firmware in `firmware/`
  (PlatformIO, Arduino core, NimBLE-Arduino 2.3.2, IRremoteESP8266 2.8.6). No Wi-Fi: the phone talks to it over BLE (service `DB00`).
- Default codes: Flipper IRDB `LED_Lighting/HLKZine/Astronaut_Star_Projector.ir` (NEC-extended, address `07 FD`). These are
  community codes for a similar astronaut projector, not confirmed for the Xtreme Lit model.
- If a code doesn't work: add the **M5Stack IR Unit** (Grove; TX G26, RX G32) and use "Learn buttons" in the app. The bridge
  decodes the real remote's signal with IRremoteESP8266 and the app saves it per button.
- Flash from the browser (esptool-js, Chrome/Edge); CI produces one merged `.bin`.

### Hubspace bulbs: they need Wi-Fi
- Tested: the cloud API works (login, list, commands), but every command returns **424** because the bulbs never joined Wi-Fi.
- Local Bluetooth control is not possible: Afero uses end-to-end ECDH + AES-GCM with keys that never leave the bulb
  (Afero security white paper; jdeath/Hubspace-Homeassistant #258, 2026: "BT control is out").
- Running Afero's public Softhub inside this app was tried and removed: Hubspace's cloud (api2.afero.net) only accepts
  hubs with Hubspace's private authenticator certificate; a `prod` softhub's join returns 400 (seen in this app's log).
- Ranked fixes:
  1. **NC A&T Aggie_Guest**: register the bulb's Wi-Fi MAC (`14:08:08:13:c9:70`) at https://ncatnac2.ncat.edu/self_registration
     (sign in from AggiePride), wait for "Approved", then run Wi-Fi setup in the Hubspace app and pick Aggie_Guest. NC A&T's KB
     lists bulbs/plugs as Aggie_Guest devices. Risk: Hubspace needs 2.4 GHz; if the network doesn't show, ask the IT desk
     (336-334-7195) or file "Student Device and Gaming Registration". After that, Dorm Remote controls the bulbs, no app changes.
  2. **A spare phone's Personal Hotspot** with "Maximize Compatibility" (2.4 GHz) as the bulb's Wi-Fi.
  3. **Fully local**: replace with Triones (Happy Lighting) or ELK-BLEDOM (Lotus Lamp) bulbs, about $8–11 each; Dorm Remote
     already drives them over BLE ("Add" → Bluetooth bulb). Avoid newer Govee bulbs (encrypted BLE).

## iOS limits and the workarounds

| Limit | Workaround |
|---|---|
| Free Apple ID apps expire after 7 days | Install **SideStore** with iloader once; it refreshes on the phone over LocalDevVPN, no PC. Or a $99/yr developer account (1-year signing). |
| Apple's sign-in block on sideloading tools (Oct 2026, error -80045/-80046) | iloader 2.3.10. Pick a working anisette server (StikStore or Jkcoxson) **before** signing in: iloader fixes the server at login (`account.rs`), so changing it later needs Sign Out → Sign In. Sideloadly 0.71 still fails. |
| No timers while the app is closed | Built-in effects run on the lights themselves. Schedules: the app ships Shortcuts actions (Turn lights on/off, Set scene); use **Shortcuts → Automation → Time of Day → Run Immediately**. |
| BLE is one connection per strip | Close the DayBetter app. |
| iOS caps BLE connections per phone (undocumented; varies by model) | The app names the limit error instead of a generic failure. |
| No IR hardware | DormBridge (above). |
| Campus Wi-Fi blocks smart devices | Everything local is BLE; only the Hubspace bulbs need internet, through the phone. |

## Next steps, in order
1. Install the current build; test strip colors and the bulb softhub (look for `bulb hub` lines in the log).
2. Buy an M5Stack ATOM Lite (+ IR Unit), flash `dormbridge-merged.bin`, test the projector codes; learn any that don't work.
3. Shortcuts actions are in; add per-light actions and a Control Center control if needed.
4. If the softhub can't join the account: get the bulbs on Wi-Fi, or swap them for `led-ble` bulbs.
