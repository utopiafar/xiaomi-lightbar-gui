# Protocol notes (Xiaomi MJGJD01YL / Telink TLSR8368)

> **Attribution.** The packet format, CRC parameters, command codes, and the
> pairing trick were reverse-engineered by
> [lamperez/xiaomi-lightbar-nrf24](https://github.com/lamperez/xiaomi-lightbar-nrf24)
> (analyzed with a HackRF One + Universal Radio Hacker). This document restates
> those findings plus the implementation details specific to driving the radio
> from an nRF24L01 over a serial bridge. Bugs and framing choices below are our
> own; verify against the upstream project for the source of truth.

## Packet (17 bytes)

| Offset | Bytes | Field |
|-------:|:-----:|-------|
| 0      | 8     | Preamble `53 39 14 DD 1C 49 34 12` (same for all lamps) |
| 8      | 3     | Remote ID (any value the lamp is bound to) |
| 11     | 1     | Separator `0xFF` |
| 12     | 1     | Sequence counter |
| 13     | 2     | Command (`cmd1 cmd2`) |
| 15     | 2     | CRC16 (big-endian) |

> ⚠️ The lamperez README prose lists *command* before *counter*, but its **code**
> (and the captured packets) put the **counter at offset 12, command at 13–14**.
> The code order is the correct one and is what this firmware uses.

## CRC16

Reverse-engineered with `reveng`:

```
width=16  poly=0x1021  init=0xFFFE  refin=false  refout=false  xorout=0x0000
```

Computed over bytes `[0..14]` (preamble through command).

## No whitening

Data is sent **as-is**. (An earlier note in our project claimed an LFSR
whitening step with seed `0x7F` — that was wrong; the reference applies none.)

## Radio / nRF24 framing

* **Data rate:** 2 Mbps GFSK. **CRC:** disabled. **AutoAck:** off.
* **TX address = `55 55 55 55 55`** — this is the sync run, *not* an address in
  the usual sense. The **entire 17-byte packet (preamble included)** is sent as
  the nRF24 payload (`payload_size = 17`). This gives the Telink receiver the
  long `0x5555…` sync run it needs to lock on.
  * ❗ A tempting-but-broken alternative is to put the Telink preamble in the
    nRF24 address and send only the tail as payload. The sync run is then too
    short and the lamp ignores the packets. Don't.
* **Channels:** 6, 43, 68 (2406 / 2443 / 2468 MHz), with frequency hopping.
* **Burst:** each logical command is one packet (one counter value) repeated
  ~20× across the 3 channels for reliability.

## The sequence counter — two non-obvious traps

The lamp de-duplicates by the 1-byte counter at offset 12: a **repeated**
counter is treated as the same button press and ignored; a **new** counter is a
fresh press.

1. **Fix the counter for the whole burst.** Build the packet *once* per command
   and repeat the identical bytes. If you increment the counter on every
   repetition, the lamp sees ~20 separate presses and toggles/steps wildly.
2. **Persist the counter across resets.** On a host-over-serial setup, opening
   the serial port toggles DTR and **resets the MCU**, zeroing a RAM counter —
   so every command would ship counter `0` and the lamp would ignore all but the
   first. Store the counter in EEPROM, load it at boot, and save it after each
   command. (This trap is specific to the PC-bridge topology and is why we hit
   it where the RPi/direct-SPI projects don't.)

## Command codes

| Action            | cmd1 | cmd2          |
|-------------------|:----:|---------------|
| On/Off (toggle)   | 0x01 | 0x00          |
| Cooler  +N        | 0x02 | 0x01–0x0F     |
| Warmer  −N        | 0x03 | 0xFF–0xF1     |
| Brighter +N       | 0x04 | 0x01–0x0F     |
| Dimmer  −N        | 0x05 | 0xFF–0xF1     |
| Reset / pair      | 0x06 | 0x00          |

`cmd2` magnitude is the step size (farther from `0x01`/`0xFF` = bigger step).
For on/off and reset, `cmd2` is effectively ignored.

## Pairing (bind to an arbitrary ID)

The lamp learns a new remote ID when it receives a **reset** (`0x06 0x00`) with
that ID **within ~20 s of being powered on**:

1. Pick any 3-byte ID and load it into the firmware.
2. Power-cycle the lamp (unplug → plug).
3. Within the window, send `reset` with that ID.
4. The lamp flashes once = bound. It now obeys commands carrying that ID.

Because the lamp has no pairing crypto and the remote is a pure transmitter,
this fully replaces "sniff the original remote" or "read its chip via SWS".

## Serial bridge protocol (115200 8N1)

Text, line-based. Commands:

```
SCAN / SCAN_STOP            enter / leave RX sniffer (find a remote's ID)
SNIFF1 / SNIFF2 / SNIFF_STOP  promiscuous sniffers (1 Mbps / 2 Mbps)
ID AA:BB:CC                 set + persist the remote ID
GET_ID                      report the stored ID
CMD HH HH                   send a raw command (cmd1 cmd2)
ON / OFF / RESET / PAIR     toggle / factory-reset / pairing burst
BRIGHT +N|-N / WARM +N|-N   stepped brightness / colour temperature
```

Replies: `READY` (boot), `OK`, `ERR <msg>`, `FOUND:AA:BB:CC` (scan).
