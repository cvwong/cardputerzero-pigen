#!/bin/bash
# E2E test for cz-files: the on-demand file manager menu and the lifecycle of the
# web server it launches.
#
# The security-critical property here is that the server dies with the menu. An
# endpoint that can read, write and delete files must not outlive the session
# that started it, so that gets its own assertion rather than being assumed.
# Run: bash tests/cz-files-e2e.sh
set -u
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/06-cpz-features/files/cz-files"
WORK=$(mktemp -d)
MOCK="$WORK/bin"; mkdir -p "$MOCK"
ROOT="$WORK/shared"; mkdir -p "$ROOT"

export CZ_THEME="$HERE/../stage2/06-cpz-features/files/cz-theme.sh"
export CZ_FILES_WEB="$HERE/../stage2/06-cpz-features/files/cz-files-web.py"
export CZ_FILES_ROOT="$ROOT"
export CZ_FILES_LOG="$WORK/srv.log"

printf '#!/bin/bash\nexit 0\n' > "$MOCK/clear"; chmod +x "$MOCK/clear"
export PATH="$MOCK:$PATH"
CURL() { command curl -s --max-time 20 "$@"; }

trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — missing [$2]" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 — unexpected [$2]" ;; *) ok "$3" ;; esac; }

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'; }

# boxed <label> <output> — every box row exactly 53 columns, top and bottom present.
boxed() {
    local body l w b=0 rows=0
    body=$(strip "$2")
    printf '%s\n' "$body" | grep -q '^╔═\{51\}╗$' || { bad "$1 has no 53-wide box top"; b=1; }
    printf '%s\n' "$body" | grep -q '^╚═\{51\}╝$' || { bad "$1 has no 53-wide box bottom"; b=1; }
    while IFS= read -r l; do
        [ -n "$l" ] && rows=$((rows + 1))
        w=${#l}
        [ "$w" -le 53 ] || { bad "$1 line is $w columns (want <=53): [$l]"; b=1; }
    done <<< "$body"
    [ "$rows" -le 13 ] || { bad "$1 uses $rows rows, over the 13-row tmux budget"; b=1; }
    [ "$b" = 0 ] && ok "$1 is a well-formed box within 53x13 ($rows rows)"
    return $b
}

echo "=== the account the web UI will authenticate against ==="
u=$(bash "$CZ" user)
if [ "$u" = "$(id -un)" ]; then ok "reports the invoking account ($u)"
else bad "user subcommand gave '$u', expected $(id -un)"; fi

echo "=== start: prints a working URL ==="
P=$(free_port); export CZ_FILES_PORT="$P"
echo "shared payload" > "$ROOT/hello.txt"
bash "$CZ" start > "$WORK/url.txt" 2>"$WORK/start.err" &
SPID=$!
for _ in $(seq 1 60); do [ -s "$WORK/url.txt" ] && break; sleep 0.15; done
URL=$(cat "$WORK/url.txt")
echo "  url=$URL"
has "$URL" "http://" "URL has a scheme"
has "$URL" ":$P" "URL uses the requested port"
hasnt "$URL" "token=" "the URL carries no token now that login is used"
hasnt "$URL" "user=" "the printed URL stops before the log line's user= field"
c=$(CURL -o "$WORK/idx" -w '%{http_code}' "$URL")
[ "$c" = 200 ] && ok "the printed URL serves the sign-in page (200)" || bad "URL gave HTTP $c"
has "$(cat "$WORK/idx")" 'type="password"' "an anonymous visitor gets a sign-in form"
hasnt "$(cat "$WORK/idx")" "hello.txt" "an anonymous visitor cannot see any filename"
c=$(CURL -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P/download?path=hello.txt")
[ "$c" = 403 ] && ok "download without a session is refused" || bad "anonymous download gave $c"

echo "=== the server must die with cz-files ==="
PYPID=$(pgrep -P "$SPID" 2>/dev/null | head -1)
kill "$SPID" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
sleep 0.5
if [ -n "$PYPID" ] && kill -0 "$PYPID" 2>/dev/null; then
    bad "LEAK: web server pid $PYPID outlived cz-files"
    kill "$PYPID" 2>/dev/null
else
    ok "web server child was reaped"
fi
if port_open "$P"; then bad "LEAK: port $P still listening after cz-files exited"
else ok "port released when cz-files exited"; fi

echo "=== port fallback when the preferred port is taken ==="
python3 - "$P" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(5); time.sleep(25)
PY
HOG=$!
sleep 1
if port_open "$P"; then ok "test hog is holding port $P"; else bad "could not occupy the port to test fallback"; fi
bash "$CZ" start > "$WORK/url2.txt" 2>"$WORK/start2.err" &
S2=$!
for _ in $(seq 1 60); do [ -s "$WORK/url2.txt" ] && break; sleep 0.15; done
URL2=$(cat "$WORK/url2.txt")
if [ -n "$URL2" ] && [ "$URL2" != "$URL" ]; then
    ok "fell back to another port: $URL2"
    c=$(CURL -o /dev/null -w '%{http_code}' "$URL2")
    [ "$c" = 200 ] && ok "the fallback URL serves 200" || bad "fallback URL gave HTTP $c"
else
    bad "no fallback when the port was busy (url='$URL2')"
fi
kill "$S2" 2>/dev/null; kill "$HOG" 2>/dev/null; wait "$S2" 2>/dev/null; wait "$HOG" 2>/dev/null
sleep 0.5

echo "=== menu screen ==="
P=$(free_port); export CZ_FILES_PORT="$P"
out=$(printf '0' | bash "$CZ" 2>&1)
boxed "FILES menu" "$out"
s=$(strip "$out")
has "$s" "FILES" "menu title is FILES"
has "$s" "1 Start web server" "offers Start web server"
has "$s" "2 Shared folder" "offers changing the shared folder"
has "$s" "3 Browse files" "offers browsing"
has "$s" "0 Back (stops server)" "Back says it stops the server"
hasnt "$s" "New token" "the token menu entry is gone"
has "$s" "sign in: $(id -un)" "shows which device account to sign in as"
has "$s" "device password" "says the sign-in uses the device password"
has "$s" "http://" "shows the URL to visit"
has "$s" "$ROOT" "shows the shared root"
if port_open "$P"; then bad "LEAK: leaving the menu left the server listening"; else ok "leaving the menu stopped the server"; fi

echo "=== changing the shared folder ==="
mkdir -p "$WORK/other"; echo "elsewhere" > "$WORK/other/o.txt"
P=$(free_port); export CZ_FILES_PORT="$P"
# '2' opens the prompt, the path is read by `read -r`, then '0' exits the menu.
out=$(printf '2%s\n0' "$WORK/other" | bash "$CZ" 2>&1)
has "$(strip "$out")" "$WORK/other" "the new shared folder is shown"
hasnt "$(strip "$out")" "Not a directory" "an existing directory was accepted"
if port_open "$P"; then bad "LEAK: server still up after folder change"; else ok "server stopped on exit"; fi

echo "=== a nonexistent folder is rejected ==="
P=$(free_port); export CZ_FILES_PORT="$P"
out=$(printf '2%s\n0' "$WORK/does-not-exist" | bash "$CZ" 2>&1)
has "$(strip "$out")" "Not a directory" "rejects a folder that does not exist"

echo "=== browse screen shows sizes with units ==="
printf '0123456789' > "$ROOT/tenbytes"   # exactly 10 bytes
out=$(printf '0' | bash "$CZ" browse 2>&1)
boxed "browse screen" "$out"
bs=$(strip "$out")
has "$bs" "tenbytes" "browse lists the file"
has "$bs" "10B" "size carries a unit (regression: du -h printed a bare '10')"
has "$bs" "$ROOT" "browse names the folder it is showing"

echo "=== usage ==="
out=$(bash "$CZ" bogus 2>&1); rc=$?
has "$out" "usage: cz-files" "unknown subcommand prints usage"
[ "$rc" = 1 ] && ok "unknown subcommand exits 1" || bad "usage rc=$rc"

echo
if [ "$fail" = 0 ]; then echo "CZ-FILES OK"; else echo "CZ-FILES PROBLEM"; exit 1; fi
