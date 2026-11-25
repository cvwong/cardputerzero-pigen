#!/bin/bash
# Unit test for cz-output: the foreground-VT toggle between panel (tty1) and
# monitor (tty2). chvt/fgconsole are stubbed so the host VTs are untouched.
# Run: bash tests/cz-output.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../stage2/06-cpz-features/files/cz-output"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/chvt" <<'EOF'
#!/bin/bash
printf 'chvt %s\n' "$1" >> "$CHVTLOG"
EOF
cat > "$STUB/fgconsole" <<'EOF'
#!/bin/bash
printf '%s\n' "${FG_CURRENT:-1}"
EOF
chmod +x "$STUB/chvt" "$STUB/fgconsole"
export PATH="$STUB:$PATH"

run() { CHVTLOG="$WORK/chvtlog" FG_CURRENT="${FG_CURRENT:-1}" bash "$TOOL" "$@"; }

echo "=== monitor switches the foreground VT to tty2 ==="
: > "$WORK/chvtlog"
run monitor
grep -q '^chvt 2$' "$WORK/chvtlog" && ok "cz-output monitor runs chvt 2" || bad "chvt 2 not called: $(cat "$WORK/chvtlog")"

echo "=== panel switches back to tty1 ==="
: > "$WORK/chvtlog"
run panel
grep -q '^chvt 1$' "$WORK/chvtlog" && ok "cz-output panel runs chvt 1" || bad "chvt 1 not called: $(cat "$WORK/chvtlog")"

echo "=== no argument reports the current output ==="
[ "$(FG_CURRENT=2 run)" = monitor ] && ok "reports monitor when fg is tty2" || bad "wrong report for fg 2: $(FG_CURRENT=2 run)"
[ "$(FG_CURRENT=1 run)" = panel ] && ok "reports panel when fg is tty1" || bad "wrong report for fg 1: $(FG_CURRENT=1 run)"

echo "=== bad argument is refused ==="
out=$(run sideways 2>&1); rc=$?
[ "$rc" = 2 ] && ok "exit 2 on bad argument" || bad "rc=$rc on bad argument"
case "$out" in *usage*) ok "prints usage" ;; *) bad "no usage text: $out" ;; esac

echo
if [ "$fail" = 0 ]; then echo "CZ-OUTPUT OK"; else echo "CZ-OUTPUT PROBLEM"; exit 1; fi
