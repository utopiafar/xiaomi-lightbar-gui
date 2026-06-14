# TODO

## To use this right now (checklist)

- [ ] Hardware: an **RF-NANO** (or Arduino Nano + nRF24L01+) and a
      **Xiaomi MJGJD01YL** light bar within radio range.
- [ ] Install [PlatformIO](https://platformio.org/) and flash `firmware/`
      (`cd firmware && pio run -t upload`).
- [ ] Install Go 1.22+ and build the CLI (`go build -o lamp ./cmd/lamp`).
- [ ] Find your serial port (`/dev/cu.usbserial-*`, `/dev/ttyUSB*`, `COMx`).
- [ ] Run `./lamp pair --port <DEV>` and follow the power-cycle prompt.
- [ ] Verify with `./lamp on`, `./lamp bright +5`, etc.

## Nice-to-have features

- [ ] `lamp cmd HH HH` — expose the raw `CMD` passthrough in the CLI for
      experimenting with undocumented codes.
- [ ] Optional **fix the `warm` direction**: today `warm +N` sends the *cooler*
      code (`0x02`). Decide whether `+` should mean warmer and swap if so
      (also swap `bright` if you want consistency), or add `cooler`/`warmer`
      aliases.
- [ ] "Set absolute brightness/temperature in %" helpers (the protocol is
      step-based; lamperez emulates absolute by saturating then stepping —
      port that approach).
- [ ] Make the serial bridge generic enough to also expose `SNIFF`/`SCAN`
      results in the CLI for debugging.
- [ ] Cross-platform release builds of the CLI (darwin/linux/windows).

## Known limitations

- One-way control only: the lamp never reports state, so the host can't know
  if it's currently on or what the brightness is. `on`/`off` is a blind toggle.
- Reliability depends on RF range and interference; tune burst repetitions /
  channels in `firmware/src/main.cpp` if commands are missed.
- The `SCAN`/`SNIFF` sniffers depend on the nRF24 actually receiving the
  remote's Telink frames, which is less reliable than transmitting — prefer
  `pair` over sniffing.
