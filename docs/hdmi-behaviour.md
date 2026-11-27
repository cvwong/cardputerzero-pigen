# HDMI behaviour on CardputerZero

Measured on hardware 2026-11-27, image `aec9118`, board `Raspberry Pi Compute
Module 0 Rev 1.0`, kernel `6.18.39+rpt-rpi-v8`.

## Summary

Two rules follow from the measurements below, and both are easy to get wrong:

1. **The HDMI resolution is decided at boot.** Attach the monitor *before*
   powering on to get 1920x1080. Boot without one and the output stays at
   1024x768 even if a monitor is attached later.
2. **Unplugging HDMI is invisible to the kernel.** It does not return the
   console to the built-in panel. `Alt+p` does, and works.

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

`/sys/class/drm/card0-HDMI-A-1/` and `/sys/class/graphics/fb*/`, same card
before and after pulling the cable:

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
- Do not expect cable events to drive anything.

## Untested: forcing a connector re-probe

`CONFIG_DRM_LOAD_EDID_FIRMWARE=y` is set, and the DRM sysfs `status` attribute is
root-writable (`-rw-r--r--`), so two levers exist in principle:

- `echo detect > /sys/class/drm/card0-HDMI-A-1/status` to force a re-probe
- `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin` to supply a synthetic EDID

Neither has been validated here. Attempts to write `detect` and then `off`
produced no observable change on the device, but the commands' own output was
never captured, so the result is **inconclusive** rather than negative: a
rejected write, a write ignored by vc4, and a command run against the host (which
exposes the identical `card0-HDMI-A-1` path) are all still possible.

Anyone picking this up should run it *on the device* and read the state back in
the same command, e.g.

```sh
sudo sh -c 'echo off > /sys/class/drm/card0-HDMI-A-1/status; cat /sys/class/drm/card0-HDMI-A-1/status'
```

`disconnected` would prove the interface works and that vc4's detect hook always
reports connected; `connected` would mean the write is accepted but ignored.
Restore with `echo on`, or reboot to reapply the cmdline force.

## Corrections worth remembering

Two conclusions were drawn from a single sample during this investigation and
later retracted:

- "the forced 1920x1080 mode never applies" — it does, when EDID is readable at
  boot;
- "the board's HPD/EDID lines never assert, so no attachment signal exists" —
  EDID was read successfully (256 bytes), so the stronger claim was unproven.

The narrower, verified statement is the one in the Summary: hotplug produces no
observable change, and the resolution is fixed at boot. Check `edid` byte count
and `fb0/virtual_size` on the current card before diagnosing the `video=` force.
