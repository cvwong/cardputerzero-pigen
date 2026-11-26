#!/bin/bash
# E2E test for cz-files-web.py: the on-demand file transfer server.
#
# This serves file read, write, create and delete to the local network, so the
# tests concentrate on what must never break: the login gate, path containment
# (including via encoded separators and symlinks), upload integrity across the
# parser's chunk boundary, folder creation, and refusal to delete directories.
#
# Password checking is exercised for real by putting a mock `sudo` on PATH: the
# server shells out to `sudo -S -k -p "" true`, so the mock sees the same call
# and accepts or rejects by comparing stdin. No test-only hooks in the server.
# Run: bash tests/cz-files-web-e2e.sh
set -u
export LC_ALL=C.UTF-8
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

MOCK="$WORK/bin"; mkdir -p "$MOCK"
export CZ_TEST_PASSWORD="correct horse battery"
export CZ_TEST_CALLS="$WORK/calls.log"
cat > "$MOCK/sudo" <<'EOF'
#!/bin/bash
read -r pw
printf '%s\n' "sudo called" >> "$CZ_TEST_CALLS"
[ "$pw" = "$CZ_TEST_PASSWORD" ] && exit 0
exit 1
EOF
chmod +x "$MOCK/sudo"
export PATH="$MOCK:$PATH"
: > "$CZ_TEST_CALLS"

RUN_USER=$(id -un)
JAR="$WORK/cookies"
PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
BASE="http://127.0.0.1:$PORT"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — missing [$2]" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 — unexpected [$2]" ;; *) ok "$3" ;; esac; }
CURL() { command curl -s --max-time 30 "$@"; }
req()   { CURL -b "$JAR" -c "$JAR" "$@"; }              # authenticated
code()  { req  -o "$WORK/body" -w '%{http_code}' "$@"; }
rcode() { CURL -o "$WORK/body" -w '%{http_code}' "$@"; } # anonymous
login() { CURL -b "$JAR" -c "$JAR" -o "$WORK/body" -w '%{http_code}' \
            --data-urlencode "username=$1" --data-urlencode "password=$2" "$BASE/login"; }

# ---- fixture ----------------------------------------------------------
mkdir -p "$ROOT/sub" "$ROOT/emptydir"
printf 'hello world\n' > "$ROOT/a.txt"
printf 'nested file\n' > "$ROOT/sub/b.txt"
# Larger than the parser's 256KB chunk so the streaming loop is really exercised.
head -c 700000 /dev/urandom > "$ROOT/big.bin"
BIG_SUM=$(md5sum "$ROOT/big.bin" | cut -d' ' -f1)
ln -s /etc/passwd "$ROOT/escape-link" 2>/dev/null || true
printf 'outside\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$ROOT/sub/up-link" 2>/dev/null || true

python3 "$WEB" --root "$ROOT" --port "$PORT" > "$WORK/srv.log" 2>&1 &
SRVPID=$!
for _ in $(seq 1 60); do
    CURL -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.15
done
if ! kill -0 "$SRVPID" 2>/dev/null; then
    echo "server failed to start:"; cat "$WORK/srv.log"; exit 1
fi

echo "=== unauthenticated access is refused ==="
c=$(rcode "$BASE/")
[ "$c" = 200 ] && ok "GET / shows a sign-in page (200)" || bad "GET / gave $c"
page=$(cat "$WORK/body")
has "$page" 'type="password"' "sign-in page has a password field"
has "$page" "Sign in" "sign-in page offers a Sign in button"
has "$page" "unencrypted" "sign-in page warns the password is not encrypted"
has "$page" "$RUN_USER" "sign-in page pre-fills the device account"
c=$(rcode "$BASE/download?path=a.txt")
[ "$c" = 403 ] && ok "download without a session -> 403" || bad "download without session gave $c"
c=$(rcode "$BASE/?path=sub")
hasnt "$(cat "$WORK/body")" "b.txt" "an anonymous browse leaks no filenames"

echo "=== login ==="
c=$(login "$RUN_USER" "$CZ_TEST_PASSWORD")
[ "$c" = 303 ] && ok "correct credentials -> 303 redirect" || bad "login gave $c"
[ -s "$JAR" ] && ok "a session cookie was set" || bad "no session cookie stored"
grep -q "czsid" "$JAR" && ok "the cookie is the session id" || bad "unexpected cookie name"
hdrs=$(req -D - -o /dev/null "$BASE/")
has "$hdrs" "no-store" "pages are not cached"

