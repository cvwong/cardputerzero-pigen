# HDMI behaviour on CardputerZero

Measured on hardware 2026-11-27, image `aec9118`, board `Raspberry Pi Compute
Module 0 Rev 1.0`, kernel `6.18.39+rpt-rpi-v8`.

## Summary

Three rules follow from the measurements below, and all are easy to get wrong:

1. **The HDMI resolution is decided at boot**, by whether EDID can be read then.
   Attach the monitor *before* powering on to get 1920x1080; boot without one and
   the connector carries only the 1024x768 no-EDID fallback.
2. **Unplugging and replugging does not break the output.** The force keeps the
   connector enabled and bound to a CRTC, so the monitor re-syncs on its own with
   no kernel event. It does *not* return the console to the built-in panel —
   `Alt+p` does that, and works.
3. **Never write `detect` to the connector's `status`.** It clears the force-on
   flag, and the delayed re-probe can leave the connector `disconnected`,
   `disabled`, with zero modes and no CRTC — a permanently blank monitor until
   `echo on` or a reboot. This was observed, not theorised; see below.

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

## Symptom

Two observations that look like bugs but are not:

- An attached monitor runs at 1024x768 rather than the 1920x1080 requested by
  `video=HDMI-A-1:1920x1080@60D` in `cmdline.txt`.
- Pulling the HDMI cable while looking at the monitor leaves the panel showing
  a stale frame, with the session stranded on tty2.

## What is actually happening

EDID is read **once at boot** and cached. HPD never asserts afterwards, so
nothing re-probes the connector:

- Monitor present at boot -> EDID read -> the connector carries real modes,
  including 1920x1080, and `fb0` is 1920x1080.
- Monitor absent at boot -> no EDID -> the kernel falls back to
  `drm_add_modes_noedid(connector, 1024, 768)`, whose cap is **exactly** the
  1024x768 that gets observed. That number is the fallback's ceiling, not a
  mis-parsed `video=` argument.

The force itself works. The kernel logs it explicitly:

```
[drm] forcing HDMI-A-1 connector on
```

So `video=` is parsed and applied; the connector is forced on regardless of
cable state, which is why `status` reads `connected` even with nothing plugged
in. `stage2/05-cardputerzero/02-run.sh:21-23` documents why the force exists,
and line 49 appends the token.

## Evidence

Read from `$(ls -d /sys/class/drm/card*-HDMI-A-1)` and `/sys/class/graphics/fb*/`
on the same card, before and after pulling the cable. (These readings were taken
on a boot where vc4 happened to be `card0`; the later replug retest found it at
`card1`.)

| signal | monitor attached at boot | after unplugging |
| --- | --- | --- |
| `edid` | 256 bytes | **256 bytes** (stale cache) |
| `status` | connected | connected |
| `enabled` / `dpms` | enabled / On | enabled / On |
| `1920x1080` entries in `modes` | 3 | **3** |
| total `modes` | 29 | 29 |
| `fb0` | vc4drmfb 1920,1080 | 1920,1080 |
| kernel drm/udev event | - | **none** |
| `cz-display-switch` ran | - | **no** |
| `/run/cz-display-switch.state` | `1 0` | `1 0` |

An earlier card, booted without a readable monitor, showed `edid` 0 bytes,
`fb0 1024,768` and no 1920x1080 entry at all. Both readings are correct; they
describe different boot-time conditions, not different behaviour of the force.

## Why the unplug branch never runs

`stage2/05-cardputerzero/files/cz-display-switch` does have the right code:

- `hdmi_fb()` (line 28) matches purely on `name == vc4drmfb` (line 31).
- Line 46 takes the HDMI-present branch whenever that framebuffer exists.
- The `else` at line 48 is the unplug path, and line 52 issues `chvt 1` to bring
  the foreground console home.

Because the forced mode keeps `vc4drmfb` registered permanently, `H` is never
empty, so **line 52 is unreachable**. This is a code fact independent of the
hotplug question: even if a hotplug event arrived, the branch would not be taken.

`tests/cz-display-switch.sh` simulates unplug by deleting the vc4 framebuffer
from its fake sysfs. That state never occurs on this hardware, so its green run
does **not** cover the real unplug path.

## `fb0/blank` is not a health signal

`/sys/class/graphics/fb0/blank` reads `4` (FB_BLANK_POWERDOWN) whenever tty1 is
the foreground VT, because fbcon only renders the foreground console. Every
reading taken during this investigation was with tty1 foreground, which made the
monitor look powered down.

The monitor is in fact a **live terminal**: typing on it while tty2 is foreground
echoes. Do not infer a stale frame from `blank=4`. (This is distinct from the
panel's `KD_GRAPHICS` blanking issue, where an explicit `FBIOBLANK` really is
required — see `cz-splash`.)

## Practical guidance

- Attach the monitor before power-on if you want 1080p.
- Use `Alt+M` to go out to the monitor and `Alt+p` to come back. Both are kernel
  keymap bindings (`cz-console-switch.map`), so they work in both directions with
  no compositor involved.
- Unplugging and replugging the cable is safe: verified from a clean boot, the
  monitor came back with EDID 256 bytes, 1920x1080 and the connector still bound
  to `crtc=pixelvalve-2`, with no kernel event at all.
- Do not expect cable events to drive anything, and do not write `detect` to
  `status` to try to provoke one — it disables the output. If the monitor ever
  goes blank while `Alt+M` still moves the cursor off the panel, check for
  `crtc=(null)` and 0 modes, then restore with `echo on` or a reboot.

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

Nothing was scanning out. The user then plugged a monitor in and got a **blank
screen**, while `Alt+M` still moved the cursor off the panel — the VT switch
worked, the output did not. `detect` sets the force to unspecified and schedules
a re-probe; that re-probe found no cable and disabled the connector, and with no
HPD nothing ever re-enabled it.

**Recovery:** `echo on` to restore the force, or reboot to reapply the cmdline
force. A reboot was verified to restore a healthy output (EDID 256 bytes,
`connected/enabled/On`, 1920x1080, connector bound to `crtc=pixelvalve-2`).

Two lessons worth keeping: a no-change reading immediately after a state-changing
write is *not yet observed*, not negative evidence; and `status` reads `connected`
only while the force is intact — it does read `disconnected` once cleared.

`CONFIG_DRM_LOAD_EDID_FIRMWARE=y` is set, so `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin`
remains an untried lever for a genuinely EDID-less monitor. It has not been tested
here and, unlike the sysfs write, it does not clear the force.

## Still untested

Booting **without** a monitor and attaching one afterwards, from a clean boot with
the force intact. The force should give `connected` plus the 1024x768 fallback and
a bound CRTC, so the monitor would be expected to display at 1024x768 — but the one
report of a blank monitor in that scenario was confounded by the cleared force
above, so it is not established.

## Corrections worth remembering

Three conclusions were asserted during this investigation and later retracted:

- "the forced 1920x1080 mode never applies" — it does, when EDID is readable at
  boot;
- "the board's HPD/EDID lines never assert, so no attachment signal exists" —
  EDID was read successfully (256 bytes), so the stronger claim was unproven;
- "the `status` writes were inert and left nothing changed" — they took effect on
  a delay and disabled the user's monitor.

Each came from reasoning past the available evidence: the first two from a single
sample on one card, the third from a reading taken immediately after a write whose
effect was asynchronous. The verified statements are the ones in the Summary.
Check `edid` byte count and `fb0/virtual_size` on the current card, resolve the
connector by glob, and re-measure after a delay before calling a probe harmless.
