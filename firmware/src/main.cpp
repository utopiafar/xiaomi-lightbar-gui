/*
 * auto-lamp firmware for RF-NANO (ATmega328P + NRF24L01)
 * Controls Xiaomi Mijia MJGJD01YL via Telink 2.4GHz RF protocol.
 *
 * RF-NANO built-in NRF24 pins:
 *   CE  = D10 (some revisions use D9  — adjust CE_PIN below)
 *   CSN = D9  (some revisions use D10 — adjust CSN_PIN below)
 *   SCK = D13, MOSI = D11, MISO = D12 (hardware SPI)
 */

#include <Arduino.h>
#include <EEPROM.h>
#include <SPI.h>
#include <RF24.h>
#include "SequenceCounter.h"

// ----- Pin definitions (swap if needed for your RF-NANO revision) -----
#define CE_PIN  10
#define CSN_PIN  9

// ----- Protocol constants -----
// TX framing follows the proven lamperez/xiaomi-lightbar-nrf24 scheme:
// the NRF24 address is the 5-byte sync run 0x5555555555, and the WHOLE
// 17-byte Telink packet (preamble included) is sent as the payload. This
// gives the Telink receiver the long sync run it needs to lock on.
#define TX_PAYLOAD_SIZE 17

// Fixed 8-byte preamble (same for all MJGJD01YL lamps)
static const uint8_t PREAMBLE[8] = {
    0x53, 0x39, 0x14, 0xDD, 0x1C, 0x49, 0x34, 0x12
};

// RF channels (2406, 2443, 2468 MHz)
static const uint8_t CHANNELS[3] = {6, 43, 68};

// NRF24 TX address — 5-byte sync run that precedes the Telink preamble.
static const uint8_t SYNC_ADDR[5] = {0x55, 0x55, 0x55, 0x55, 0x55};
// The remote's sync stream can be captured as an nRF24 address. This receive
// framing and bit realignment follow ebinf/lightbar2mqtt (MIT); see the
// included third-party license.
static const uint8_t RX_PIPE_ADDR[5] = {0xAA, 0xAA, 0xAA, 0xAA, 0xAA};
#define SCAN_PAYLOAD_SIZE 17

// ----- EEPROM layout -----
#define EEPROM_MAGIC_VAL  0xAB
#define EEPROM_ADDR_MAGIC 0
#define EEPROM_ADDR_ID    1   // 3 bytes: remoteId[0..2]
#define EEPROM_ADDR_SEQ   4   // 1 byte: persisted sequence counter

// ----- State -----
RF24 radio(CE_PIN, CSN_PIN);

uint8_t remoteId[3] = {0x00, 0x00, 0x00};
SequenceCounter seqCounter;
bool    scanning    = false;
bool    scanDiagnostic = false;
bool    sniffing    = false;
bool    sniff1Mbps  = false;  // false=2Mbps, true=1Mbps
bool    radioReady  = false;

// ----- EEPROM helpers -----
static void loadIdFromEEPROM() {
    // Skip beyond the previous block on boot and persist the new starting
    // point, so even an interrupted block cannot repeat its last counter.
    EEPROM.update(EEPROM_ADDR_SEQ, seqCounter.begin(EEPROM.read(EEPROM_ADDR_SEQ)));

    if (EEPROM.read(EEPROM_ADDR_MAGIC) != EEPROM_MAGIC_VAL) return;
    remoteId[0] = EEPROM.read(EEPROM_ADDR_ID);
    remoteId[1] = EEPROM.read(EEPROM_ADDR_ID + 1);
    remoteId[2] = EEPROM.read(EEPROM_ADDR_ID + 2);
}

static void saveIdToEEPROM() {
    // EEPROM.update() writes only if value changed — saves write cycles
    EEPROM.update(EEPROM_ADDR_MAGIC,     EEPROM_MAGIC_VAL);
    EEPROM.update(EEPROM_ADDR_ID,        remoteId[0]);
    EEPROM.update(EEPROM_ADDR_ID + 1,    remoteId[1]);
    EEPROM.update(EEPROM_ADDR_ID + 2,    remoteId[2]);
}

// ----- LFSR whitening -----
// Seed and poly taken from community reverse engineering of TLSR8368
// (same as used in ebinf/lightbar2mqtt and lamperez/xiaomi-lightbar-nrf24)
static void whiten(uint8_t *buf, uint8_t len, uint8_t seed) {
    uint8_t lfsr = seed;
    for (uint8_t i = 0; i < len; i++) {
        uint8_t byte = 0;
        for (int8_t b = 7; b >= 0; b--) {
            byte |= ((lfsr >> 7) & 1) << b;
            // feedback: bit7 XOR bit4 (poly 0x11, Telink BLE-like)
            lfsr = (lfsr << 1) ^ (((lfsr >> 7) & 1) ? 0x11 : 0x00);
        }
        buf[i] ^= byte;
    }
}