echo "=== authenticated browsing ==="
c=$(code "$BASE/")
[ "$c" = 200 ] && ok "index with session -> 200" || bad "index gave $c"
body=$(cat "$WORK/body")
has "$body" "a.txt" "lists a plain file"
has "$body" "big.bin" "lists a binary file"
has "$body" "sub/" "marks directories with a trailing slash"
has "$body" "Sign out" "offers sign out"
has "$body" "Create folder" "offers folder creation"
has "$body" "$RUN_USER" "shows the signed-in account"
c=$(code "$BASE/?path=sub"); [ "$c" = 200 ] && ok "subdirectory listing -> 200" || bad "subdir gave $c"
has "$(cat "$WORK/body")" "b.txt" "subdirectory lists its own contents"
code "$BASE/?path=emptydir" >/dev/null
has "$(cat "$WORK/body")" "empty folder" "empty directory says so instead of an empty table"

echo "=== download ==="
got=$(req "$BASE/download?path=a.txt")
[ "$got" = "hello world" ] && ok "download returns the exact file content" || bad "download returned [$got]"
sum=$(req "$BASE/download?path=big.bin" | md5sum | cut -d' ' -f1)
[ "$sum" = "$BIG_SUM" ] && ok "700KB binary downloads byte-identical" || bad "corrupted: $sum != $BIG_SUM"
cd=$(req -D - -o /dev/null "$BASE/download?path=a.txt")
has "$cd" 'Content-Disposition: attachment' "download is an attachment, not inline"

echo "=== path traversal must be refused ==="
for p in '../../../../etc/passwd' '..%2f..%2f..%2f..%2fetc%2fpasswd' '/etc/passwd' \
         'sub/../../etc/passwd' '%2e%2e%2f%2e%2e%2fetc%2fpasswd' '..\..\..\etc\passwd' \
         '....//....//etc/passwd'; do
    c=$(code "$BASE/download?path=$p")
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
    c=$(code "$BASE/download?path=escape-link")
    if grep -q 'root:.*:0:0:' "$WORK/body" 2>/dev/null; then bad "SYMLINK ESCAPED: served /etc/passwd"
    else ok "symlink to /etc/passwd refused ($c)"; fi
else
    echo "  (symlink fixture unavailable on this filesystem, skipped)"
fi

echo "=== upload ==="
printf 'uploaded content\n' > "$WORK/new.txt"
c=$(req -o "$WORK/body" -w '%{http_code}' -F "files=@$WORK/new.txt" "$BASE/upload?path=")
[ "$c" = 303 ] && ok "upload redirects (303)" || bad "upload gave $c"
[ "$(cat "$ROOT/new.txt" 2>/dev/null)" = "uploaded content" ] && ok "uploaded content is intact" || bad "uploaded content wrong"
m=$(stat -c %a "$ROOT/new.txt" 2>/dev/null)
[ "$m" = 644 ] && ok "uploaded file is 0644, not mkstemp's 0600" || bad "uploaded file mode is $m"
c=$(CURL -o /dev/null -w '%{http_code}' -F "files=@$WORK/new.txt" "$BASE/upload?path=")
[ "$c" = 403 ] && ok "upload without a session -> 403" || bad "unauthenticated upload gave $c"

echo "=== multiple files in one request ==="
printf 'one\n' > "$WORK/m1.txt"; printf 'two\n' > "$WORK/m2.txt"; printf 'three\n' > "$WORK/m3.txt"
req -o /dev/null -F "files=@$WORK/m1.txt" -F "files=@$WORK/m2.txt" -F "files=@$WORK/m3.txt" "$BASE/upload?path="
n=0; for f in m1.txt m2.txt m3.txt; do [ -f "$ROOT/$f" ] && n=$((n+1)); done
[ "$n" = 3 ] && ok "all 3 files from one multipart request were saved" || bad "only $n of 3 saved"

echo "=== upload into a subdirectory ==="
printf 'into sub\n' > "$WORK/s.txt"
req -o /dev/null -F "files=@$WORK/s.txt" "$BASE/upload?path=sub"
[ "$(cat "$ROOT/sub/s.txt" 2>/dev/null)" = "into sub" ] && ok "upload honours the target subdirectory" || bad "upload to subdir failed"

