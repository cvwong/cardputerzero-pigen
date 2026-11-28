#!/bin/bash
# E2E test for cz-splash's console restore path.
#
# The splash blits its image with the VT in KD_GRAPHICS, which powers the
# panel-mipi-dbid panel down (fb0/blank -> 4). If cz-splash exits without
# unblanking, agetty draws the login banner into a dark panel and the device
# looks dead. This test mocks python3 so it can observe the actual ioctols
# issued, rather than merely grepping the source for a constant.
# Run: bash tests/cz-splash-unblank-e2e.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/06-cpz-features/files/cz-splash"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"; mkdir -p "$MOCK"

export CZ_TEST_CALLS="$WORK/calls.log"
: > "$CZ_TEST_CALLS"

# Mock python3: record which ioctl the script text asked for. cz-splash invokes
# it as `python3 -c '<script>' <arg>`, so the constant is in the script text and
# the device path is the last argument.
cat > "$MOCK/python3" <<'EOF'
#!/bin/bash
all="$*"
case "$all" in
  *0x4611*) printf 'FBIOBLANK %s\n' "${@: -1}" >> "$CZ_TEST_CALLS" ;;
  # The mode is the LAST argument, not something to search the script text for:
  # the embedded python contains sys.argv[1]=="g", so grepping $* for "g" would
  # report graphics on every call.
  *0x4B3A*) if [ "${@: -1}" = g ]; then printf 'KDSETMODE graphics\n' >> "$CZ_TEST_CALLS"
            else printf 'KDSETMODE text\n' >> "$CZ_TEST_CALLS"; fi ;;
