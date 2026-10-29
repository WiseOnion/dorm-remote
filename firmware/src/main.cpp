// Dorm Remote IR bridge: the phone talks Bluetooth LE to this board, the board talks infrared to the projector.
// No Wi-Fi needed, so campus networks don't matter.
//
// GATT service 0xDB00:
//   0xDB01 write   command frames (below)
//   0xDB02 notify  replies
// Commands:
//   01 addrLo addrHi cmd     send an NEC / NEC-extended code (Flipper IRDB "address"/"command" bytes)
//   02 type bits v0..v7      send any IRremoteESP8266-decoded code (value little-endian), e.g. one learned below
//   10                       learn: report the next code seen on the IR receiver (needs the M5Stack IR Unit)
// Replies:
//   00 status                01 = sent, 02 = unsupported protocol
//   10 type bits v0..v7      learned code, same layout as command 02
//
// Presence: which side of your door you're on, from the signal of the board's own connection to your phone. A live
// connection keeps exchanging packets while the phone is locked in a pocket, unlike the advertisements passive
// room sensors (ESPresense, Bermuda) listen for, which a locked iPhone can stop sending. The engine:
//   readings every 300 ms → median of the last 5 (drops spikes) → smoothed → zone (room / doorway / hall), with
//   hysteresis at each boundary → a new zone only after it holds (about 1 s; 1.2 s for the hall) → events:
//   leaving = into the hall while home; arriving = into the doorway or room while away. Standing in the doorway and
//   going back in does nothing; after leaving, coming back through the doorway within 20 s needs to reach the room.
// A notification from a connected accessory wakes the app even in the background.
//   30 zone                  measure a zone for setup (0 hall, 1 doorway, 2 room): about 4 s of readings
//   31 room door hall        the zones' signals from setup, in dBm (signed bytes); all 0 = off
//   22                       read the link's signal now
//   32 on                    test mode: 1 streams every reading (reply 23), 0 stops
// Replies:
//   30 zone rssi             the measured zone's median signal (0 = no readings)
//   21 in rssi margin        01 = you arrived, 00 = you left; margin = dB past the boundary (confidence)
//   22 rssi                  the link's signal now, smoothed (0 = no reading yet)
//   23 raw filtered smooth zone candidate holds home margin   one reading, in test mode
//
// Room beacon: every other second the board advertises as an iBeacon (UUID D0A1E7B2-6F2C-4C8B-9E31-5B7A0C1D2E3F,
// major 1, minor 1), in the standard form (non-connectable, no scan response) and at -12 dBm, so iOS reports you
// "in range" near your door rather than down the hall. iOS relaunches an app for beacon region crossings even after it was swiped away, so the
// phone's Walk in knows when you come into and leave your room. The other second it advertises as DormBridge with
// service DB00, because iOS hides iBeacon advertisements from apps that scan with Core Bluetooth.
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <IRrecv.h>
#include <IRsend.h>
#include <IRutils.h>

// ATOM Lite pinout (docs.m5stack.com): built-in IR LED on G12; the IR Unit on the Grove port uses G26 (TX) and G32 (RX).
static const uint16_t kIrLed = 12;
static const uint16_t kIrUnitLed = 26;
static const uint16_t kIrReceiver = 32;

static IRsend irsend(kIrLed);
static IRsend irsendUnit(kIrUnitLed);
static IRrecv irrecv(kIrReceiver, 1024, 50, true);
static decode_results results;
static NimBLECharacteristic *replies;
static volatile bool learning = false;

static const uint8_t kBeacon[25] = {
  0x4C, 0x00,  // Apple
  0x02, 0x15,  // iBeacon, 21 bytes follow
  0xD0, 0xA1, 0xE7, 0xB2, 0x6F, 0x2C, 0x4C, 0x8B, 0x9E, 0x31, 0x5B, 0x7A, 0x0C, 0x1D, 0x2E, 0x3F,
  0x00, 0x01,  // major
  0x00, 0x01,  // minor
  0xB9,        // signal at 1 m: about -71 dBm at -12 dBm transmit power
};
static NimBLEAdvertisementData beaconFrame, bridgeFrame;
static bool showingBeacon = false;
static uint32_t lastSwap = 0;

// Presence state for the phone's connection.
static const uint16_t kNoPhone = 0xFFFF;
static volatile uint16_t phone = kNoPhone;
enum Zone : int8_t { Unknown = -1, Hall = 0, Door = 1, InRoom = 2 };
static int8_t zoneSignal[3] = {0, 0, 0};  // hall, doorway, room
static Zone zone = Unknown, candidate = Unknown;
static uint8_t holds = 0;
static int8_t home = -1;  // -1 not known yet, 0 away, 1 home
static uint32_t lastLeave = 0, lastSample = 0;
static int8_t recent[5];
static uint8_t recentCount = 0, recentAt = 0;
static float smooth = 0;
static int8_t measuringZone = -1;
static int8_t measured[16];
static uint8_t measuredCount = 0;
static uint32_t measureStart = 0;
static bool streaming = false;

