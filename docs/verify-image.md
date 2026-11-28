# tools/verify-image.sh

Post-build check that an image contains the CardputerZero customisations. CI runs
it on every image it produces — the `build-desktop` job and the `check-lite` job
in `.github/workflows/build.yml` both invoke it. A non-zero exit breaks CI.

```sh
sudo ./tools/verify-image.sh deploy/<image>.img
```

## It needs root for exactly one thing

The script extracts both partitions to files with `dd`, then mounts the boot
partition:

```sh
mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot"
```

That is the **only** privileged operation in the script. Because the script runs
under `set -euo pipefail`, a failed mount aborts it immediately and no later
section runs. Everything after it reads `$TMPDIR/root.ext4` with `debugfs`, which
operates on an ordinary file and needs no privileges.

| section | reads | root needed |
| --- | --- | --- |
| `[1/6]` Extracting partitions | `fdisk -l`, `dd` on the image | no |
| `[2/6]` Boot partition | the loop-mounted FAT | **yes** (avoidable, see below) |
| `[3/6]` Kernel modules | `debugfs` on `root.ext4` | no |
| `[4/6]` APPLaunch (retired) | `debugfs` | no |
| `[5/6]` Modprobe configuration | `debugfs` | no |
| `[6/6]` Packages | `debugfs` | no |

So without root the script is not merely degraded — it produces no output at all
past the mount. Do not conclude from that alone that the image is bad.

## Running the whole script without root

Swap the one privileged line for an `mcopy` and the script runs to completion
unprivileged, producing output **byte-identical** to a root run:

```sh
cp tools/verify-image.sh /tmp/verify-mtools.sh
python3 - <<'PY'
p = "/tmp/verify-mtools.sh"; s = open(p).read()
old = 'mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot" 2>/dev/null'
new = 'mcopy -s -i "$TMPDIR/boot.fat" ::/. "$TMPDIR/boot" 2>/dev/null || true'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
bash /tmp/verify-mtools.sh deploy/<image>.img
```

`mcopy -s` populates `$TMPDIR/boot` with the FAT's contents, so every `[2/6]`
check runs unchanged against real files — the `start.elf` existence and
`stat -c%s` size check, the `grep`s over `config.txt` and `cmdline.txt`, the
`u-boot.bin` absence test and the overlay `.dtbo` lookup all behave exactly as
they do on a loop mount.

Verified 2026-11-28 on `2026-11-28-cardputerzero-v5-console-0a6418f-lite.img`:
the variant and a genuine `sudo` run of the committed script each produced 58
lines, 37 checks, 0 failures, exit 0, and the same md5
`447c527cfa2a8b35da298391d9e7e7b0`. `diff` reported no differing lines. An
earlier version of this page hedged that `mtools` covered "most of `[2/6]`";
that was never tested, and the measurement shows it understates the result.

Two things this still does not prove:

- **That the loop-mount itself succeeds.** `mcopy` parsing the FAT is good
  evidence the partition is intact, but it is not the kernel's verdict on it.
- **Anything about CI.** The workflow runs the committed script as root, so the
  variant is a local convenience, never a substitute in the pipeline.

When reporting results this way, show the one-line diff. It is what distinguishes
"the script's own checks, with one access method swapped" from "a reimplementation
that happens to look similar" — and only the first is evidence about the script.

## Running a few checks by hand without root

Use this when you want one or two facts about an image and not a verdict — the
full-script route above is better when you want the whole check. Extract the root
partition and run the same `debugfs` commands by hand:

```sh
IMG=deploy/<image>.img
RS=$(fdisk -l "$IMG" | awk '/Linux/{print $2}')
RE=$(fdisk -l "$IMG" | awk '/Linux/{print $3}')
dd if="$IMG" of="$HOME/.cz-root.ext4" bs=512 skip="$RS" count=$((RE - RS + 1)) status=none

debugfs -R "ls lib/modules" "$HOME/.cz-root.ext4"
debugfs -R "cat var/lib/dpkg/status" "$HOME/.cz-root.ext4" > /tmp/dpkg_status
```