esac
exit 0
EOF
# sleep as a no-op so the two "wait for hardware" loops finish instantly.
printf '#!/bin/sh\nexit 0\n' > "$MOCK/sleep"
for t in setfont aplay amixer systemctl con2fbmap; do printf '#!/bin/sh\nexit 0\n' > "$MOCK/$t"; done
chmod +x "$MOCK"/*
export PATH="$MOCK:$PATH"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
calls() { cat "$CZ_TEST_CALLS" 2>/dev/null; }

FB="$WORK/fb0"
: > "$FB"
export CZ_SPLASH_FB="$FB"
export CZ_SPLASH_IMG="$WORK/nonexistent.rgb565"
export CZ_SPLASH_MIN=0
export CZ_SPLASH_MAX=0

echo "=== run the splash to completion ==="
out=$(bash "$CZ" 2>&1); rc=$?
echo "$out"
echo "--- ioctols observed ---"; calls

[ "$rc" = 0 ] && ok "cz-splash exits 0" || bad "cz-splash exit $rc"
case "$(calls)" in *KDSETMODE\ graphics*) ok "entered KD_GRAPHICS to blit" ;;
    *) bad "never entered KD_GRAPHICS - test is not exercising the blit path" ;; esac
case "$(calls)" in *KDSETMODE\ text*) ok "restored KD_TEXT on exit" ;;
    *) bad "did not restore KD_TEXT" ;; esac
case "$(calls)" in *FBIOBLANK*) ok "issued FBIOBLANK on exit" ;;
    *) bad "NO FBIOBLANK - the panel would stay powered down" ;; esac
case "$(calls)" in *"FBIOBLANK $FB"*) ok "unblanked the framebuffer it actually used" ;;
    *) bad "FBIOBLANK targeted the wrong device: $(calls | grep FBIOBLANK)" ;; esac

echo "=== order matters: text mode restored before unblank ==="
kt=$(calls | grep -n 'KDSETMODE text' | cut -d: -f1 | head -1)
fb=$(calls | grep -n 'FBIOBLANK' | cut -d: -f1 | head -1)
if [ -n "$kt" ] && [ -n "$fb" ] && [ "$kt" -lt "$fb" ]; then
    ok "KD_TEXT ($kt) precedes FBIOBLANK ($fb)"
else
    bad "ordering wrong: KD_TEXT=$kt FBIOBLANK=$fb"
fi

echo "=== the exit trap really logs the panel state ==="
case "$out" in *"blank before unblank="*) ok "logs blank state before unblanking" ;;
    *) bad "no before/after blank logging - cannot diagnose on device" ;; esac
case "$out" in *"blank after unblank="*) ok "logs blank state after unblanking" ;;
    *) bad "no after-unblank logging" ;; esac

echo "=== trap fires on TERM too, not just normal exit ==="
: > "$CZ_TEST_CALLS"
# Make the splash actually linger: the mocked systemctl exits 1, so the wait
# unit reports inactive and the loop runs until MAX. The test's own sleep must be
# the real one, since $MOCK/sleep is a no-op stub.
printf '#!/bin/sh\nexit 1\n' > "$MOCK/systemctl"
export CZ_SPLASH_MAX=3 CZ_SPLASH_MIN=0
bash "$CZ" >/dev/null 2>&1 &
pid=$!
/bin/sleep 0.6
if kill -0 "$pid" 2>/dev/null; then ok "splash still running when TERM is sent"; else bad "splash exited before the TERM test"; fi
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
case "$(calls)" in *FBIOBLANK*) ok "SIGTERM also unblanks (no dark panel on a killed splash)" ;;
    *) bad "SIGTERM left the panel blanked" ;; esac

echo "=== panel framebuffer detection (regression: hardcoded /dev/fb0) ==="
# Reproduces the 2026-11-26 failure: cmdline forces HDMI on, so HDMI takes fb0
# and the 320x170 panel becomes fb1. cz-splash used to blit to fb0 and unblank
# fb0, leaving the panel at blank=4 with the login banner drawn into a dark
# screen -- the device looked dead and was powered off.
SYS="$WORK/sys"
mkfb() { mkdir -p "$SYS/$1"; printf '%s' "$2" > "$SYS/$1/virtual_size"; printf '%s' "$3" > "$SYS/$1/blank"; }
printf '#!/bin/sh\nexit 0\n' > "$MOCK/systemctl"
export CZ_SPLASH_SYSFS="$SYS" CZ_SPLASH_MAX=0 CZ_SPLASH_MIN=0

rm -rf "$SYS"; mkfb fb0 '1920,1080' 0; mkfb fb1 '320,170' 4
: > "$CZ_TEST_CALLS"
out=$(env -u CZ_SPLASH_FB bash "$CZ" 2>&1)
printf '%s\n' "$out" | grep 'panel=' | sed 's/^/  /'
case "$out" in *"panel=/dev/fb1"*) ok "picks fb1 when HDMI holds fb0 and the panel is fb1" ;;
    *) bad "did not select the panel fb: $out" ;; esac
case "$out" in *"panel=/dev/fb1 blank before unblank=4"*) ok "read the PANEL blank state (4), not the monitor's" ;;
    *) bad "read the wrong blank attribute: $out" ;; esac
case "$(calls)" in *"FBIOBLANK /dev/fb1"*) ok "issued FBIOBLANK against the panel" ;;
    *) bad "FBIOBLANK went to the wrong device: $(calls | grep FBIOBLANK)" ;; esac

echo "=== panel on fb0 (no HDMI) still resolves to fb0 ==="
rm -rf "$SYS"; mkfb fb0 '320,170' 4
: > "$CZ_TEST_CALLS"
out=$(env -u CZ_SPLASH_FB bash "$CZ" 2>&1)
case "$out" in *"panel=/dev/fb0"*) ok "picks fb0 when the panel is fb0" ;;
    *) bad "wrong fb when the panel is fb0: $out" ;; esac

echo "=== reversed enumeration order does not matter ==="
rm -rf "$SYS"; mkfb fb0 '1920,1080' 0; mkfb fb1 '1920,1080' 0; mkfb fb2 '170,320' 4
: > "$CZ_TEST_CALLS"
out=$(env -u CZ_SPLASH_FB bash "$CZ" 2>&1)
case "$out" in *"panel=/dev/fb2"*) ok "finds a rotated 170,320 panel on fb2" ;;
    *) bad "did not find the panel on fb2: $out" ;; esac

echo "=== no panel at all falls back to fb0 ==="
rm -rf "$SYS"; mkfb fb0 '1920,1080' 0
printf '#!/bin/sh\nexit 1\n' > "$MOCK/con2fbmap"; chmod +x "$MOCK/con2fbmap"
: > "$CZ_TEST_CALLS"
out=$(env -u CZ_SPLASH_FB bash "$CZ" 2>&1)
case "$out" in *"panel=/dev/fb0"*) ok "falls back to fb0 when nothing matches" ;;
    *) bad "no fallback when no panel matched: $out" ;; esac

echo "=== an explicit CZ_SPLASH_FB still overrides detection ==="
out=$(CZ_SPLASH_FB="$WORK/fb0" bash "$CZ" 2>&1)
case "$out" in *"panel=$WORK/fb0"*) ok "CZ_SPLASH_FB override is honoured" ;;
    *) bad "override ignored: $out" ;; esac

echo "=== the splash must not gate the login prompt on the network ==="
# Boot-time defect measured on the 8e0ee1a card: cz-splash waited on
# systemd-user-sessions.service, which is After=network.target, so a cosmetic
# logo held getty@tty1 for ~6.7s of NetworkManager's wifi+DHCP cycle and the
# login prompt did not appear until ~25.4s. The wait unit is now local.
# Strip comments before grepping: the block above the WAIT_UNIT default explains
# the old network-gated behaviour and therefore names systemd-user-sessions in
# prose, which a plain grep flags as the defect it is documenting.
grep -v '^[[:space:]]*#' "$CZ" | grep -q 'systemd-user-sessions' \
    && bad "cz-splash still waits on systemd-user-sessions (network-gated)" \
    || ok "cz-splash no longer waits on systemd-user-sessions in code"
grep -qE '^WAIT_UNIT=\$\{CZ_SPLASH_WAIT_UNIT:-systemd-logind\.service\}' "$CZ" \
    && ok "waits on systemd-logind.service by default, overridable" \
    || bad "WAIT_UNIT default is not systemd-logind.service"
grep -q 'is-active --quiet "$WAIT_UNIT"' "$CZ" \
    && ok "the wait loop actually consults WAIT_UNIT" \
    || bad "the wait loop does not use WAIT_UNIT"
grep -qE '^MIN_SHOW=\$\{CZ_SPLASH_MIN:-1\}' "$CZ" \
    && ok "MIN_SHOW defaults to 1s (was 3s)" || bad "MIN_SHOW default is not 1"

# Behavioural: with the wait unit reporting active, the splash must hand over
# promptly instead of running to MAX_WAIT. Uses a real 30s ceiling so a broken
# loop would hang the test rather than pass it.
printf '#!/bin/sh\nexit 0\n' > "$MOCK/systemctl"
export CZ_SPLASH_SYSFS="$SYS" CZ_SPLASH_MAX=30 CZ_SPLASH_MIN=0
t0=$(date +%s)
bash "$CZ" >/dev/null 2>&1
t1=$(date +%s)
el=$((t1 - t0))
[ "$el" -lt 5 ] && ok "splash handed over in ${el}s with the wait unit active (MAX was 30)" \
    || bad "splash took ${el}s despite the wait unit being active"

echo
if [ "$fail" = 0 ]; then echo "CZ-SPLASH-UNBLANK OK"; else echo "CZ-SPLASH-UNBLANK PROBLEM"; exit 1; fi
