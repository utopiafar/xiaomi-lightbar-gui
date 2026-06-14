/*
 * TLSR8516 SWS Flash Reader
 * Reads BLE MAC address from Telink TLSR8516 chip (Yeelight Remote Ctrl v0.3)
 * Last 3 bytes of MAC = Remote ID for lamp control.
 *
 * Wiring:
 *   Arduino D7 ---[1kΩ]--- SWS pad on TLSR8516
 *   Arduino GND ----------- GND on remote PCB
 *   Leave remote battery in place (powers the chip)
 *
 * Open Serial Monitor at 115200 after upload.
 */

#define SWS_PIN 7

// Bit period in microseconds — ~57600 baud (reliable for Arduino bitbang)
#define BIT_US 17

// ---- SWS low-level I/O ----

static void sws_idle() {
    pinMode(SWS_PIN, INPUT_PULLUP);
}

static void sws_write_bit(uint8_t b) {
    pinMode(SWS_PIN, OUTPUT);
    digitalWrite(SWS_PIN, b ? HIGH : LOW);
}

// Send one byte over SWS (8N1, LSB first)
static void sws_send(uint8_t val) {
    // Start bit
    sws_write_bit(0);
    delayMicroseconds(BIT_US);
    // Data bits
    for (int i = 0; i < 8; i++) {
        sws_write_bit((val >> i) & 1);
        delayMicroseconds(BIT_US);
    }
    // Stop bit
    sws_write_bit(1);
    delayMicroseconds(BIT_US);
    sws_idle();
    delayMicroseconds(BIT_US);
}

// Receive one byte over SWS; returns -1 on timeout
static int sws_recv() {
    sws_idle();
    // Wait for start bit (falling edge)
    uint32_t t = micros();
    while (digitalRead(SWS_PIN) && (micros() - t) < 10000UL);
    if ((micros() - t) >= 10000UL) return -1;
    // Sample in middle of first data bit
    delayMicroseconds(BIT_US + BIT_US / 2);
    uint8_t val = 0;
    for (int i = 0; i < 8; i++) {
        val |= (uint8_t)(digitalRead(SWS_PIN) & 1) << i;
        delayMicroseconds(BIT_US);
    }
    return val;
}

// ---- Telink SWS register bus ----
// Each SWS bus frame = 1 byte: bit7=1 → write register, bit7=0 → read register
// Bits[6:0] = SWS register index

static void sws_write_reg(uint8_t reg, uint8_t val) {
    sws_send(0x80 | reg);   // write command
    sws_send(val);
}

static int sws_read_reg(uint8_t reg) {
    sws_send(0x00 | reg);   // read command
    return sws_recv();
}

// ---- Telink AHB memory read via SWS register bridge ----
// SWS regs: 0x00=addr[7:0], 0x01=addr[15:8], 0x02=addr[23:16]
//           0x03=ctrl(0x80=trigger read), 0x04=data

static int sws_read_byte_at(uint32_t addr) {
    sws_write_reg(0x00,  addr        & 0xFF);
    sws_write_reg(0x01, (addr >> 8)  & 0xFF);
    sws_write_reg(0x02, (addr >> 16) & 0xFF);
    sws_write_reg(0x03, 0x80);          // trigger AHB read
    delayMicroseconds(50);
    return sws_read_reg(0x04);          // fetch result
}

// ---- Activation sequence ----
static void sws_activate() {
    // Long reset pulse → chip enters SWS mode
    pinMode(SWS_PIN, OUTPUT);
    digitalWrite(SWS_PIN, LOW);
    delay(5);
    digitalWrite(SWS_PIN, HIGH);
    delay(2);
    // Send 0x00 at our baud rate → chip auto-detects bit period
    sws_send(0x00);
    delay(2);
}

// ---- Read N bytes starting at addr ----
static bool sws_read_mem(uint32_t addr, uint8_t *buf, uint8_t n) {
    for (uint8_t i = 0; i < n; i++) {
        int b = sws_read_byte_at(addr + i);
        if (b < 0) return false;
        buf[i] = (uint8_t)b;
    }
    return true;
}

void setup() {
    Serial.begin(115200);
    sws_idle();
    delay(1000);

    Serial.println("=== TLSR8516 SWS Reader ===");
    Serial.println("Activating SWS interface...");

    sws_activate();

    // Known BLE MAC address locations in TLSR flash
    // MAC is 6 bytes; last 3 bytes = Remote ID
    const uint32_t candidates[] = {
        0x76000,   // most common for TLSR8x
        0x3F000,
        0x40006,
        0x60000,
    };
    const uint8_t N_CAND = sizeof(candidates) / sizeof(candidates[0]);

    for (uint8_t c = 0; c < N_CAND; c++) {
        uint8_t mac[6] = {};
        Serial.print("addr 0x");
        if (candidates[c] < 0x10000) Serial.print("0");
        Serial.print(candidates[c], HEX);
        Serial.print(" -> ");

        if (sws_read_mem(candidates[c], mac, 6)) {
            for (int i = 0; i < 6; i++) {
                if (mac[i] < 0x10) Serial.print("0");
                Serial.print(mac[i], HEX);
                if (i < 5) Serial.print(":");
            }
            Serial.print("  (Remote ID = ");
            if (mac[3] < 0x10) Serial.print("0");
            Serial.print(mac[3], HEX);
            Serial.print(":");
            if (mac[4] < 0x10) Serial.print("0");
            Serial.print(mac[4], HEX);
            Serial.print(":");
            if (mac[5] < 0x10) Serial.print("0");
            Serial.print(mac[5], HEX);
            Serial.println(")");
        } else {
            Serial.println("timeout — no response");
        }
        delay(100);
    }

    Serial.println("=== Done ===");
}

void loop() {}
