#!/bin/bash
# E2E test for the NetworkManager dispatcher that refreshes the tty1 login
# banner. The behaviour that matters most is the negative case: it must NOT
# restart getty@tty1 while someone is using the console, since that would kill
# their session.
# Run: bash tests/cz-issue-dispatcher-e2e.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../stage2/06-cpz-features/files/99-cz-issue.dispatcher"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"; mkdir -p "$MOCK"

export CZ_TEST_CALLS="$WORK/calls.log"
export CZ_ISSUE_FILE="$WORK/issue"
export CZ_ISSUE_GETTY="getty@tty1.service"
export CZ_ISSUE_BIN="$MOCK/cz-issue"

# Mock cz-issue: rewrites the banner. CZ_TEST_CHANGED=no writes the same content
# back, to exercise the no-flicker path; CZ_TEST_FAIL=1 simulates a failure.
cat > "$MOCK/cz-issue" <<'EOF'
#!/bin/sh
printf '%s\n' "cz-issue" >> "$CZ_TEST_CALLS"
[ "${CZ_TEST_FAIL:-0}" = 1 ] && exit 1
if [ "${CZ_TEST_CHANGED:-yes}" = no ]; then
    printf 'unchanged banner\n' > "$CZ_ISSUE_FILE"
else
    printf 'banner %s\n' "$(date +%s%N)" > "$CZ_ISSUE_FILE"
fi
exit 0
EOF
cat > "$MOCK/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "systemctl $*" >> "$CZ_TEST_CALLS"
EOF
cat > "$MOCK/who" <<'EOF'
#!/bin/sh
[ -n "${CZ_TEST_WHO:-}" ] && printf '%s\n' "${CZ_TEST_WHO}"
exit 0
EOF
chmod +x "$MOCK"/*
export PATH="$MOCK:$PATH"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
calls() { cat "$CZ_TEST_CALLS" 2>/dev/null; }
# Knobs must be exported, not prefixed onto the call: the mocks are child
# processes, and `VAR=x func` does not export VAR when the command is a function.
dispatch() { : > "$CZ_TEST_CALLS"; sh "$SRC" "$1" "$2"; RC=$?; }
restarted()   { calls | grep -q "systemctl restart $CZ_ISSUE_GETTY"; }
regenerated() { calls | grep -q '^cz-issue$'; }

CONSOLE_BUSY='cvwong   tty1         2026-11-24 07:56'
SSH_ONLY='cvwong   sshd         2026-11-24 07:59 (192.0.2.31)'
export CZ_TEST_CHANGED=yes CZ_TEST_FAIL=0

echo "=== address arrives, console idle -> refresh and repaint ==="
export CZ_TEST_WHO=''
dispatch wlan1 up
[ "$RC" = 0 ] && ok "exits 0" || bad "exit $RC"
regenerated && ok "regenerated the banner" || bad "did not call cz-issue"
restarted && ok "restarted getty so the new banner is shown" || bad "did not repaint the prompt"

echo "=== console in use -> must NOT restart getty ==="
export CZ_TEST_WHO="$CONSOLE_BUSY"
dispatch wlan1 up
[ "$RC" = 0 ] && ok "exits 0" || bad "exit $RC"
regenerated && ok "still refreshed the banner file for the next prompt" || bad "did not refresh"
if restarted; then bad "RESTARTED GETTY WITH AN ACTIVE CONSOLE SESSION"; else ok "left the active console session alone"; fi

echo "=== an ssh session is not a console session ==="
export CZ_TEST_WHO="$SSH_ONLY"
dispatch wlan1 up
restarted && ok "ssh session does not block the repaint" || bad "treated an ssh session as console use"

echo "=== banner unchanged -> no pointless flicker ==="
printf 'unchanged banner\n' > "$CZ_ISSUE_FILE"
export CZ_TEST_WHO='' CZ_TEST_CHANGED=no
dispatch wlan1 up
if restarted; then bad "restarted getty although the banner did not change"; else ok "no restart when the banner is identical"; fi
export CZ_TEST_CHANGED=yes

echo "=== irrelevant actions are ignored ==="
export CZ_TEST_WHO=''
for a in down pre-up vpn-up; do
    dispatch wlan1 "$a"
    [ "$RC" = 0 ] || bad "action $a exited $RC"
    if regenerated || restarted; then bad "action $a did work it should have skipped"
    else ok "action $a ignored"; fi
done

echo "=== dhcp and connectivity events also refresh ==="
for a in dhcp4-change dhcp6-change connectivity-change; do
    dispatch wlan1 "$a"
    regenerated && ok "action $a refreshes the banner" || bad "action $a did not refresh"
done

echo "=== cz-issue failing must not restart getty ==="
export CZ_TEST_FAIL=1
dispatch wlan1 up
[ "$RC" = 0 ] && ok "still exits 0 when the generator fails" || bad "exit $RC on generator failure"
if restarted; then bad "restarted getty after a failed regeneration"; else ok "no restart after a failed regeneration"; fi
export CZ_TEST_FAIL=0

echo "=== missing generator is tolerated ==="
export CZ_ISSUE_BIN=/nonexistent/cz-issue
dispatch wlan1 up
export CZ_ISSUE_BIN="$MOCK/cz-issue"
[ "$RC" = 0 ] && ok "exits 0 when cz-issue is absent" || bad "exit $RC when cz-issue is absent"
if restarted; then bad "restarted getty with no generator present"; else ok "no restart when the generator is absent"; fi

echo "=== no interface argument (NM always passes one, but be safe) ==="
dispatch '' up
[ "$RC" = 0 ] && ok "exits 0 with an empty interface name" || bad "exit $RC with empty interface"

echo
if [ "$fail" = 0 ]; then echo "CZ-ISSUE-DISPATCHER OK"; else echo "CZ-ISSUE-DISPATCHER PROBLEM"; exit 1; fi
