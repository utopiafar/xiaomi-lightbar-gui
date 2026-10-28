# xiaomi-lightbar-mac

[English](README.md) | [简体中文](README.zh-CN.md)

An independent macOS menu bar controller for the **first-generation Xiaomi Mi
Computer Monitor Light Bar (MJGJD01YL)**. An RF-Nano board connected over USB
acts as the 2.4 GHz radio bridge; no Bluetooth, cloud account, or Home Assistant
is needed.

<img src="assets/app-icon.png" alt="An illustrated monitor with a light bar" width="128">

> **Early-stage project.** A power toggle has been confirmed on one physical
> lamp with a saved remote ID. Remote-ID scanning and the slider command flow
> have automated serial-simulator coverage, but have not yet been confirmed
> on a broad range of physical devices. Please report your hardware and results.

## What it does

- Open a compact controller from the Mac menu bar; control power, brightness,
  and color temperature with a button and sliders.
- Read the original remote's ID and save it to the RF-Nano, so the Mac can
  transmit using that ID without deliberately re-pairing the lamp.
- Offer a separate computer-pairing flow if reading the original remote fails.
- Run locally using a native SwiftUI app and a small Arduino-compatible firmware.

The lamp sends no status back. The power button **toggles** rather than setting
an explicit on/off state. Slider positions are requested targets, not measured
values, and adjustments made with the original remote are not reflected in the
app. Each setting uses 16 steps and may require a moment to take effect.

## Requirements

| Item | Details |
| --- | --- |
| Lamp | First-generation MJGJD01YL with the round 2.4 GHz remote; Bluetooth models are not covered. |
| Radio bridge | RF-Nano with ATmega328P, nRF24L01 and a USB serial interface such as CH340; use a USB data cable. |
| Computer | macOS app targeting macOS 13 or later; built and tested on Apple silicon. Other Mac configurations need testing. |
| Build tools | Xcode Command Line Tools for the app; [PlatformIO Core](https://docs.platformio.org/en/stable/core/installation/index.html) for the firmware. |

The app looks for `/dev/cu.usbserial*` and `/dev/cu.wchusbserial*` devices.
Some RF-Nano revisions swap the nRF24 CE and CSN pins; see
[`firmware/src/main.cpp`](firmware/src/main.cpp).

## Get started

Clone the project and enter its directory before running the commands below:

```bash
git clone https://github.com/utopiafar/xiaomi-lightbar-mac.git
cd xiaomi-lightbar-mac
```

### 1. Flash the RF-Nano

If your board already runs this project's firmware, skip to step 2. Flashing
replaces existing firmware; back it up first if you need it. Install PlatformIO
Core, connect the board and identify its serial port (`pio device list`). Then:

```bash
cd firmware
pio run -e nanoatmega328new
pio run -e nanoatmega328new -t upload --upload-port /dev/cu.usbserial-XXXX
cd ..
```

Replace the example port with your actual port. For an old Nano bootloader,
change `board = nanoatmega328new` to `board = nanoatmega328` in
`firmware/platformio.ini`; the environment name can remain unchanged. If the
radio fails to initialize, your board may need the CE/CSN pins swapped.

### 2. Build and open the Mac app

Clone this repository, install Xcode Command Line Tools if needed, and run:

```bash
./mac/build-app.sh
open "build/小米挂灯控制.app"
```

The script builds for the current Mac's architecture and signs the app locally
with an ad-hoc signature. It is not an Apple-notarized distribution. To choose
a different build output directory, pass it as the first script argument.

### 3. Read the remote ID and control the lamp

1. Keep the RF-Nano connected and open the app. If it is not found, open
   **设备与配对 / Device & pairing**, select the port and click **连接 / Connect**.
2. If no ID is saved, scanning starts automatically. Bring the original remote
   close to the RF-Nano and press or turn it. You can also expand **设备与配对**
   and click **读取遥控器 / Read remote**. Stop and retry if no packet is read.
3. Once an ID is saved and the app says **已连接 / Connected**, use the power
   button and sliders. The ID is stored on the RF-Nano and normally survives
   app restarts. The original remote can continue using that ID.

The app's current interface is in Chinese; the labels above include translations.
Closing its initial window leaves the app running in the menu bar. Use **退出 /
Quit** in the panel to exit. A menu-bar manager may hide the bulb icon.

### Alternative: pair the computer

In **设备与配对**, choose **配对电脑 / Pair computer**. Power-cycle the lamp,
then press **发送配对 / Send pairing** within 10 seconds; the lamp flashing
indicates it accepted the pairing attempt. This can replace the original remote's
binding. To restore the remote, power-cycle the lamp and hold the remote button
within 20 seconds until the lamp flashes; the computer will then need to read
that remote ID or pair again.

## Troubleshooting

- **No USB device:** check the data cable and serial driver, reconnect the board,
  then click **连接**. Only one process should use the serial port at a time.
- **No remote ID:** bring the remote close, check its battery and try again;
  radio revisions and interference can affect reception. Scanning does not
  guarantee a result on every board.
- **Commands sent but lamp unchanged:** verify the lamp model, stored ID and
  power, and move the radio closer. The RF protocol does not acknowledge commands.
- **The original remote stopped working:** it may have been replaced by the
  computer-pairing flow; re-pair it as described above.

## Development and tests

```bash
mkdir -p build
xcrun clang++ -std=c++11 mac/tests/SequenceCounterTest.cpp -o build/sequence-counter-test
./build/sequence-counter-test
xcrun swiftc -swift-version 5 mac/SerialBridge.swift mac/tests/SerialBridgeIntegration.swift -o build/serial-integration-test
python3 mac/tests/serial_simulator.py build/serial-integration-test scan
python3 mac/tests/serial_simulator.py build/serial-integration-test sliders
python3 mac/tests/serial_simulator.py build/serial-integration-test pair
go test ./...
```

The simulated serial tests do not transmit to a lamp. The Go check requires
Go 1.22 or later. The optional Python
diagnostic scripts require `pyserial`. The upstream Go CLI and its original
documentation remain available in [README.upstream.md](README.upstream.md).
Radio packet details are in [docs/PROTOCOL.md](docs/PROTOCOL.md)
([中文](docs/PROTOCOL.zh-CN.md)).

## Versions and repository topics

The `v0.1.0` Git tag identifies the first experimental version; it is not a
claim of broad hardware compatibility. Repository topics such as `macos`,
`xiaomi`, `nrf24l01` and `swiftui` are discovery keywords, not version numbers.

## Credits and license

This project builds on [alxndrchernov/auto-lamp](https://github.com/alxndrchernov/auto-lamp),
the protocol research in [lamperez/xiaomi-lightbar-nrf24](https://github.com/lamperez/xiaomi-lightbar-nrf24),
and the receive-framing work in [ebinf/lightbar2mqtt](https://github.com/ebinf/lightbar2mqtt).
The project code is MIT-licensed under [LICENSE](LICENSE); the relevant third-party
notice is in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES/).

Xiaomi is named only to describe device compatibility. This project is not
affiliated with or endorsed by Xiaomi. The app icon was generated for this
project without using its official logo; the [candidate notes](assets/icon-candidates/README.md)
include the generation prompts.