// ----- CRC16 (CCITT, poly=0x1021, init=0xFFFE, no reflection) -----
static uint16_t crc16(const uint8_t *buf, uint8_t len) {
    uint16_t crc = 0xFFFE;
    for (uint8_t i = 0; i < len; i++) {
        crc ^= (uint16_t)buf[i] << 8;
        for (uint8_t b = 0; b < 8; b++) {
            if (crc & 0x8000)
                crc = (crc << 1) ^ 0x1021;
            else
                crc <<= 1;
        }
    }
    return crc;
}

// ----- Build the full 17-byte TX packet -----
// Layout: preamble[8] + id[3] + 0xFF + counter + cmd1 + cmd2 + crc16[2].
// The whole packet is the NRF24 payload (no software whitening); the sync
// run lives in the NRF24 address (SYNC_ADDR). CRC covers bytes [0..14].
static void buildPacket(uint8_t *pkt, uint8_t cmd1, uint8_t cmd2) {
    memcpy(pkt, PREAMBLE, 8);
    pkt[8]  = remoteId[0];
    pkt[9]  = remoteId[1];
    pkt[10] = remoteId[2];
    pkt[11] = 0xFF;
    pkt[12] = seqCounter.next();
    pkt[13] = cmd1;
    pkt[14] = cmd2;
    uint16_t crc = crc16(pkt, 15);
    pkt[15] = (crc >> 8) & 0xFF;
    pkt[16] =  crc        & 0xFF;
}

// ----- Send command: one packet (one counter) blasted 20× × 3 channels -----
// The counter MUST stay fixed for the whole burst: the lamp treats each new
// counter value as a fresh button press. Building the packet once (single
// counter advance) means the lamp registers exactly one logical command, while the
// repetitions and channel hopping just buy reception reliability.
static void sendCommand(uint8_t cmd1, uint8_t cmd2) {
    uint8_t pkt[TX_PAYLOAD_SIZE];
    buildPacket(pkt, cmd1, cmd2);   // single counter for the entire burst
    // Persist once per block, rather than on every slider update.
    if (seqCounter.needsCheckpoint()) {
        EEPROM.update(EEPROM_ADDR_SEQ, seqCounter.checkpoint());
    }

    radio.stopListening();

    for (uint8_t rep = 0; rep < 20; rep++) {
        for (uint8_t ch = 0; ch < 3; ch++) {
            radio.setChannel(CHANNELS[ch]);
            radio.write(pkt, TX_PAYLOAD_SIZE);
            delayMicroseconds(100);
        }
    }
}

// ----- NRF24 initialisation -----
static bool initRadio() {
    if (!radio.begin()) return false;

    radio.setPALevel(RF24_PA_MAX);
    radio.setDataRate(RF24_2MBPS);
    radio.setCRCLength(RF24_CRC_DISABLED);
    radio.setAutoAck(false);
    radio.disableDynamicPayloads();
    radio.setPayloadSize(TX_PAYLOAD_SIZE);
    radio.setAddressWidth(5);

    radio.openWritingPipe(SYNC_ADDR);
    radio.openReadingPipe(1, SYNC_ADDR);

    radio.stopListening();
    return true;
}

// ----- Scan (RX sniffer) mode helpers -----
static void startScan() {
    scanning = true;
    scanDiagnostic = false;
    radio.setPayloadSize(SCAN_PAYLOAD_SIZE);
    radio.openReadingPipe(1, RX_PIPE_ADDR);
    radio.setChannel(68);  // fixed 2468 MHz, as used by lightbar2mqtt
    radio.startListening();
}

static void stopScan() {
    scanning = false;
    radio.stopListening();
    radio.setPayloadSize(TX_PAYLOAD_SIZE);
    radio.openWritingPipe(SYNC_ADDR);
}

// ----- Promiscuous sniffer -----
static const uint8_t SNIFF_ADDR[2] = {0xAA, 0xAA};
#define SNIFF_PAYLOAD 32

static void startSniff(bool use1Mbps) {
    sniffing   = true;
    sniff1Mbps = use1Mbps;
    radio.setDataRate(use1Mbps ? RF24_1MBPS : RF24_2MBPS);
    radio.setAddressWidth(2);
    radio.setPayloadSize(SNIFF_PAYLOAD);
    radio.openReadingPipe(1, SNIFF_ADDR);
    radio.setChannel(2);
    radio.startListening();
}

static void stopSniff() {
    sniffing = false;
    radio.stopListening();
    radio.setDataRate(RF24_2MBPS);
    radio.setAddressWidth(5);
    radio.setPayloadSize(TX_PAYLOAD_SIZE);
    radio.openWritingPipe(SYNC_ADDR);
}

