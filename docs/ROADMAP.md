# Dorm Remote roadmap

What people want from a universal LED remote, what Dorm Remote already does, and what gets built next, in order.
Each item ships as its own commit and has to pass CI (full app build + unit tests) before the next one starts.

## What users want (research, October 2026)

| Want | Evidence | Dorm Remote |
|---|---|---|
| Lights that connect every time and reconnect on their own | Top complaint in DayBetter App Store reviews ("fail to connect every time after unplugging", Nov 2025; "frequent issues with Bluetooth connectivity", Dec 2025) and Magic Home Pro reviews ("randomly disconnect", "constantly have to reinstall") | Done: per-strip pending connects, retry with backoff, CCHIP fallback, state restoration, pull to refresh |
| The app shows what the light is really doing | Magic Home Pro: on/off labels "often do not show the correct state" | Done: strips report status on connect and after IR remote presses; Hubspace re-read every 15 s and after each command |
| No surprise flashing; a gentle music mode | DayBetter: music sync "fast strobing on any noise, even in soft mode"; a reviewer with epilepsy hit unexpected flashing (Dec 2025) | Next: **Reduce flashing** setting and a gentler music mode |
| Siri / Shortcuts / one-tap on-off | DayBetter: "No Siri or iOS Shortcuts support for quick on/off" | Done: Toggle lights, per-light power, brightness, scenes, fade out; Action Button and Control Center through Shortcuts |
| One setting applied to several lights at once | DayBetter: wants one setting applied to multiple devices; Govee community: link strands so scenes run together | Partly: room power, scenes, room-wide effects. Next: **Room controls** sheet (color, white, brightness, effects for every light in the room) |
| Custom scenes you can save | LED Strip Light Controller (App Store) lists saved and shared scenes; Hue added scene reshuffle and favorites (Feb 2026) | Next: **Save as scene**, **Favorites**, **tap again to reshuffle** |
| Color from the real world / "From photo" | LED Strip Light Controller has a camera color picker; Magic Home Pro reviewers want a full-spectrum "From Photo" mode | Next: **Scene from a photo** |
| Effects with your own speed and colors | Magic Home Pro reviewers: customizable effect colors and speeds, faster speeds | Done: speed slider, Rainbow in sync. Next: **Living scenes** (palette scenes that drift) |
| Fire, candle and other natural effects | Hue Lights (third-party Hue app, 4.1 stars) sells fire, candle, thunderstorm and sunrise effects | Next: **Candlelight** and **Fireplace** |
| Schedules, wake-up and sleep | Govee and Magic Home list schedules; LED light control home added a sleep timer | Done through Shortcuts automations (Sunrise on alarm, Fade lights out on Sleep Focus), with a recipes screen. An in-app sleep timer can't run once the phone locks |
| Easy setup with troubleshooting | DayBetter FAQ: unplug the strip 10 s, toggle Bluetooth; LED Strip Light Controller ships step-by-step setup guides | Next: **Troubleshooting tips** in strip setup when nothing turns up |
| Seasonal and themed scenes | Hue adds Halloween and fall scenes every year | Next: **Halloween, Aggie Pride, Christmas, Valentine's** |
| No account, local control, privacy | Magic Home Pro reviewers object to signing in to a global server | Done: strips, Bluetooth bulbs and the IR bridge never touch the internet; only Hubspace needs its own cloud |

Left out on purpose:
- **Home-screen widgets and Control Center buttons inside the app** need an app extension and an App Group, fragile on a free Apple ID, and the widget couldn't use the app's Bluetooth links. Shortcuts covers the same uses.
- **AccessorySetupKit** would limit Bluetooth to accessories approved in Apple's picker and hide the bulbs and the IR bridge.
- **The strip's built-in mic mode** needs a command format that contradicts the one proven on the P031.
- **Segment control** only exists on "Magic Light" (HC) controllers, which the app doesn't drive yet.

Sources: DayBetter App Store reviews (apps.apple.com/us/app/daybetter/id6444903068); Magic Home Pro reviews (justuseapp.com/en/app/1187808229/magic-home-pro/reviews; appgrooves.com/app/magic-home-pro-by-led-controller);
LED Strip Light Controller (apps.apple.com/us/app/led-strip-light-controller/id6738105731); LED light control home (apps.apple.com/us/app/led-light-control-home/id1591730334);
Hue Lights (apps.apple.com/us/app/hue-lights/id762009425); Philips Hue app updates (9to5google.com, Jan 2026; notebookcheck.net); Govee community App Suggestions board; DayBetter FAQ (daybetter.net/frequently-asked-questions).

## Build order

1. **Your scenes**: Save as scene (captures every light in the room), Favorites row, delete; tap an active color scene again to reshuffle which light gets which color.
2. **Scene from a photo**: pick a photo, the app keeps its strongest colors and spreads them over the room. Saved under Yours.
3. **Seasonal scenes**: Halloween, Aggie Pride (NC A&T blue and gold), Christmas, Valentine's, also in Shortcuts.
4. **Living scenes**: a switch that makes color scenes drift slowly, each light handing its color to the next.
5. **Candlelight and Fireplace**: warm flicker driven from the phone, on every strip in the room.
6. **Reduce flashing**: hides blink, flash and strobe effects and softens music mode.
7. **Room controls**: one sheet for color, white, brightness and effects on the whole room.
8. **Setup troubleshooting**: tips appear when no strip shows up after a few seconds.
9. **Redesign**: same screens and features, better look and feel (type, depth, motion, haptics).