echo "=== a large upload survives the chunked parser ==="
head -c 900000 /dev/urandom > "$WORK/large.bin"
LSUM=$(md5sum "$WORK/large.bin" | cut -d' ' -f1)
req -o /dev/null -F "files=@$WORK/large.bin" "$BASE/upload?path="
GOT=$(md5sum "$ROOT/large.bin" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$LSUM" ] && ok "900KB upload is byte-identical" || bad "900KB corrupted ($GOT != $LSUM)"

echo "=== an uploading filename containing a path is flattened ==="
req -o /dev/null -F "files=@$WORK/new.txt;filename=../../evil.txt" "$BASE/upload?path="
[ -f "$WORK/evil.txt" ] && bad "UPLOAD ESCAPED: wrote outside the root" || ok "traversing filename was flattened"
[ -f "$ROOT/evil.txt" ] && ok "flattened file stayed inside the root" || bad "flattened upload not found in root"

echo "=== no name collision: an existing file is not overwritten ==="
before=$(cat "$ROOT/new.txt")
printf 'different\n' > "$WORK/new.txt"
req -o /dev/null -F "files=@$WORK/new.txt" "$BASE/upload?path="
[ "$(cat "$ROOT/new.txt")" = "$before" ] && ok "original file preserved" || bad "existing file was overwritten"
[ -f "$ROOT/new-1.txt" ] && ok "collision saved as new-1.txt" || bad "no de-duplicated copy created"

echo "=== create folder ==="
c=$(req -o "$WORK/body" -w '%{http_code}' --data-urlencode "name=Photos" "$BASE/mkdir?path=")
[ "$c" = 303 ] && ok "mkdir redirects" || bad "mkdir gave $c"
[ -d "$ROOT/Photos" ] && ok "folder was created" || bad "folder missing"
perm=$(stat -c %a "$ROOT/Photos" 2>/dev/null)
[ "$perm" = 755 ] && ok "folder is 0755" || bad "folder mode is $perm"

echo "=== upload into the new folder ==="
printf 'in photos\n' > "$WORK/p.txt"
req -o /dev/null -F "files=@$WORK/p.txt" "$BASE/upload?path=Photos"
[ "$(cat "$ROOT/Photos/p.txt" 2>/dev/null)" = "in photos" ] && ok "upload into the created folder works" || bad "upload into new folder failed"

echo "=== nested folder creation ==="
req -o /dev/null --data-urlencode "name=2026" "$BASE/mkdir?path=Photos"
[ -d "$ROOT/Photos/2026" ] && ok "folder created inside a subdirectory" || bad "nested folder missing"

echo "=== folder names are validated ==="
# Two things the previous version of this loop got wrong, which let a mutation
# that deleted the validation pass unnoticed:
#   - it only checked that nothing escaped the root, but Store.resolve() already
#     guarantees that on its own, so it proved nothing about this guard;
#   - it grepped the 303 response body for the error, but a redirect body is
#     empty -- the reason lives in the Location header's err= parameter.
# So assert both that the root gained nothing at all, and that the rejection
# reason is the validation's own message rather than a later fallback.
long=$(printf 'x%.0s' $(seq 1 80))
for bad_name in '../escape' '..' '.' '' 'a/b' 'a\b' "$long"; do
    label="${bad_name:-<empty>}"
    before=$(find "$ROOT" -mindepth 1 | sort)
    hdr=$(req -D - -o /dev/null --data-urlencode "name=$bad_name" "$BASE/mkdir?path=")
    after=$(find "$ROOT" -mindepth 1 | sort)
    [ -e "$WORK/escape" ] && bad "MKDIR ESCAPED the root with name [$label]"
    if [ "$before" = "$after" ]; then
        ok "[$label] created nothing in the root"
    else
        bad "[$label] was accepted; root gained: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"
    fi
    case "$hdr" in
      *invalid%20folder%20name*) ok "[$label] rejected by the name validation" ;;
      *) bad "[$label] not rejected as invalid: $(printf '%s' "$hdr" | grep -i '^location:' || echo 'no Location header, got an error page')" ;;
    esac
done
before_sub=$(stat -c %Y "$ROOT/sub")
c=$(req -o "$WORK/body" -w '%{http_code}' --data-urlencode "name=sub" "$BASE/mkdir?path=")
[ -d "$ROOT/sub" ] && ok "an existing folder is not clobbered" || bad "existing folder was destroyed"
[ "$(stat -c %Y "$ROOT/sub")" = "$before_sub" ] && ok "existing folder untouched" || bad "existing folder was modified"

echo "=== mkdir requires a session ==="
c=$(CURL -o /dev/null -w '%{http_code}' --data-urlencode "name=Sneaky" "$BASE/mkdir?path=")
[ "$c" = 403 ] && ok "mkdir without a session -> 403" || bad "unauthenticated mkdir gave $c"
[ ! -d "$ROOT/Sneaky" ] && ok "unauthenticated mkdir created nothing" || bad "UNAUTHENTICATED MKDIR CREATED A FOLDER"