static void processSniff() {
    if (!sniffing) return;

    // Rotate through channels: 2Mbps → 6,43,68; 1Mbps → 2,26,80
    static uint8_t chIdx = 0;
    static uint32_t lastRotate = 0;
    const uint8_t ch2M[3] = {6, 43, 68};
    const uint8_t ch1M[3] = {2, 26, 80};
    const uint8_t *chs = sniff1Mbps ? ch1M : ch2M;

    if (millis() - lastRotate > 15) {
        chIdx = (chIdx + 1) % 3;
        radio.stopListening();
        radio.setChannel(chs[chIdx]);
        radio.startListening();
        lastRotate = millis();
    }

    if (!radio.available()) return;

    uint8_t buf[SNIFF_PAYLOAD];
    radio.read(buf, SNIFF_PAYLOAD);

    Serial.print("CH");
    Serial.print(chs[chIdx]);
    Serial.print(":");
    for (uint8_t i = 0; i < SNIFF_PAYLOAD; i++) {
        if (buf[i] < 0x10) Serial.print("0");
        Serial.print(buf[i], HEX);
        if (i < SNIFF_PAYLOAD - 1) Serial.print(" ");
    }
    Serial.println();
}

// Check for received packets and print any Remote ID found
static void processScan() {
    if (!scanning) return;

    if (!radio.available()) return;

    // The nRF24 has consumed part of the Telink preamble as its own address
    // and packet-control bits. Restore the missing upper five bits and align
    // the remaining stream (as in lightbar2mqtt's Radio::handlePackage).
    uint8_t raw[SCAN_PAYLOAD_SIZE];
    uint8_t data[TX_PAYLOAD_SIZE];
    radio.read(raw, sizeof(raw));
    data[0] = 0x50 | (raw[0] >> 5);
    for (uint8_t i = 1; i < sizeof(data); i++) {
        data[i] = (uint8_t)((raw[i - 1] << 3) | (raw[i] >> 5));
    }
    if (scanDiagnostic) {
        static uint32_t lastReport = 0;
        if (millis() - lastReport > 250) {
            Serial.print("RAW:");
            for (uint8_t i = 0; i < sizeof(raw); i++) {
                if (raw[i] < 0x10) Serial.print("0");
                Serial.print(raw[i], HEX);
            }
            Serial.println();
            lastReport = millis();
        }
    }
    if (memcmp(data, PREAMBLE, sizeof(PREAMBLE)) != 0 || data[11] != 0xFF) return;
    uint16_t expected = ((uint16_t)data[15] << 8) | data[16];
    if (crc16(data, 15) != expected) return;

    char id[9];
    snprintf(id, sizeof(id), "%02X:%02X:%02X", data[8], data[9], data[10]);
    Serial.print("FOUND:");
    Serial.println(id);
}

// ----- Parse hex byte from two ASCII chars -----
static bool parseHexByte(const char *s, uint8_t *out) {
    char tmp[3] = {s[0], s[1], '\0'};
    char *end;
    long val = strtol(tmp, &end, 16);
    if (end != tmp + 2) return false;
    *out = (uint8_t)val;
    return true;
}

// ----- Serial command parser -----
static char lineBuf[64];
static uint8_t lineLen = 0;

