# auto-lamp

Control a **Xiaomi Mi Computer Monitor Light Bar (MJGJD01YL)** from any computer
over USB, using a cheap **RF-NANO** board (Arduino Nano + nRF24L01) as a
2.4 GHz radio bridge.

```
PC  ──USB/serial──  RF-NANO (ATmega328P + nRF24L01)  ──2.4 GHz RF──  Light Bar
host CLI / library         generic serial bridge firmware           Telink TLSR8368
```

Unlike most existing projects, this one is **host-driven**: the radio logic
lives in a small firmware that speaks a plain text protocol over the serial
port, and a cross-platform host program (Go CLI here) drives it. You do **not**
need a Raspberry Pi, and you do **not** need the original remote — see
[Pairing](#pairing-no-remote-needed).

> The radio protocol itself was reverse-engineered by
> [**lamperez/xiaomi-lightbar-nrf24**](https://github.com/lamperez/xiaomi-lightbar-nrf24).
> This project builds a host-over-serial layer on top of that work. See
> [Credits](#credits).

---

## Hardware we used

| Part | Exact model | Notes |
|------|-------------|-------|
| Lamp | **Xiaomi Mi Computer Monitor Light Bar `MJGJD01YL`** | The non-BLE version controlled by a wireless rotary remote |
| Radio bridge | **RF-NANO** (Arduino Nano clone with an on-board nRF24L01) | `CE=D10`, `CSN=D9` on our unit (some revisions swap these) |
| Cable | USB → Mini/Micro-USB | Whatever your RF-NANO uses |

A plain Arduino Nano + a separate nRF24L01+ module works too; just wire
`CE`/`CSN`/SPI and adjust the pin `#define`s in the firmware.

The lamp's remote uses a Telink TLSR8368, which is *almost* nRF24-compatible at
the PHY level, which is what makes this hack possible.

---

## How it works

* Only the remote (and our bridge) ever transmit; the lamp is a pure receiver,
  like a wireless-mouse dongle. There is no acknowledgement or pairing crypto.
* The lamp accepts commands from any 3-byte "remote ID" it has been bound to.
* You can bind the lamp to **any ID you choose** by sending a `reset` command
  within a short window after powering the lamp on. No original remote needed.

Full byte-level details: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

---

## Quick start

### 1. Flash the firmware

Uses [PlatformIO](https://platformio.org/):

```bash
cd firmware
pio run -t upload
```

> Old bootloader? Change `nanoatmega328new` → `nanoatmega328` in `platformio.ini`.
> `NRF24 init failed` on boot? Swap `CE_PIN`/`CSN_PIN` in `src/main.cpp`.

On boot the board prints `READY` over serial once the nRF24 initializes.

### 2. Build the host CLI

Requires Go 1.22+.

```bash
go build -o lamp ./cmd/lamp
```

### 3. Pair (no remote needed!)

```bash
./lamp pair --port /dev/cu.usbserial-10     # macOS example; pick your port
# Linux:   /dev/ttyUSB0
# Windows: COM3
```

Follow the prompt: unplug the lamp, plug it back in, then press Enter within a
few seconds. The lamp **flashes once** when it binds to the chosen ID
(default `11:11:11`). The port and ID are saved to a config file, so you can
drop `--port` afterwards.

### 4. Control it

```bash
./lamp on            # on/off (it is a single toggle)
./lamp bright +5     # brightness up   (step 1..15)
./lamp bright -3     # brightness down
./lamp warm +5       # cooler  (see note in CLI reference)
./lamp warm -2       # warmer
```

---

## CLI reference

```
lamp <command> [--port DEV] [arg]

  pair  [AA:BB:CC]   Bind the lamp to an ID of your choice (no original remote needed).
                     Defaults to the saved ID, then to 11:11:11.
  scan               Listen for the original remote's ID and save it (Ctrl-C to stop).
  set-id [AA:BB:CC]  Write a Remote ID to firmware EEPROM + config manually.
  on / off           Toggle the lamp (same code; the lamp has no discrete on/off).
  bright +N | -N     Brightness step, N = 1..15.
  warm   +N | -N     Colour-temperature step, N = 1..15.
  reset              Factory-reset the lamp.
  config             Show the saved port and ID.

  --port DEV         Serial device. Defaults to config, then /dev/ttyUSB0.
```

**Notes / gotchas**

* `on` and `off` send the **same** toggle code (`0x01 0x00`); the protocol has
  no absolute on/off. Each call flips the current state.
* `warm +N` currently sends the *cooler* code (`0x02`) and `warm -N` the
  *warmer* code (`0x03`). Rename to taste — see [`TODO.md`](TODO.md).
* Don't run two `lamp` processes at once → `Serial port busy`.
* Brightness/warm values are signed (`-3`), parsed manually so the shell/flags
  don't choke on the leading `-`.

---

## Project layout

```
lib/
├── firmware/
│   ├── platformio.ini       # PlatformIO: atmelavr / nanoatmega328new / RF24
│   ├── src/main.cpp          # serial-bridge firmware (protocol + UART parser)
│   └── sws_reader/           # optional: read the remote's ID off its Telink chip via SWS
├── cmd/lamp/main.go          # host CLI
├── internal/
│   ├── config/               # config file (~/.config/lamp/config.json)
│   └── serial/               # serial port wrapper (115200, READY handshake)
├── docs/PROTOCOL.md          # byte-level protocol + attribution
├── TODO.md                   # roadmap to turn this into a real library
├── go.mod                    # module: github.com/alxndrchernov/auto-lamp
└── LICENSE
```

---

## Credits

* **Protocol reverse engineering:**
  [lamperez/xiaomi-lightbar-nrf24](https://github.com/lamperez/xiaomi-lightbar-nrf24)
  — packet format, CRC parameters, command codes, and the power-cycle pairing
  trick all come from this work.
* Related implementations and prior art:
  * [ebinf/lightbar2mqtt](https://github.com/ebinf/lightbar2mqtt) — ESP32 + MQTT / Home Assistant
  * [BAJ810/xiaomi-lightbar-nrf24-esp32](https://github.com/BAJ810/xiaomi-lightbar-nrf24-esp32)
  * [eugene-reim/lightbar2mqtt-esp8268](https://github.com/eugene-reim/lightbar2mqtt-esp8268)
  * [benallen-dev/xiaomi-lightbar](https://github.com/benallen-dev/xiaomi-lightbar) — Arduino Nano sketch

What this project adds over the above: a **host-driven, cross-platform**
control path (PC ↔ USB-serial ↔ generic bridge firmware) and a **pairing-first**
workflow that needs neither a Raspberry Pi nor the original remote.

## License

MIT — see [LICENSE](LICENSE).
