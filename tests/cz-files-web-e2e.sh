#!/bin/bash
# E2E test for cz-files-web.py: the on-demand file transfer server.
#
# This serves file read, write and delete to the local network, so the tests
# concentrate on the things that must never break: the token gate, path
# containment (including via encoded separators and symlinks), upload integrity
# for a file larger than the parser's chunk size, and refusal to delete
# directories.
# Run: bash tests/cz-files-web-e2e.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WEB="$HERE/../stage2/06-cpz-features/files/cz-files-web.py"
WORK=$(mktemp -d)
ROOT="$WORK/root"
SRVPID=""

cleanup() {
    if [ -n "$SRVPID" ] && kill -0 "$SRVPID" 2>/dev/null; then
        kill "$SRVPID" 2>/dev/null
        wait "$SRVPID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v curl >/dev/null || { echo "curl required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# Every request is time-boxed: a parser that hangs would otherwise wedge the
# whole suite instead of failing one assertion.
CURL() { command curl -s --max-time 30 "$@"; }

# Pick a port the OS says is free, rather than hardcoding one that may be taken.
PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
TOKEN="t0ken-abc123"
BASE="http://127.0.0.1:$PORT"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — missing [$2]" ;; esac; }
code() { CURL -o "$WORK/body" -w '%{http_code}' "$@"; }

# ---- fixture ----------------------------------------------------------
mkdir -p "$ROOT/sub" "$ROOT/emptydir"
printf 'hello world\n'   > "$ROOT/a.txt"
printf 'nested file\n'   > "$ROOT/sub/b.txt"
# Larger than the parser's 256KB chunk so the streaming loop is really exercised.
head -c 700000 /dev/urandom > "$ROOT/big.bin"
BIG_SUM=$(md5sum "$ROOT/big.bin" | cut -d' ' -f1)
# A symlink that escapes the root: containment must catch it even though it is
# inside the shared tree.
ln -s /etc/passwd "$ROOT/escape-link" 2>/dev/null || true
printf 'outside\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$ROOT/sub/up-link" 2>/dev/null || true

python3 "$WEB" --root "$ROOT" --port "$PORT" --token "$TOKEN" > "$WORK/srv.log" 2>&1 &
SRVPID=$!
for _ in $(seq 1 60); do
    CURL -o /dev/null "$BASE/?token=$TOKEN" 2>/dev/null && break
    sleep 0.1
done
if ! kill -0 "$SRVPID" 2>/dev/null; then
    echo "server failed to start:"; cat "$WORK/srv.log"; exit 1
fi

echo "=== token gate ==="
c=$(code "$BASE/");                       [ "$c" = 403 ] && ok "no token -> 403" || bad "no token gave $c"
c=$(code "$BASE/?token=wrong");           [ "$c" = 403 ] && ok "wrong token -> 403" || bad "wrong token gave $c"
c=$(code "$BASE/?token=$TOKEN");          [ "$c" = 200 ] && ok "correct token -> 200" || bad "correct token gave $c"
c=$(code "$BASE/download?path=a.txt");    [ "$c" = 403 ] && ok "download without token -> 403" || bad "download without token gave $c"

echo "=== listing ==="
body=$(CURL "$BASE/?token=$TOKEN")
has "$body" "a.txt" "lists a plain file"
has "$body" "big.bin" "lists a binary file"
has "$body" "sub/" "marks directories with a trailing slash"
c=$(code "$BASE/?path=sub&token=$TOKEN"); [ "$c" = 200 ] && ok "subdirectory listing -> 200" || bad "subdir listing gave $c"
has "$(cat "$WORK/body")" "b.txt" "subdirectory lists its own contents"
c=$(code "$BASE/?path=emptydir&token=$TOKEN")
has "$(cat "$WORK/body")" "empty folder" "empty directory says so instead of an empty table"

echo "=== download ==="
got=$(CURL "$BASE/download?path=a.txt&token=$TOKEN")
[ "$got" = "hello world" ] && ok "download returns the exact file content" || bad "download returned [$got]"
sum=$(CURL "$BASE/download?path=big.bin&token=$TOKEN" | md5sum | cut -d' ' -f1)
[ "$sum" = "$BIG_SUM" ] && ok "700KB binary downloads byte-identical (streamed correctly)" || bad "binary corrupted: $sum != $BIG_SUM"
cd=$(CURL -D - -o /dev/null "$BASE/download?path=a.txt&token=$TOKEN")
has "$cd" 'Content-Disposition: attachment' "download is an attachment, not inline"
has "$cd" 'filename="a.txt"' "attachment carries the filename"

echo "=== path traversal must be refused ==="
for p in '../../../../etc/passwd' '..%2f..%2f..%2f..%2fetc%2fpasswd' '/etc/passwd' \
         'sub/../../etc/passwd' '%2e%2e%2f%2e%2e%2fetc%2fpasswd' '..\..\..\etc\passwd' \
         '....//....//etc/passwd'; do
    c=$(code "$BASE/download?path=$p&token=$TOKEN")
    if grep -q 'root:.*:0:0:' "$WORK/body" 2>/dev/null; then
        bad "LEAKED /etc/passwd for path [$p]"
    elif [ "$c" = 403 ] || [ "$c" = 404 ]; then
        ok "blocked [$p] -> $c"
    else
        bad "unexpected status $c for [$p]"
    fi
done

echo "=== symlinks pointing outside the root ==="
if [ -L "$ROOT/escape-link" ]; then
    c=$(code "$BASE/download?path=escape-link&token=$TOKEN")
    if grep -q 'root:.*:0:0:' "$WORK/body" 2>/dev/null; then bad "SYMLINK ESCAPED: served /etc/passwd"
    else ok "symlink to /etc/passwd refused ($c)"; fi
else
    echo "  (symlink fixture unavailable on this filesystem, skipped)"
fi

echo "=== upload ==="
printf 'uploaded content\n' > "$WORK/new.txt"
c=$(CURL -o "$WORK/body" -w '%{http_code}' -F "files=@$WORK/new.txt" "$BASE/upload?path=&token=$TOKEN")
[ "$c" = 303 ] && ok "upload redirects (303)" || bad "upload gave $c"
[ -f "$ROOT/new.txt" ] && ok "uploaded file landed in the shared root" || bad "uploaded file missing"
[ "$(cat "$ROOT/new.txt" 2>/dev/null)" = "uploaded content" ] && ok "uploaded content is intact" || bad "uploaded content wrong"
loc=$(CURL -D - -o /dev/null -F "files=@$WORK/new.txt" "$BASE/upload?path=&token=$TOKEN" | grep -i '^location:')
has "$loc" "token=$TOKEN" "redirect preserves the token so the browser stays authorized"

echo "=== multiple files in one request ==="
printf 'one\n' > "$WORK/m1.txt"; printf 'two\n' > "$WORK/m2.txt"; printf 'three\n' > "$WORK/m3.txt"
CURL -o /dev/null -F "files=@$WORK/m1.txt" -F "files=@$WORK/m2.txt" -F "files=@$WORK/m3.txt" \
    "$BASE/upload?path=&token=$TOKEN"
n=0; for f in m1.txt m2.txt m3.txt; do [ -f "$ROOT/$f" ] && n=$((n+1)); done
[ "$n" = 3 ] && ok "all 3 files from one multipart request were saved" || bad "only $n of 3 multi-upload files saved"

echo "=== upload into a subdirectory ==="
printf 'into sub\n' > "$WORK/s.txt"
CURL -o /dev/null -F "files=@$WORK/s.txt" "$BASE/upload?path=sub&token=$TOKEN"
[ "$(cat "$ROOT/sub/s.txt" 2>/dev/null)" = "into sub" ] && ok "upload honours the target subdirectory" || bad "upload to subdir failed"

echo "=== a large upload survives the chunked parser ==="
head -c 900000 /dev/urandom > "$WORK/large.bin"
LSUM=$(md5sum "$WORK/large.bin" | cut -d' ' -f1)
CURL -o /dev/null -F "files=@$WORK/large.bin" "$BASE/upload?path=&token=$TOKEN"
GOT=$(md5sum "$ROOT/large.bin" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$LSUM" ] && ok "900KB upload is byte-identical" || bad "900KB upload corrupted ($GOT != $LSUM)"

echo "=== uploading a filename with a path is flattened ==="
CURL -o /dev/null -F "files=@$WORK/new.txt;filename=../../evil.txt" "$BASE/upload?path=&token=$TOKEN"
[ -f "$WORK/evil.txt" ] && bad "UPLOAD ESCAPED: wrote outside the root" || ok "traversing filename was flattened"
[ -f "$ROOT/evil.txt" ] && ok "flattened file stayed inside the root" || bad "flattened upload not found in root"

echo "=== no name collision: existing file is not overwritten ==="
before=$(cat "$ROOT/new.txt")
printf 'different\n' > "$WORK/new.txt"
CURL -o /dev/null -F "files=@$WORK/new.txt" "$BASE/upload?path=&token=$TOKEN"
[ "$(cat "$ROOT/new.txt")" = "$before" ] && ok "original file preserved" || bad "existing file was overwritten"
[ -f "$ROOT/new-1.txt" ] && ok "collision saved as new-1.txt" || bad "no de-duplicated copy created"

echo "=== delete ==="
printf 'doomed\n' > "$ROOT/gone.txt"
c=$(CURL -o "$WORK/body" -w '%{http_code}' --data-urlencode "path=gone.txt" "$BASE/delete?token=$TOKEN")
[ "$c" = 303 ] && ok "delete redirects" || bad "delete gave $c"
[ ! -e "$ROOT/gone.txt" ] && ok "file was deleted" || bad "file still present"

echo "=== delete refuses directories ==="
c=$(CURL -o /dev/null -w '%{http_code}' --data-urlencode "path=sub" "$BASE/delete?token=$TOKEN")
[ -d "$ROOT/sub" ] && ok "directory deletion refused, sub/ intact" || bad "DIRECTORY WAS DELETED"
[ -f "$ROOT/sub/b.txt" ] && ok "directory contents intact" || bad "directory contents lost"
c=$(CURL -o /dev/null -w '%{http_code}' --data-urlencode "path=" "$BASE/delete?token=$TOKEN")
[ -d "$ROOT" ] && ok "deleting the shared root is refused" || bad "SHARED ROOT WAS DELETED"

echo "=== delete cannot escape the root ==="
CURL -o /dev/null --data-urlencode "path=../../outside.txt" "$BASE/delete?token=$TOKEN"
[ -f "$WORK/outside.txt" ] && ok "file outside the root survived" || bad "DELETED A FILE OUTSIDE THE ROOT"

echo "=== leftovers ==="
junk=$(find "$ROOT" -name '.czup-*' | wc -l)
[ "$junk" = 0 ] && ok "no temp upload files left behind" || bad "$junk temp files left in the root"

echo "=== refusing dangerous roots ==="
out=$(python3 "$WEB" --root / --port "$PORT" --token x 2>&1); rc=$?
[ "$rc" != 0 ] && ok "refuses to serve / (exit $rc)" || bad "agreed to serve the whole filesystem"
has "$out" "refusing" "says why it refused"

echo
if [ "$fail" = 0 ]; then echo "CZ-FILES-WEB OK"; else echo "CZ-FILES-WEB PROBLEM"; exit 1; fi
