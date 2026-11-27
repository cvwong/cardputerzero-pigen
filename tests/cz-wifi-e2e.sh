#!/bin/bash
# End-to-end test for cz-wifi SSID escape parsing (scan / signal / join).
# nmcli -t escapes ':' as '\:' and '\' as '\\'; this verifies cz-wifi
# decodes them and passes the real SSID to nmcli connection add.
# Run: bash tests/cz-wifi-e2e.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/06-cpz-features/files/cz-wifi"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"
mkdir -p "$MOCK"
export CZ_TEST_CALLS="$WORK/nmcli-calls.log"
: > "$CZ_TEST_CALLS"

# Bars come from /proc/net/wireless via cz-signal.sh, so pin both: without this
# the assertion would read the build host's own WiFi. -59 dBm agrees with the
# 82% nmcli reports below (nmcli SIGNAL% is roughly 2*(dBm+100)).
cat > "$WORK/wireless" <<'EOF'
Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE
 face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22
 wlan0: 0000   51.  -59.  -256        0      0      0      0      6        0
EOF
export CZ_WIRELESS="$WORK/wireless"
export CZ_SIGNAL="$HERE/../stage2/06-cpz-features/files/cz-signal.sh"

cat > "$MOCK/nmcli" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CZ_TEST_CALLS"
case "$*" in
  "-t -f DEVICE,TYPE device")
    echo "wlan0:wifi"; echo "eth0:ethernet" ;;
  "-t -f SSID,SIGNAL,SECURITY device wifi list ifname wlan0")
    printf '%s\n' \
      'Cafe\:Guest:82:WPA1 WPA2' \
      'back\\slash:70:WPA2' \
      'mix\\\:colon:60:WPA2' \
      'HomeWiFi:55:WPA2' \
      'OpenNet:40:' \
      ':30:WPA2' ;;
  "-t -f ACTIVE,SSID,SIGNAL,RATE,CHAN device wifi list ifname wlan0")
    printf '%s\n' \
      'no:HomeWiFi:55:135 Mbit/s:1' \
      'yes:Cafe\:Guest:82:270 Mbit/s:6' ;;
  *) exit 0 ;;
esac
EOF
cat > "$MOCK/ip" <<'EOF'
#!/bin/bash
echo "wlan0            UP             192.168.1.42/24"
EOF
chmod +x "$MOCK/nmcli" "$MOCK/ip"
export PATH="$MOCK:$PATH"

fail=0
ok()   { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
has()  { case "$1" in *"$2"*) ok "$3";; *) bad "$3 — missing [$2] in: $1";; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 — unexpected [$2] in: $1";; *) ok "$3";; esac; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi; }

echo "=== cz-wifi signal ==="
out=$(bash "$CZ" signal); echo "$out"
eq "signal decodes escaped-colon SSID" "SSID   Cafe:Guest" "$(echo "$out" | sed -n 1p)"
eq "signal not shifted (signal)" "Signal 82%" "$(echo "$out" | sed -n 2p)"
eq "signal not shifted (rate)"   "Rate   270 Mbit/s" "$(echo "$out" | sed -n 3p)"
eq "signal not shifted (chan)"   "Chan   6" "$(echo "$out" | sed -n 4p)"
eq "signal bars use the shared 4-bar scale" "Bars   |||." "$(echo "$out" | sed -n 5p)"

echo "=== cz-wifi scan (pick 1 = Cafe:Guest) ==="
out=$(printf '1\nsecretpw\n' | bash "$CZ" scan wlan0); echo "$out"
has  "$out" "Cafe:Guest"  "scan shows decoded colon SSID"
hasnt "$out" 'Cafe\:Guest' "scan has no leftover escape"
has  "$out" "82% WPA1 WPA2" "scan signal/security aligned"
has  "$out" 'back\slash'  "scan decodes double backslash"
hasnt "$out" 'back\\slash' "scan has no doubled backslash"
has  "$out" 'mix\:colon'  "scan decodes mixed backslash+colon"
has  "$out" "HomeWiFi"    "scan skips empty SSID, keeps HomeWiFi"
eq "join got decoded SSID" \
  "connection add type wifi con-name Cafe:Guest ifname wlan0 ssid Cafe:Guest wifi.hidden no wifi-sec.key-mgmt wpa-psk wifi-sec.psk secretpw" \
  "$(grep 'connection add' "$CZ_TEST_CALLS")"

echo "=== cz-wifi scan (pick 2 = back\\slash) ==="
: > "$CZ_TEST_CALLS"
out=$(printf '2\npw2\n' | bash "$CZ" scan wlan0)
eq "join got backslash SSID decoded" \
  'connection add type wifi con-name back\slash ifname wlan0 ssid back\slash wifi.hidden no wifi-sec.key-mgmt wpa-psk wifi-sec.psk pw2' \
  "$(grep 'connection add' "$CZ_TEST_CALLS")"

echo "=== cz-wifi scan (pick 5 = open network) ==="
: > "$CZ_TEST_CALLS"
out=$(printf '5\n' | bash "$CZ" scan wlan0)
eq "open network join without psk" \
  "connection add type wifi con-name OpenNet ifname wlan0 ssid OpenNet wifi.hidden no" \
  "$(grep 'connection add' "$CZ_TEST_CALLS")"

echo
if [ "$fail" = 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$fail"