static void handleLine(char *line) {
    // Trim trailing \r
    uint8_t len = strlen(line);
    if (len && line[len - 1] == '\r') line[--len] = '\0';

    if (strcmp(line, "PING") == 0) {
        Serial.println(radioReady ? "READY" : "ERR NRF24 init failed");

    } else if (strcmp(line, "EEPROM_DUMP") == 0) {
        // Some Nano bootloaders return flash bytes when asked to read EEPROM.
        // This permits an accurate backup before the bridge writes its ID.
        Serial.print("EEPROM:");
        for (uint16_t i = 0; i < EEPROM.length(); i++) {
            uint8_t value = EEPROM.read(i);
            if (value < 0x10) Serial.print("0");
            Serial.print(value, HEX);
        }
        Serial.println();

    } else if (!radioReady) {
        Serial.println("ERR NRF24 init failed");

    } else if (strncmp(line, "SCAN_DIAG ", 10) == 0) {
        int channel = atoi(line + 10);
        if (channel < 0 || channel > 125) {
            Serial.println("ERR bad channel");
            return;
        }
        startScan();
        scanDiagnostic = true;
        radio.stopListening();
        radio.setChannel((uint8_t)channel);
        radio.startListening();
        Serial.println("OK");

    } else if (strcmp(line, "SCAN") == 0) {
        startScan();
        Serial.println("OK");

    } else if (strcmp(line, "SCAN_STOP") == 0) {
        stopScan();
        Serial.println("OK");

    } else if (strcmp(line, "SNIFF2") == 0) {
        startSniff(false);
        Serial.println("OK");

    } else if (strcmp(line, "SNIFF1") == 0) {
        startSniff(true);
        Serial.println("OK");

    } else if (strcmp(line, "SNIFF_STOP") == 0) {
        stopSniff();
        Serial.println("OK");

    } else if (strcmp(line, "ON") == 0) {
        sendCommand(0x01, 0x00);
        Serial.println("OK");

    } else if (strcmp(line, "OFF") == 0) {
        sendCommand(0x01, 0x00);
        Serial.println("OK");

    } else if (strcmp(line, "RESET") == 0) {
        sendCommand(0x06, 0x00);
        Serial.println("OK");

    } else if (strcmp(line, "PAIR") == 0) {
        // Pairing == reset (0x06 0x00) sent within ~20 s of powering the
        // lamp on. The lamp binds to the current remoteId and flashes once.
        // Send an extra-long burst to be safe during the pairing window.
        for (uint8_t i = 0; i < 5; i++) sendCommand(0x06, 0x00);
        Serial.println("OK");

    } else if (strncmp(line, "ID ", 3) == 0) {
        // Format: "ID AA:BB:CC"
        char *p = line + 3;
        if (strlen(p) < 8) { Serial.println("ERR bad ID format"); return; }
        uint8_t a, b, c;
        if (!parseHexByte(p,     &a) ||
            !parseHexByte(p + 3, &b) ||
            !parseHexByte(p + 6, &c)) {
            Serial.println("ERR bad ID hex");
            return;
        }
        remoteId[0] = a;
        remoteId[1] = b;
        remoteId[2] = c;
        saveIdToEEPROM();
        Serial.println("OK");

    } else if (strncmp(line, "CMD ", 4) == 0) {
        // Format: "CMD HH HH"
        char *p = line + 4;
        if (strlen(p) < 5) { Serial.println("ERR bad CMD format"); return; }
        uint8_t c1, c2;
        if (!parseHexByte(p,     &c1) ||
            !parseHexByte(p + 3, &c2)) {
            Serial.println("ERR bad CMD hex");
            return;
        }
        sendCommand(c1, c2);
        Serial.println("OK");

    } else if (strncmp(line, "BRIGHT ", 7) == 0) {
        // Format: "BRIGHT +N" or "BRIGHT -N"
        char *p = line + 7;
        int n = atoi(p);
        if (n > 0) {
            uint8_t step = (uint8_t)(n & 0x0F);
            if (step == 0) step = 1;
            sendCommand(0x04, step);
        } else if (n < 0) {
            int s = -n;
            uint8_t step = (uint8_t)(0x100 - (s & 0xFF));
            sendCommand(0x05, step);
        } else {
            Serial.println("ERR bad BRIGHT value");
            return;
        }
        Serial.println("OK");

    } else if (strncmp(line, "WARM ", 5) == 0) {
        // Format: "WARM +N" or "WARM -N"
        char *p = line + 5;
        int n = atoi(p);
        if (n > 0) {
            uint8_t step = (uint8_t)(n & 0x0F);
            if (step == 0) step = 1;
            sendCommand(0x02, step);
        } else if (n < 0) {
            int s = -n;
            uint8_t step = (uint8_t)(0x100 - (s & 0xFF));
            sendCommand(0x03, step);
        } else {
            Serial.println("ERR bad WARM value");
            return;
        }
        Serial.println("OK");

    } else if (strcmp(line, "GET_ID") == 0) {
        if (EEPROM.read(EEPROM_ADDR_MAGIC) != EEPROM_MAGIC_VAL) {
            Serial.println("ID:none");
        } else {
            char buf[9];
            sprintf(buf, "%02X:%02X:%02X", remoteId[0], remoteId[1], remoteId[2]);
            Serial.print("ID:");
            Serial.println(buf);
        }

    } else {
        Serial.print("ERR unknown command: ");
        Serial.println(line);
    }
}

// ----- Arduino entry points -----
void setup() {
    Serial.begin(115200);
    loadIdFromEEPROM();
    radioReady = initRadio();
    if (!radioReady) {
        Serial.println("ERR NRF24 init failed");
    } else {
        Serial.println("READY");
    }
}

void loop() {
    // Read Serial line-by-line
    while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\n') {
            lineBuf[lineLen] = '\0';
            if (lineLen > 0) handleLine(lineBuf);
            lineLen = 0;
        } else if (lineLen < sizeof(lineBuf) - 1) {
            lineBuf[lineLen++] = c;
        }
    }

    processScan();
    processSniff();
}