// Advertising stops when the phone connects; keep it going so the beacon stays visible while you're home.
class KeepAdvertising : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &info) override {
    phone = info.getConnHandle();
    smooth = 0;
    recentCount = 0;
    zone = candidate = Unknown;
    holds = 0;
    NimBLEDevice::startAdvertising();
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &info, int reason) override {
    if (info.getConnHandle() != phone) return;
    phone = kNoPhone;
    // Out of range: you're away. Coming back through the doorway is then an arrival.
    if (zoneSignal[0] != 0) home = 0;
  }
};

static void reply(const uint8_t *data, size_t len) {
  replies->setValue(data, len);
  replies->notify();
}

static bool sendDecoded(decode_type_t type, uint16_t bits, uint64_t value) {
  // Both LEDs, so the bridge works with or without the IR Unit attached.
  bool ok = irsend.send(type, value, bits);
  irsendUnit.send(type, value, bits);
  return ok;
}

class Commands : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &info) override {
    NimBLEAttValue v = c->getValue();
    if (v.size() == 0) return;
    const uint8_t *b = reinterpret_cast<const uint8_t *>(v.data());
    switch (b[0]) {
      case 0x01: {
        if (v.size() < 4) return;
        uint16_t address = b[1] | (b[2] << 8);
        // Plain NEC repeats the address inverted; encodeNEC adds that itself for 8-bit addresses.
        if (b[2] == static_cast<uint8_t>(~b[1])) address = b[1];
        uint32_t code = irsend.encodeNEC(address, b[3]);
        irsend.sendNEC(code);
        irsendUnit.sendNEC(code);
        uint8_t ok[] = {0x00, 0x01};
        reply(ok, sizeof ok);
        break;
      }
      case 0x02: {
        if (v.size() < 11) return;
        uint64_t value = 0;
        for (int i = 7; i >= 0; i--) value = (value << 8) | b[3 + i];
        uint8_t status[] = {0x00, static_cast<uint8_t>(sendDecoded((decode_type_t)b[1], b[2], value) ? 0x01 : 0x02)};
        reply(status, sizeof status);
        break;
      }
      case 0x10:
        learning = true;
        irrecv.resume();
        break;
      case 0x30:
        if (v.size() < 2 || b[1] > 2) return;
        measuringZone = b[1];
        measuredCount = 0;
        measureStart = millis();
        break;
      case 0x32:
        if (v.size() < 2) return;
        streaming = b[1] == 1;
        break;
      case 0x31:
        if (v.size() < 4) return;
        zoneSignal[2] = static_cast<int8_t>(b[1]);
        zoneSignal[1] = static_cast<int8_t>(b[2]);
        zoneSignal[0] = static_cast<int8_t>(b[3]);
        zone = candidate = Unknown;
        holds = 0;
        break;
      case 0x22: {
        uint8_t out[] = {0x22, static_cast<uint8_t>(static_cast<int8_t>(lroundf(smooth)))};
        reply(out, sizeof out);
        break;
      }
    }
  }
};

void setup() {
  Serial.begin(115200);
  irsend.begin();
  irsendUnit.begin();
  irrecv.enableIRIn();

  NimBLEDevice::init("DormBridge");
  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new KeepAdvertising());
  server->advertiseOnDisconnect(true);
  NimBLEService *service = server->createService("DB00");
  service->createCharacteristic("DB01", NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR)->setCallbacks(new Commands());
  replies = service->createCharacteristic("DB02", NIMBLE_PROPERTY::NOTIFY);
  service->start();
  beaconFrame.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  beaconFrame.setManufacturerData(kBeacon, sizeof kBeacon);
  bridgeFrame.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  bridgeFrame.setName("DormBridge");
  bridgeFrame.addServiceUUID("DB00");
  NimBLEAdvertisementData scan;
  scan.setName("DormBridge");
  scan.addServiceUUID("DB00");
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->setAdvertisementData(bridgeFrame);
  adv->setScanResponseData(scan);
  adv->enableScanResponse(true);
  adv->start();
  Serial.println("DormBridge ready");
}

static int8_t median5() {
  int8_t s[5];
  for (uint8_t i = 0; i < recentCount; i++) s[i] = recent[i];
  for (uint8_t i = 1; i < recentCount; i++)
    for (uint8_t j = i; j > 0 && s[j - 1] > s[j]; j--) { int8_t t = s[j]; s[j] = s[j - 1]; s[j - 1] = t; }
  return s[recentCount / 2];
}

// Boundaries halfway between the zones' signals, with 2.5 dB of hysteresis that favors staying where you are.
static Zone classify(float s) {
  const float h = 2.5f;
  float inside = (zoneSignal[2] + zoneSignal[1]) / 2.0f, outside = (zoneSignal[1] + zoneSignal[0]) / 2.0f;
  switch (zone) {
    case InRoom: return s >= inside - h ? InRoom : (s >= outside - h ? Door : Hall);
    case Hall:   return s <= outside + h ? Hall : (s <= inside + h ? Door : InRoom);
    case Door:   return s > inside + h ? InRoom : (s < outside - h ? Hall : Door);
    default:     return s >= inside ? InRoom : (s >= outside ? Door : Hall);
  }
}

