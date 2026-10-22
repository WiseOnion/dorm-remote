# Dorm Remote architecture

Goal: one iPhone app that runs every light in the room, works without campus Wi-Fi, and needs the fewest extra devices.

## The answer

**Phone + one $8 board.** Everything local runs over Bluetooth LE, so campus Wi-Fi never matters.

```
                       ┌──────────────── Bluetooth LE ───────────────┐
iPhone (Dorm Remote) ──┤                                             │
                       ├──► DayBetter strip P031 (direct, local)     │
                       ├──► DormBridge (M5Stack ATOM Lite) ──IR──► astronaut projector
                       └──► Hubspace bulbs (Afero Softhub inside the app) ──► Hubspace cloud ──┘
```

| Light | Path | Local? | Extra hardware |
|---|---|---|---|
| DayBetter LED strip (P031, QC family) | Phone → strip over BLE, CCHIP unlock, `A0` frames | Yes | None |
| Xtreme Lit astronaut projector | Phone → DormBridge over BLE → IR LED | Yes | M5Stack ATOM Lite (~$8); optional IR Unit U002 (~$4) to learn codes |
| EcoSmart Hubspace bulbs | Phone runs Afero's Softhub → Hubspace cloud → back through the phone → bulb over BLE | No (needs the phone's internet) | None |
| Replacement Triones / ELK-BLEDOM bulbs | Phone → bulb over BLE | Yes | Bulbs replace the Hubspace ones (not an extra device) |

## Why each choice

### DayBetter strip: direct BLE (done)
- Protocol is public: frame `A0 cmd len payload CRC16/MODBUS`, CCHIP unlock (XOR 36/76), service `E031` → write `A031`, notify `F031`.
  Sources: DoudGeorges/daybetter-leds PROTOCOL.md, PsychedelicPalimpsest DayBetter gateway (tested live).
- Colors are sent like the DayBetter app: `12 01 00` (solid mode) then `15 R G B FF`. A 3-byte color made the controller read
  the checksum as the 4th byte, which is why some colors failed.
- Built-in effects (`12 id FF`, ids 9–32), speed (`16`), strip-mic music (`12 A0 style` + `21 01`), mic sensitivity (`17`).
- The app reads the strip's status (`10 01`) on connect, so IR-remote changes show up in the app.
- The strip takes one BLE connection at a time: close the DayBetter app.

### Projector: an IR bridge is the only way
- iPhones have no IR blaster, and the projector has no radio. Something has to emit infrared.
- **M5Stack ATOM Lite**: ESP32 with a built-in IR LED (G12), USB-C powered, no soldering. Firmware in `firmware/`
  (PlatformIO, Arduino core, NimBLE-Arduino 2.3.2, IRremoteESP8266 2.8.6). No Wi-Fi: the phone talks to it over BLE (service `DB00`).
- Default codes: Flipper IRDB `LED_Lighting/HLKZine/Astronaut_Star_Projector.ir` (NEC-extended, address `07 FD`). These are
  community codes for a similar astronaut projector, not confirmed for the Xtreme Lit model.
- If a code doesn't work: add the **M5Stack IR Unit** (Grove; TX G26, RX G32) and use "Learn buttons" in the app. The bridge
  decodes the real remote's signal with IRremoteESP8266 and the app saves it per button.
- Flash from the browser (esptool-js, Chrome/Edge); CI produces one merged `.bin`.

### Hubspace bulbs: the bulb is the hard limit
- The bulbs never finished Wi-Fi setup (dorm Wi-Fi is usually WPA2-Enterprise, which these bulbs can't join).
- Without Wi-Fi they only reach Hubspace through a Bluetooth hub. The Hubspace app is that hub; Dorm Remote now embeds the same
  component, Afero's published **AferoSofthub** framework (Afero Permissive Binary License, redistribution allowed).
  Commands still go phone → Hubspace cloud → phone → bulb, so this needs internet (cellular is fine) and works only while
  the app is open (Afero asks apps to stop the softhub in the background).
- Afero encrypts its BLE link and no one has published a local protocol (Home Assistant and Hubitat communities, 2023–2026),
  so **a fully local Hubspace path does not exist today**. Ranked fallbacks:
  1. **Softhub in the app** (built, needs testing). Zero extra hardware.
  2. **Put the bulbs on Wi-Fi**: register the bulb's MAC (`14:08:08:13:c9:70`) on the campus device network if there is one,
     or use a pocket travel router. Still cloud, but works without the phone open.
  3. **Fully local (built)**: swap the Hubspace bulbs for Bluetooth bulbs with a published protocol. The app already drives
     **Triones** bulbs (sold for the "Happy Lighting" app; spec: madhead/saberlight) and **ELK-BLEDOM** bulbs (sold for the
     "Lotus Lamp" app; spec: dave-code-ruiz/elkbledom), with power, color, white, and brightness, all over BLE from the phone.
     Tap "Add a Bluetooth bulb" on the home screen. Check the listing names one of those apps before buying.

## iOS limits and the workarounds

| Limit | Workaround |
|---|---|
| Free Apple ID apps expire after 7 days | Install **SideStore** with iloader once; it refreshes on the phone over LocalDevVPN, no PC. Or a $99/yr developer account (1-year signing). |
| Apple's sign-in block on sideloading tools (Oct 2026, error -80045/-80046) | iloader 2.3.10. Pick a working anisette server (StikStore or Jkcoxson) **before** signing in: iloader fixes the server at login (`account.rs`), so changing it later needs Sign Out → Sign In. Sideloadly 0.71 still fails. |
| No timers while the app is closed | Built-in effects run on the lights themselves. Schedules: the app ships Shortcuts actions (Turn lights on/off, Set scene); use **Shortcuts → Automation → Time of Day → Run Immediately**. |
| BLE is one connection per strip | The app releases nothing on purpose today; close the DayBetter app. |
| No IR hardware | DormBridge (above). |
| Campus Wi-Fi blocks smart devices | Everything local is BLE; only the Hubspace bulbs need internet, through the phone. |

## Next steps, in order
1. Install the current build; test strip colors and the bulb softhub (look for `bulb hub` lines in the log).
2. Buy an M5Stack ATOM Lite (+ IR Unit), flash `dormbridge-merged.bin`, test the projector codes; learn any that don't work.
3. Shortcuts actions are in; add per-light actions and a Control Center control if needed.
4. If the softhub can't join the account: get the bulbs on Wi-Fi, or swap them for `led-ble` bulbs.