echo "=== delete ==="
printf 'doomed\n' > "$ROOT/gone.txt"
c=$(req -o "$WORK/body" -w '%{http_code}' --data-urlencode "path=gone.txt" "$BASE/delete")
[ "$c" = 303 ] && ok "delete redirects" || bad "delete gave $c"
[ ! -e "$ROOT/gone.txt" ] && ok "file was deleted" || bad "file still present"

echo "=== delete refuses directories ==="
req -o /dev/null --data-urlencode "path=Photos" "$BASE/delete"
[ -d "$ROOT/Photos" ] && ok "folder deletion refused, Photos/ intact" || bad "FOLDER WAS DELETED"
[ -f "$ROOT/Photos/p.txt" ] && ok "folder contents intact" || bad "folder contents lost"
req -o /dev/null --data-urlencode "path=" "$BASE/delete"
[ -d "$ROOT" ] && ok "deleting the shared root is refused" || bad "SHARED ROOT WAS DELETED"

echo "=== delete cannot escape the root ==="
req -o /dev/null --data-urlencode "path=../../outside.txt" "$BASE/delete"
[ -f "$WORK/outside.txt" ] && ok "file outside the root survived" || bad "DELETED A FILE OUTSIDE THE ROOT"

echo "=== leftovers ==="
junk=$(find "$ROOT" -name '.czup-*' | wc -l)
[ "$junk" = 0 ] && ok "no temp upload files left behind" || bad "$junk temp files left in the root"

echo "=== logout revokes the session ==="
sid=$(awk -F'\t' '$6=="czsid"{print $7}' "$JAR" | tail -1)
[ -n "$sid" ] && ok "captured the live session id" || bad "no czsid in the cookie jar"
c=$(req -o /dev/null -w '%{http_code}' -X POST "$BASE/logout")
[ "$c" = 303 ] && ok "logout redirects" || bad "logout gave $c"
code "$BASE/" >/dev/null
has "$(cat "$WORK/body")" "Sign in" "after logout the sign-in page is shown again"
hasnt "$(cat "$WORK/body")" "big.bin" "after logout no filenames are visible"
# The jar cookie is dropped client-side on logout; replay the pre-logout id to
# prove the server revoked it, not merely the browser cookie.
c=$(CURL -o "$WORK/body" -w '%{http_code}' -H "Cookie: czsid=$sid" "$BASE/")
has "$(cat "$WORK/body")" "Sign in" "a replayed pre-logout session id is rejected"
hasnt "$(cat "$WORK/body")" "big.bin" "replayed session leaks no filenames"

echo "=== refusing dangerous roots ==="
out=$(python3 "$WEB" --root / --port "$PORT" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "refuses to serve / (exit $rc)" || bad "agreed to serve the whole filesystem"
has "$out" "refusing" "says why it refused"

echo "=== login failures (last: they trip the throttle) ==="
rm -f "$JAR"
for i in 1 2 3; do
    c=$(login "$RUN_USER" "wrong-$i")
    [ "$c" = 401 ] && ok "wrong password attempt $i -> 401" || bad "wrong password $i gave $c"
done
has "$(cat "$WORK/body")" "Wrong username or password" "failure does not reveal which part was wrong"
c=$(login "root" "$CZ_TEST_PASSWORD")
[ "$c" = 401 ] && ok "a valid password cannot sign in as another account (root)" \
    || bad "SIGNED IN AS ROOT, gave $c"

echo "=== throttle locks out repeated guessing ==="
for i in 4 5 6; do c=$(login "$RUN_USER" "wrong-$i"); done
[ "$c" = 429 ] && ok "locked out with 429 after repeated failures" || bad "no lockout, last status $c"
has "$(cat "$WORK/body")" "Too many failed attempts" "lockout says why"
c=$(login "$RUN_USER" "$CZ_TEST_PASSWORD")
[ "$c" = 429 ] && ok "even the correct password is refused during lockout" || bad "lockout bypassed, gave $c"

echo "=== the password is never logged ==="
if grep -qF "$CZ_TEST_PASSWORD" "$WORK/srv.log"; then
    bad "THE PASSWORD APPEARS IN THE SERVER LOG"
else
    ok "server log contains no plaintext password"
fi
grep -q "login ok for $RUN_USER" "$WORK/srv.log" && ok "successful logins are logged by user" \
    || bad "no audit trail for a successful login"
grep -q "login failed" "$WORK/srv.log" && ok "failed logins are logged" || bad "no audit trail for failures"

echo
if [ "$fail" = 0 ]; then echo "CZ-FILES-WEB OK"; else echo "CZ-FILES-WEB PROBLEM"; exit 1; fi
