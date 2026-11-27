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
| `[2/6]` Boot partition | the loop-mounted FAT | **yes** |
| `[3/6]` Kernel modules | `debugfs` on `root.ext4` | no |
| `[4/6]` APPLaunch (retired) | `debugfs` | no |
| `[5/6]` Modprobe configuration | `debugfs` | no |
| `[6/6]` Packages | `debugfs` | no |

So without root the script is not merely degraded — it produces no output at all
past the mount. Do not conclude from that alone that the image is bad.

## Running sections 3-6 without root

Extract the root partition and run the same `debugfs` commands by hand:

```sh
IMG=deploy/<image>.img
RS=$(fdisk -l "$IMG" | awk '/Linux/{print $2}')
RE=$(fdisk -l "$IMG" | awk '/Linux/{print $3}')
dd if="$IMG" of=/tmp/root.ext4 bs=512 skip="$RS" count=$((RE - RS + 1)) status=none

debugfs -R "ls lib/modules" /tmp/root.ext4
debugfs -R "cat var/lib/dpkg/status" /tmp/root.ext4 > /tmp/dpkg_status
```

`fdisk -l` on an image file is unprivileged, and `dd` only needs read access.
Two caveats worth stating when reporting results this way:

- The output comes from a driver you wrote, **not** from `verify-image.sh`, so it
  is evidence about the image, not a pass of the script. Say which.
- The extraction costs roughly the root partition's size (2.7 GB for the console
  image). Put it somewhere with space and delete it afterwards.

`mtools` can read the FAT boot partition unprivileged (`mdir -i <img>@@<offset> ::`,
`mcopy` the same way), which covers most of what `[2/6]` checks if that section
matters and root is unavailable.

## Coverage

`tests/cz-verify-image.sh` covers the parts of the script that have actually
broken, without needing root. It extracts the `REQUIRED_MODULES` and
`REQUIRED_PACKAGES` arrays and the `Size:` awk program from the script itself and
evaluates them, so the test cannot drift from the code it checks.

Two defects it now guards, both found on 2026-11-27:

- **Module sizes reported as `(0\nAddress: bytes)`.** `debugfs stat` prints two
  lines containing `Size:` — the inode line and a trailing
  `Fragment:  Address: 0    Number: 0    Size: 0`. The old
  `grep "Size:" | awk '{print $2}'` took field 2 of both and concatenated them,
  so a 0-byte module was indistinguishable from a healthy one. The current awk
  takes the field after the first `Size:` token.
- **Assertions for a retired desktop image.** `splash.bmp`, the APPLaunch binary
  and service, and the `applaunch`/`fastfetch`/`cmatrix` packages were required,
  but no live stage script installs any of them — `fastfetch` and `cmatrix`
  survived only in the inert `00-packages.orig`, and `applaunch` only in
  `CARDPUTERZERO-IMAGE-DESIGN.md`. Because both CI jobs share the same stage
  scripts and differ only in `config`, these failed on **every** image, for both
  variants. `[6/6]` now asserts the packages the console image really declares,
  and the drift is caught by cross-checking that list against the live
  `00-packages` files, excluding `*.orig`.

A permanently failing check is worse than no check: it trains everyone to ignore
the tool's output. When a verification assertion fails on an image that is
otherwise known-good, check whether the assertion still describes the product
before changing the product.
