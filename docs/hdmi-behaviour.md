# HDMI behaviour on CardputerZero

Measured on hardware 2026-11-27, board `Raspberry Pi Compute Module 0 Rev 1.0`,
kernel `6.18.39+rpt-rpi-v8`. Two fixes resulted: `1b8afce` (framebuffer wake) and
`6ef1d5c` (reduced-blanking mode), both verified on the device.

## Summary

1. **1080p works with or without a monitor at boot.** The forced mode uses CVT
   reduced-blanking timings (`1920x1080MR@60D`), which vc4 accepts. Plain
   `1920x1080@60D` was rejected outright.
2. **The HDMI framebuffer must be woken explicitly.** `cz-display-switch` now does
   it; nothing else did, which left a black picture with the signal up.
3. **Unplugging and replugging is safe**, and does not return the console to the
   panel — `Alt+p` does that. No kernel hotplug event fires either way.
4. **Never write `detect` to the connector's `status`.** It clears the force-on
   flag and can leave the output dead until `echo on` or a reboot.

**Resolve the connector path, never hardcode it.** The DRM card index moves
between boots: one boot had `card0 -> vc4-drm` (`card0-HDMI-A-1`), the next had
`card0 -> panel-mipi-dbi-spi` and `card1 -> vc4-drm` (`card1-HDMI-A-1`), where a
hardcoded `card0-HDMI-A-1` path does not exist at all. Use:

```sh
H=$(ls -d /sys/class/drm/card*-HDMI-A-1 | head -1)
```

`cz-display-switch` is immune because it matches the framebuffer *name*
(`vc4drmfb`), not a card index. The debugfs state also appears under several
aliases for the same card (`dri/1/state`, `dri/soc:gpu/state`, `dri/128/state`).

## The mode rejection, and its fix

With plain `video=HDMI-A-1:1920x1080@60D` the kernel logged, twice per boot:

```
[drm] User-defined mode not supported: "1920x1080":
    60 172780 1920 2040 2248 2576 1080 1081 1084 1118 0x20 0x6
```

That is CVT with htotal 2576 and a **172780 kHz** pixel clock (59.99 Hz). vc4
refuses it. With no accepted user mode and no EDID, the connector was left with
only `drm_add_modes_noedid(connector, 1024, 768)`, whose ceiling is exactly the
1024x768 that was observed.

Adding `MR` (CVT + reduced blanking) gives htotal 2080 and **138611 kHz** measured
(138653 predicted from 2080 x 1111 x 60), comfortably under the 148500 kHz CEA
clock vc4 drives from EDID. Both flags are load-bearing; `02-run.sh` carries the
reasoning next to the token.

Verified with **no monitor at boot** (`edid` 0 bytes), which is the case that was
broken:

| | before (`@60D`) | after (`MR@60D`) |
| --- | --- | --- |
| rejection message | present, twice | **absent** |
| 1920x1080 in mode list | 0 | **1, first entry** |
| `fb0` | 1024,768 | **1920,1080** |
| `tmds_char_rate` | 65000000 | **138611000** |
| connector | bound | bound to `crtc=pixelvalve-2` |

The force-**on** half always worked (`[drm] forcing HDMI-A-1 connector on`); the
force-**mode** half never did. An earlier reading recorded 1024x768 as "just the
no-EDID fallback", missing that the fallback was reached *because* the requested
mode was refused.

## The framebuffer wake

`fbcon=map:0` starts every console on fb0; `lcd-console` then moves tty1 to the
panel, and nothing woke the framebuffer it left behind. A monitor attached after
boot got a black picture with the signal up — HVS channel in use, tmds clock
running, connector bound to a CRTC — and switching to tty2 did not fix it.
`cz-splash`'s `FBIOBLANK` targeted the panel only.

`cz-display-switch` now writes 0 to the HDMI fb's `blank`, on every run and
**before** its state cache can short-circuit, so a reattach with an unchanged fb
layout still gets woken. The panel's `blank` is deliberately untouched.

**`blank` is not a usable readout.** It reads 4 again afterwards even while the
monitor is displaying, and it also reads 4 whenever tty1 is the foreground VT
because fbcon renders only the foreground console. Judge by the picture — an
earlier reading of it nearly led me to call a working output dead. The monitor is
a live terminal: typing on it while tty2 is foreground echoes.

