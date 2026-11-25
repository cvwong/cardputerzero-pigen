#!/bin/bash
# Unit tests for the monitor compositor stack:
#  - cz-monitor-session: Waiting until the panel-login flag, then a bare
#    shell; on shell exit it hands the console back to the panel.
#  - cz-cage-watcher: starts cz-cage when the foreground VT is 2 (Alt+M),
#    stops it when the foreground is 1 (Alt+P / session exit).
# Run: bash tests/cz-monitor-stack.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SESSION="$HERE/../stage2/06-cpz-features/files/cz-monitor-session"
WATCHER="$HERE/../stage2/06-cpz-features/files/cz-cage-watcher"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/cz-output" <<'EOF'
#!/bin/bash
printf 'cz-output %s\n' "$1" >> "$CZLOG"
EOF
chmod +x "$STUB/cz-output"
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
if [ "$1" = is-active ]; then exit 1; fi
printf 'systemctl %s\n' "$*" >> "$CZLOG"
EOF
chmod +x "$STUB/systemctl"
cat > "$STUB/fgconsole" <<'EOF'
#!/bin/bash
printf '%s\n' "${FG_CURRENT:-1}"
EOF
chmod +x "$STUB/fgconsole"
export PATH="$STUB:$PATH"

echo "=== session before panel login: Waiting, then shell, then hand back ==="
: > "$WORK/czlog"
FLAG="$WORK/flag"
( sleep 1; : > "$FLAG" ) &
out=$(CZ_MON_FLAG="$FLAG" CZLOG="$WORK/czlog" bash "$SESSION" <<< 'exit')
wait
case "$out" in *Waiting*) ok "shows Waiting before login" ;; *) bad "no Waiting: [$out]" ;; esac
grep -q 'cz-output panel' "$WORK/czlog" && ok "hands the console back after the shell exits" \
    || bad "no hand-back: $(cat "$WORK/czlog")"

echo "=== session after panel login: no Waiting, straight to the shell ==="
: > "$WORK/czlog"; : > "$WORK/flag"
out=$(CZ_MON_FLAG="$WORK/flag" CZLOG="$WORK/czlog" bash "$SESSION" <<< 'echo MARKER_RUN; exit')
case "$out" in *Waiting*) bad "Waiting shown despite login flag" ;; *) ok "no Waiting after login" ;; esac
case "$out" in *MARKER_RUN*) ok "bare shell ran" ;; *) bad "shell did not run: [$out]" ;; esac

echo "=== watcher: fg 2 starts the compositor ==="
: > "$WORK/czlog"
CZLOG="$WORK/czlog" FG_CURRENT=2 CZ_WATCH_LOOPS=1 CZ_WATCH_SLEEP=0 bash "$WATCHER"
grep -q 'systemctl start --no-block cz-cage.service' "$WORK/czlog" \
    && ok "cz-cage started on fg 2" || bad "no start: $(cat "$WORK/czlog")"

echo "=== watcher: fg 1 stops the compositor ==="
: > "$WORK/czlog"
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
if [ "$1" = is-active ]; then exit 0; fi
printf 'systemctl %s\n' "$*" >> "$CZLOG"
EOF
chmod +x "$STUB/systemctl"
CZLOG="$WORK/czlog" FG_CURRENT=1 CZ_WATCH_LOOPS=1 CZ_WATCH_SLEEP=0 bash "$WATCHER"
grep -q 'systemctl stop --no-block cz-cage.service' "$WORK/czlog" \
    && ok "cz-cage stopped on fg 1" || bad "no stop: $(cat "$WORK/czlog")"

echo
if [ "$fail" = 0 ]; then echo "CZ-MONITOR-STACK OK"; else echo "CZ-MONITOR-STACK PROBLEM"; exit 1; fi
