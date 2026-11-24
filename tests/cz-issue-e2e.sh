#!/bin/bash
# E2E test for cz-issue, which regenerates /etc/issue as a fully bordered box.
# The point of the box is that the right-hand border stays aligned no matter how
# long the hostname or DHCP address is, so every case asserts exact character
# widths rather than just "looks plausible".
# Run: bash tests/cz-issue-e2e.sh
set -u
# Box drawing is multibyte; without a UTF-8 locale ${#l} counts bytes, not columns.
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/06-cpz-features/files/cz-issue"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"; mkdir -p "$MOCK"
OUT="$WORK/issue"

# Mock hostname so the banner content is deterministic: `hostname` prints the
# nodename, `hostname -I` prints the address list.
cat > "$MOCK/hostname" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-I" ]; then printf '%s\n' "${CZ_TEST_IPS:-}"
else printf '%s\n' "${CZ_TEST_HOST:-mockhost}"; fi
EOF
chmod +x "$MOCK/hostname"
export PATH="$MOCK:$PATH"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — missing [$2] in: $1" ;; esac; }

gen() { # gen <host> <ips> [width]
    rm -f "$OUT"
    # Assignments must be literal in the source: a ${3:+VAR=$3} expansion happens
    # after bash has already parsed the command prefix, so it would be treated as
    # a command name rather than an environment assignment.
    if [ -n "${3:-}" ]; then
        CZ_TEST_HOST="$1" CZ_TEST_IPS="$2" CZ_ISSUE_OUT="$OUT" CZ_ISSUE_WIDTH="$3" bash "$CZ"
    else
        CZ_TEST_HOST="$1" CZ_TEST_IPS="$2" CZ_ISSUE_OUT="$OUT" bash "$CZ"
    fi
}

# widths <label> <expected-columns> — every line exactly N columns, and report
# any that differ.
widths() {
    local l w bad=0 n=0
    while IFS= read -r l; do
        n=$((n+1)); w=${#l}
        [ "$w" -eq "$2" ] || { bad "$1 line $n is $w columns, want $2: [$l]"; bad=1; }
    done < "$OUT"
    [ "$n" = 5 ] || { bad "$1 has $n lines, want 5"; bad=1; }
    [ "$bad" = 0 ] && ok "$1: 5 lines, every one exactly $2 columns"
    return $bad
}

# boxshape <label> — corners and sides must be the right glyphs in the right places.
boxshape() {
    local l1 l5 b=0
    l1=$(sed -n 1p "$OUT"); l5=$(sed -n 5p "$OUT")
    case "$l1" in '╔'*'╗') ;; *) bad "$1 top rule is not ╔…╗: [$l1]"; b=1 ;; esac
    case "$l5" in '╚'*'╝') ;; *) bad "$1 bottom rule is not ╚…╝: [$l5]"; b=1 ;; esac
    while IFS= read -r l; do
        case "$l" in '║'*'║') ;; '╔'*|'╚'*) ;; *) bad "$1 row has no side borders: [$l]"; b=1 ;; esac
    done < "$OUT"
    [ "$b" = 0 ] && ok "$1 is a fully bordered box (sides, not just rules)"
    return $b
}

echo "=== typical device (czero-test / 192.0.2.235) ==="
gen czero-test '192.0.2.235 2001:db8::1'
echo "--- rendered ---"; cat "$OUT"; echo "----------------"
widths "typical" 53
boxshape "typical"
body=$(cat "$OUT")
has "$body" "C A R D P U T E R   Z E R O" "title is present"
has "$body" "CM0 console" "the CM0 console label is present"
has "$body" "czero-test" "hostname is baked in, not left as an agetty escape"
has "$body" "192.0.2.235" "first IPv4 address is baked in"
case "$body" in *'\n'*|*'\\4'*) bad "agetty escapes leaked into the banner" ;;
    *) ok "no unresolved \\n or \\4 escapes remain" ;; esac
[ "$(grep -c '2001:' "$OUT")" = 0 ] && ok "IPv6 address is not shown" || bad "IPv6 leaked into the banner"
# The detail line must be centred, not merely padded on one side.
det=$(sed -n 4p "$OUT" | sed 's/^║//; s/║$//')
lead=${det%%[! ]*}                # leading spaces
rest=${det%"${det##*[! ]}"}       # det with its trailing spaces removed
l=${#lead}; r=$(( ${#det} - ${#rest} ))
if [ $(( l - r )) -le 1 ] && [ $(( r - l )) -le 1 ]; then ok "detail line is centred (left $l / right $r)"
else bad "detail line is off-centre (left $l / right $r)"; fi

echo "=== no address yet (early boot, network down) ==="
gen czero-test ''
widths "no-ip" 53
boxshape "no-ip"
has "$(cat "$OUT")" "no address yet" "missing address degrades to a placeholder"

echo "=== long hostname and address (must truncate, not widen) ==="
gen 'a-very-long-hostname-that-will-not-fit-in-the-box-at-all' '255.255.255.255'
widths "long" 53
boxshape "long"

echo "=== single-character values ==="
gen h '1.1.1.1'
widths "tiny" 53
boxshape "tiny"

echo "=== width is derived, not hardcoded ==="
gen czero-test '10.0.0.5' 40
widths "narrow" 40
boxshape "narrow"

echo "=== idempotent, and leaves no temp files ==="
gen czero-test '192.0.2.235'; first=$(cat "$OUT")
gen czero-test '192.0.2.235'; second=$(cat "$OUT")
[ "$first" = "$second" ] && ok "regenerating produces identical output" || bad "output is not stable"
leftover=$(find "$WORK" -maxdepth 1 -name 'issue.*' | wc -l)
[ "$leftover" = 0 ] && ok "no temp files left beside the banner" || bad "$leftover temp files left behind"

echo "=== file mode ==="
m=$(stat -c %a "$OUT")
[ "$m" = 644 ] && ok "banner is mode 0644" || bad "banner mode is $m"

echo "=== always exits 0 (a failed ExecStartPre must not kill the login prompt) ==="
gen czero-test '192.0.2.235' >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "exit 0 on success" || bad "exit $rc on success"
CZ_ISSUE_OUT="$WORK/nonexistent-dir/issue" bash "$CZ" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit 0 even when the output path is unwritable" || bad "exit $rc on unwritable path"

echo
if [ "$fail" = 0 ]; then echo "CZ-ISSUE OK"; else echo "CZ-ISSUE PROBLEM"; exit 1; fi
