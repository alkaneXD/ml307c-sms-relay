# Air780EPM firmware for SMS Relay

Hezhou **Air780EPM does not support official AT firmware**. Flash this LuatOS script instead. It implements the PDU SMS AT subset the Mac app already speaks (`CMGF=0`, `CMGS`, `CMTI`/`CMGR`/`CMGL`/`CMGD`, `CSQ`, `CREG`, `CNETLIGHT`).

## The BOOT button (often misread as “ROOT”)

On the dongle that is the **download-mode** key, not a Linux root switch.

| Silkscreen | Function |
|---|---|
| **BOOT** / 下载 / USB_BOOT | Hold this **before** the module starts so it enumerates as a single download port for Luatools. |
| **RST** / RESET | Hardware reset. Hold BOOT, then tap RST. |
| **PWR** / 开机 | Power key. USB-powered dongles often auto-boot; you may not need it. |

Do **not** hold BOOT during normal use. If USB_BOOT stays high, the module waits ~20s for a download and looks “dead”.

## Flash (Luatools, Windows)

1. Install [Luatools](https://docs.openluat.com/common/Luatools/).
2. Kernel: **LuatOS-SoC Air780EPM** build that includes the `sms` library (firmware **1 / 2 / 103–106**). Latest index: https://docs.openluat.com/air780epm/luatos/firmware/version/
3. Project script: this folder’s `main.lua`. Check **添加默认 lib**.
4. Click **下载**, then:
   - Hold **BOOT**
   - Unplug/replug USB **or** tap **RST**
   - Release BOOT once the progress bar moves
5. Success: Device Manager shows the usual 3 CDC ports again (not a single boot port).
6. On the AT port (`cu.usbmodem…` ending in 7 on macOS):

```
AT
OK
AT+CGMM
+CGMM: "Air780EPM"
AT+CNETLIGHT=0
OK
```

`AT+CNETLIGHT=0` turns the network LED off; `=1` turns it on. The Mac app maps its existing LED toggle to this command.

Script **0.5.5**:

- Incoming emoji / Chinese / any non-GSM7 text is UCS2 (UTF-16BE, including surrogate pairs). Invalid UTF-8 from the radio is not dropped.

Script **0.5.4**:

- Incoming long SMS is split into concatenated PDUs (GSM 7-bit when possible, UCS2 otherwise). 0.5.3 wrote a 3-digit UDL for messages over 140 bytes, so the Mac stored `[raw PDU]`.
- Alphanumeric senders (GCash, etc.) use TOA 0xD0 instead of an empty number.

Script **0.5.3**:

- `AT+CMGS` waits for LuatOS `SMS_SENT` (0.5.1 returned OK in ~5 ms on queue).
- `AT+COPS?` reports the real PLMN (IMSI / serving cell). 0.5.1 wrote Lua `\7` (BEL) instead of LTE `7`, so the Mac app showed no operator.
- `AT+CESQ` / `AT+CREG?` use RSRP and TAC/ECI when the radio has them.
- `AT+CGMM` is plain `Air780EPM` so the app fills Model.
- `AT+CNUM` still depends on LuatOS `mobile.number()`. That API is empty on many Globe SIMs even when the same card returns a number in an ML307 via `AT+CNUM`. The Mac app (0.6.7+) remembers MSISDN by ICCID from the last stick that could read it.

## Mac app

SMS Relay 0.5.1+ probes `AT+CGMM` for `AIR780` as well as `ML307`. After this firmware is on the stick, plug it in like an ML307C. Keep it off the HDMI-adjacent Thunderbolt port if a display is plugged in (same USB current issue).