`fdisk -l` on an image file is unprivileged, and `dd` only needs read access.
Three caveats worth stating when reporting results this way:

- The output comes from a driver you wrote, **not** from `verify-image.sh`, so it
  is evidence about the image, not a pass of the script. Say which.
- The extraction costs roughly the root partition's size (2.7 GB for the console
  image). Prefer `$HOME` over `/tmp`: on many systems `/tmp` is a tmpfs, so the
  extraction comes straight out of RAM. Delete it afterwards.
- Never walk the extracted tree with `grep -r` while a build is running elsewhere,
  and never walk `work/*/rootfs` at all during a build.

To read a single file from the FAT boot partition without extracting it, `mtools`
addresses the partition by byte offset — `mcopy -i <img>@@$((16384 * 512))
::cmdline.txt -` prints `cmdline.txt` straight to stdout, and `mdir -i
<img>@@<offset> ::/overlays` lists the overlays. That is how the `.dtbo` and
`cmdline.txt` facts above were checked unprivileged.

## Coverage

`tests/cz-verify-image.sh` covers the parts of the script that have actually
broken, without needing root. It extracts the `REQUIRED_MODULES` and
`REQUIRED_PACKAGES` arrays, the `Size:` awk program, and the overlay `.dtbo`
block from the script itself and evaluates them, so the test cannot drift from
the code it checks.

Three defects it now guards:

- **Module sizes reported as `(0\nAddress: bytes)`** (found 2026-11-27).
  `debugfs stat` prints two
  lines containing `Size:` — the inode line and a trailing
  `Fragment:  Address: 0    Number: 0    Size: 0`. The old
  `grep "Size:" | awk '{print $2}'` took field 2 of both and concatenated them,
  so a 0-byte module was indistinguishable from a healthy one. The current awk
  takes the field after the first `Size:` token.
- **Assertions for a retired desktop image** (found 2026-11-27). `splash.bmp`, the APPLaunch binary
  and service, and the `applaunch`/`fastfetch`/`cmatrix` packages were required,
  but no live stage script installs any of them — `fastfetch` and `cmatrix`
  survived only in the inert `00-packages.orig`, and `applaunch` only in
  `CARDPUTERZERO-IMAGE-DESIGN.md`. Because both CI jobs share the same stage
  scripts and differ only in `config`, these failed on **every** image, for both
  variants. `[6/6]` now asserts the packages the console image really declares,
  and the drift is caught by cross-checking that list against the live
  `00-packages` files, excluding `*.orig`.
- **The `.dtbo` check credited the wrong file** (found 2026-11-28, fixed in
  `ce3cb95`). One loop resolved which overlay `config.txt` loads; a second,
  independent loop scanned `CARDPUTERZERO_OVERLAYS` for any `.dtbo` that existed
  and broke at the first hit. An image ships both `cardputerzero-v3-overlay.dtbo`
  (7208 bytes) and `cardputerzero-v5-overlay.dtbo` (9550 bytes) while
  `config.txt` loads v5, so the check reported the v3 file as its evidence. Had
  the v5 dtbo ever gone missing, the firmware would load no board overlay — dead
  keypad, LCD and battery gauge — and verification would still have printed
  `ALL CHECKS PASSED`. The dtbo is now looked up by the overlay name
  `config.txt` actually specifies. The test catches five mutations of this: reverting to the
  scan-any loop outright, the same revert with the extraction anchor comment
  preserved so only the behaviour differs, hardcoding a v3 lookup that ignores
  `config.txt`, dropping the missing-dtbo failure branch, and double-counting an
  unnamed overlay.

A permanently failing check is worse than no check: it trains everyone to ignore
the tool's output. When a verification assertion fails on an image that is
otherwise known-good, check whether the assertion still describes the product
before changing the product.
