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
  server->advertiseOnDisconnect(true);
  NimBLEService *service = server->createService("DB00");
  service->createCharacteristic("DB01", NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR)->setCallbacks(new Commands());
  replies = service->createCharacteristic("DB02", NIMBLE_PROPERTY::NOTIFY);
  service->start();
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID("DB00");
  adv->setName("DormBridge");
  adv->start();
  Serial.println("DormBridge ready");
}

void loop() {
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