(This is distinct from the panel's `KD_GRAPHICS` blanking issue, where an explicit
`FBIOBLANK` really is required — see `cz-splash`.)

## Hotplug: nothing to hook

Same card, monitor attached at boot, before and after pulling the cable:

| signal | attached | after unplugging |
| --- | --- | --- |
| `edid` | 256 bytes | **256 bytes** (stale cache) |
| `status` | connected | connected |
| `enabled` / `dpms` | enabled / On | enabled / On |
| 1920x1080 modes | 3 | **3** |
| total `modes` | 29 | 29 |
| kernel drm/udev event | - | **none** |
| `cz-display-switch` ran | - | **no** |
| `/run/cz-display-switch.state` | `1 0` | `1 0` |

EDID is read once at boot and cached; HPD never asserts, so nothing re-probes.
Replugging still works because the force keeps the output enabled and bound to a
CRTC — the monitor re-syncs on its own.

`cz-display-switch`'s unplug branch is unreachable regardless: `hdmi_fb()` (line
28) matches only on `name == vc4drmfb` (line 31), which the force keeps registered,
so line 46 always takes the HDMI-present branch and line 52's `chvt 1` never runs.
`tests/cz-display-switch.sh` simulates unplug by deleting that framebuffer from
fake sysfs — a state that never occurs here — so its coverage of the mapping does
not extend to the real unplug path.

## Writing `status` clears the force and kills the output

This was tried, and it caused a real failure. `echo detect` and then `echo off`
were written to the connector's `status`; read back immediately, nothing appeared
to change, so the experiment was recorded as inconclusive. **That reading was
taken too early.** Roughly 34 minutes later the same boot showed:

```
edid      0 bytes
status    disconnected
enabled   disabled
dpms      Off
modes     0 total
connector HDMI-A-1   crtc=(null)
all CRTCs enable=0 active=0,  all HVS channels in use=0
```

Nothing was scanning out. The user plugged a monitor in and got a **blank screen**
while `Alt+M` still moved the cursor off the panel — the VT switch worked, the
output did not. `detect` sets the force to unspecified and schedules a re-probe;
that re-probe found no cable and disabled the connector, and with no HPD nothing
ever re-enabled it.

**Recovery:** `echo on`, or reboot to reapply the cmdline force. A reboot was
verified to restore a healthy output.

Two lessons: a no-change reading immediately after a state-changing write is *not
yet observed*, not negative evidence; and `status` reads `connected` only while the
force is intact — it does read `disconnected` once cleared.

`CONFIG_DRM_LOAD_EDID_FIRMWARE=y` is set, so `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin`
remains an untried lever for a genuinely EDID-less monitor. Unlike the sysfs write
it does not clear the force, and it is no longer needed for the case above.

## Practical guidance

- 1080p no longer depends on attaching the monitor before power-on.
- `Alt+M` out to the monitor, `Alt+p` back. Both are kernel keymap bindings
  (`cz-console-switch.map`), so they work in both directions with no compositor.
- Unplugging and replugging the cable is safe.
- Do not expect cable events to drive anything, and do not write `detect` to
  `status` to provoke one. If the monitor goes blank while `Alt+M` still moves the
  cursor, check for `crtc=(null)` and 0 modes, then `echo on` or reboot.

## Corrections worth remembering

Four conclusions were asserted here and later retracted:

- "the forced 1920x1080 mode never applies" — the force-on worked; the *mode* was
  rejected, a different and fixable defect;
- "the board's HPD/EDID lines never assert, so no attachment signal exists" — EDID
  read fine (256 bytes), so the stronger claim was unproven;
- "the `status` writes were inert and left nothing changed" — they took effect on
  a delay and disabled the monitor;
- "1024x768 is just the no-EDID fallback" — true but incomplete; the fallback was
  reached because the requested mode was refused.

Each came from reasoning past the evidence: single samples, a reading taken too
early, or a correct observation with the wrong cause attached. A fifth near-miss
is worth recording too: two staged installers were reported as run and had not
executed at all, caught only by checking the installed file's md5 and the absence
of the backup the script writes first. Verify on the current card, resolve the
connector by glob, re-measure after a delay, and confirm a step happened before
building on it.