static void event(bool arrived, float s) {
  float outside = (zoneSignal[1] + zoneSignal[0]) / 2.0f;
  int margin = static_cast<int>(lroundf(arrived ? s - outside : outside - s));
  uint8_t out[] = {0x21, static_cast<uint8_t>(arrived ? 1 : 0), static_cast<uint8_t>(static_cast<int8_t>(lroundf(s))),
                   static_cast<uint8_t>(constrain(margin, 0, 127))};
  reply(out, sizeof out);
}

static void moved(Zone to, float s) {
  Zone from = zone;
  zone = to;
  if (home == -1) {  // first zone after power-up: just note where you are
    home = to == Hall ? 0 : 1;
    return;
  }
  if (to == Hall && home == 1) {
    home = 0;
    lastLeave = millis();
    event(false, s);
  } else if (to != Hall && home == 0) {
    // Lingering outside your door right after leaving shouldn't bring the lights back: within 20 s, only the room counts.
    if (to == Door && millis() - lastLeave < 20000) return;
    home = 1;
    event(true, s);
  }
  (void)from;
}

// Every 300 ms: one reading, filtered, classified, and committed once it holds.
static void watchPresence() {
  if (phone == kNoPhone || millis() - lastSample < 300) return;
  lastSample = millis();
  int8_t rssi;
  if (ble_gap_conn_rssi(phone, &rssi) != 0 || rssi == 127) return;
  recent[recentAt] = rssi;
  recentAt = (recentAt + 1) % 5;
  if (recentCount < 5) recentCount++;
  int8_t filtered = median5();
  smooth = smooth == 0 ? filtered : smooth * 0.6f + filtered * 0.4f;

  if (measuringZone >= 0) {
    if (measuredCount < 16) measured[measuredCount++] = filtered;
    if (millis() - measureStart > 4000) {
      int8_t s[16];
      for (uint8_t i = 0; i < measuredCount; i++) s[i] = measured[i];
      for (uint8_t i = 1; i < measuredCount; i++)
        for (uint8_t j = i; j > 0 && s[j - 1] > s[j]; j--) { int8_t t = s[j]; s[j] = s[j - 1]; s[j - 1] = t; }
      uint8_t out[] = {0x30, static_cast<uint8_t>(measuringZone), static_cast<uint8_t>(measuredCount ? s[measuredCount / 2] : 0)};
      reply(out, sizeof out);
      measuringZone = -1;
    }
    return;
  }
  if (zoneSignal[0] != 0 && recentCount >= 3) {
    Zone now = classify(smooth);
    if (now == zone) {
      holds = 0;
    } else {
      if (now != candidate) {
        candidate = now;
        holds = 0;
      }
      if (++holds >= (now == Hall ? 4 : 3)) {
        holds = 0;
        moved(now, smooth);
      }
    }
  }
  if (streaming) {
    // Confidence: how far the signal sits from the nearest boundary.
    float inside = (zoneSignal[2] + zoneSignal[1]) / 2.0f, outside = (zoneSignal[1] + zoneSignal[0]) / 2.0f;
    float margin = zoneSignal[0] == 0 ? 0 : fminf(fabsf(smooth - inside), fabsf(smooth - outside));
    uint8_t out[] = {0x23, static_cast<uint8_t>(rssi), static_cast<uint8_t>(filtered),
                     static_cast<uint8_t>(static_cast<int8_t>(lroundf(smooth))), static_cast<uint8_t>(zone),
                     static_cast<uint8_t>(candidate), holds, static_cast<uint8_t>(home),
                     static_cast<uint8_t>(constrain(static_cast<int>(lroundf(margin)), 0, 127))};
    reply(out, sizeof out);
  }
}

void loop() {
  watchPresence();
  if (millis() - lastSwap > 1000) {
    lastSwap = millis();
    showingBeacon = !showingBeacon;
    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->stop();
    adv->setConnectableMode(showingBeacon ? BLE_GAP_CONN_MODE_NON : BLE_GAP_CONN_MODE_UND);
    adv->enableScanResponse(!showingBeacon);
    NimBLEDevice::setPower(showingBeacon ? -12 : 9, NimBLETxPowerType::Advertise);
    adv->setAdvertisementData(showingBeacon ? beaconFrame : bridgeFrame);
    adv->start();
  }
  if (learning && irrecv.decode(&results)) {
    if (!results.repeat && results.decode_type != UNKNOWN) {
      uint8_t out[11] = {0x10, static_cast<uint8_t>(results.decode_type), static_cast<uint8_t>(results.bits)};
      for (int i = 0; i < 8; i++) out[3 + i] = (results.value >> (8 * i)) & 0xFF;
      reply(out, sizeof out);
      learning = false;
      Serial.println(resultToHumanReadableBasic(&results));
    }
    irrecv.resume();
  }
  delay(5);
}
