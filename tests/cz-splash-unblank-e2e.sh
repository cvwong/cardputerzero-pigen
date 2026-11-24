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
# Make the splash actually linger: systemctl reports user-sessions inactive, so
# the wait loop runs until MAX. The test's own sleep must be the real one, since
# $MOCK/sleep is a no-op stub.
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

echo
if [ "$fail" = 0 ]; then echo "CZ-SPLASH-UNBLANK OK"; else echo "CZ-SPLASH-UNBLANK PROBLEM"; exit 1; fi
