# DormBridge firmware (IR bridge)

Lets Dorm Remote control the Xtreme Lit astronaut projector, which only listens to infrared.

## Hardware

- **M5Stack ATOM Lite** (~$8): ESP32 with a built-in IR LED, USB-C powered. Nothing to solder.
- Optional **M5Stack IR Unit (U002)** (~$4): plugs into the ATOM's Grove port and adds an IR receiver,
  so the app can learn codes straight from the projector's remote if the built-in codes don't match.

Point the ATOM at the projector (IR range is a few meters, line of sight) and power it from any USB charger.

## Flash it (no installs)

1. Download `dormbridge-merged.bin` from the latest **Build firmware** run on GitHub Actions.
2. Plug the ATOM into the computer with USB-C, open https://espressif.github.io/esptool-js/ in Chrome or Edge.
3. Connect, set the flash address to `0x0`, choose the file, click **Program**.

## Protocol

See the comment at the top of `src/main.cpp`. The app's default projector codes come from the
Flipper IRDB file `LED_Lighting/HLKZine/Astronaut_Star_Projector.ir` (NEC-extended, address 07 FD).
