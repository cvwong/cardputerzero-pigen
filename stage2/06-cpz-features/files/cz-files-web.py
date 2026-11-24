#!/usr/bin/env python3
"""cz-files-web — on-demand file transfer web UI for the CardputerZero.

Started by cz-files when the user opens the file manager and stopped when they
leave, so nothing listens on the LAN except during an active transfer session.

Authentication uses the device account of whoever started the server: the login
form takes that username and the account's own password, and a successful login
issues a random session cookie, so the password is sent once per session rather
than on every request.

  WARNING: this is plain HTTP. The password crosses the local network in
  cleartext, and on this image the account is a sudoer, so capturing it means
  root on the device. That is an accepted trade-off for a short-lived server on a
  trusted LAN; add TLS before exposing it anywhere else.

Other constraints that shaped this code:

1. Python 3.13 removed the `cgi` module, so multipart/form-data is parsed here.
   Uploads stream straight to disk rather than being buffered: the device has
   ~450MB of RAM and a phone may push an SD-card-sized video.
2. This serves file read, write, create and delete to the local network, so
   every request path is resolved and checked against the shared root. Neither
   .. traversal nor a symlink inside the tree may escape it.
3. Password verification cannot use the stdlib: there is no PAM binding, the
   `crypt` module was removed in 3.13, and /etc/shadow is unreadable by the
   unprivileged user this runs as. `sudo -S -k true` authenticates the invoking
   user through PAM and runs a no-op, reading the password from stdin -- which
   avoids forking a pty inside a threaded server.

Only files can be deleted, never directories: recursive deletion over a web form
is too easy to trigger by accident for the benefit it adds. Folders can be
created, just not removed from here.
"""

import html
import os
import posixpath
import pwd
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = 256 * 1024
# Directories the shared root is not allowed to be, so the whole filesystem
# cannot be exposed by accident.
FORBIDDEN_ROOTS = frozenset({"/", "/etc", "/bin", "/sbin", "/usr", "/boot",
                             "/dev", "/proc", "/sys", "/var", "/lib"})
SESSION_TTL = 8 * 3600          # absolute lifetime of a login
SESSION_IDLE = 60 * 60          # revoked after this long with no request
COOKIE = "czsid"
MAX_NAME = 60                   # longest folder name accepted
RUN_USER = pwd.getpwuid(os.getuid()).pw_name

CSS = """
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;padding:16px;font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
     background:#11151b;color:#e6e6e6}
h1{font-size:17px;margin:0 0 4px}
.sub{color:#9aa4b2;font-size:12px;margin-bottom:16px}
.card{background:#1a2029;border:1px solid #2a323d;border-radius:10px;padding:12px;margin-bottom:14px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:7px 8px;border-bottom:1px solid #232b35;vertical-align:middle}
th{color:#9aa4b2;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
tr:last-child td{border-bottom:0}
a{color:#7ab8ff;text-decoration:none}
a:hover{text-decoration:underline}
.dir{color:#ffd479}
.sz,.dt{color:#9aa4b2;font-size:12px;white-space:nowrap}
td.sz,td.dt{text-align:right}
th.sz,th.dt{text-align:right}
form.up,form.mk{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
form.mk{margin-top:10px;padding-top:10px;border-top:1px solid #232b35}
input[type=file],input[type=text],input[type=password]{flex:1 1 200px;min-width:0;
  color:#e6e6e6;background:#11151b;border:1px solid #2a323d;border-radius:7px;padding:8px;font:inherit}
input[type=text]:focus,input[type=password]:focus{outline:1px solid #2f6feb}
button{background:#2f6feb;border:0;color:#fff;padding:9px 14px;border-radius:7px;
       font:inherit;cursor:pointer}
button:hover{background:#3d7bf7}
button.sec{background:#30363d}
button.sec:hover{background:#3d444d}
button.danger{background:#0000;color:#f07178;border:1px solid #4a2b2e;padding:4px 9px}
button.danger:hover{background:#3a1f22}
.crumb{margin-bottom:10px;font-size:13px;word-break:break-all}
.msg{padding:9px 12px;border-radius:7px;margin-bottom:14px;font-size:13px}
.msg.ok{background:#12301f;border:1px solid #1f5c39;color:#7ee2a8}
.msg.err{background:#331a1c;border:1px solid #5c2429;color:#ff9aa2}
.msg.warn{background:#2e2617;border:1px solid #5c4a1f;color:#f0d78a}
.empty{color:#9aa4b2;padding:14px 8px;text-align:center}
.bar{height:6px;background:#232b35;border-radius:3px;overflow:hidden;margin-top:10px;display:none}
.bar>i{display:block;height:100%;width:0;background:#2f6feb}
.free{color:#9aa4b2;font-size:12px}
.top{display:flex;justify-content:space-between;align-items:flex-start;gap:10px}
.login label{display:block;margin-bottom:10px;color:#9aa4b2;font-size:12px}
.login input{width:100%;margin-top:4px}
.login button{width:100%;margin-top:4px}
form.logout{margin:0}
form.logout button{padding:4px 9px}
"""

LOGIN = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CardputerZero Files - Sign in</title>
<style>{css}</style>
</head><body>
<h1>CardputerZero Files</h1>
<div class="sub">sign in with the device account</div>
{messages}
<div class="card login">
  <form method="post" action="/login">
    <label>Username<input name="username" value="{user}" autocomplete="username"
      autocapitalize="none" spellcheck="false"></label>
    <label>Password<input type="password" name="password" autocomplete="current-password"></label>
    <button type="submit">Sign in</button>
  </form>
</div>
<div class="msg warn">The password is sent unencrypted over the local network.
Only use this on a network you trust.</div>
</body></html>
"""

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CardputerZero Files</title>
<style>{css}</style>
</head><body>
<div class="top">
  <div>
    <h1>CardputerZero Files</h1>
    <div class="sub">{host} &middot; signed in as <b>{user}</b> &middot; sharing
      <code>{root}</code> &middot; <span class="free">{free}</span></div>
  </div>
  <form class="logout" method="post" action="/logout">
    <button class="sec" type="submit">Sign out</button>
  </form>
</div>
{messages}
<div class="card">
  <div class="crumb">{crumbs}</div>
  <form class="up" method="post" action="{upload_action}" enctype="multipart/form-data" id="upform">
    <input type="file" name="files" id="files" multiple>
    <button type="submit">Upload</button>
    <span class="sz" id="upinfo"></span>
  </form>
  <form class="mk" method="post" action="{mkdir_action}">
    <input type="text" name="name" placeholder="New folder name" maxlength="{maxname}"
      autocapitalize="off" spellcheck="false">
    <button class="sec" type="submit">Create folder</button>
  </form>
  <div class="bar" id="bar"><i></i></div>
</div>
<div class="card">
{listing}
</div>
<script>
var f=document.getElementById('files'),i=document.getElementById('upinfo'),
    b=document.getElementById('bar'),bi=b.firstElementChild;
function human(n){{var u=['B','KB','MB','GB'];var k=0;while(n>=1024&&k<3){{n/=1024;k++;}}
  return n.toFixed(k?1:0)+' '+u[k];}}
f.addEventListener('change',function(){{
  var t=0;for(var j=0;j<f.files.length;j++)t+=f.files[j].size;
  i.textContent=f.files.length?(f.files.length+' file'+(f.files.length>1?'s':'')+', '+human(t)):'';
}});
document.getElementById('upform').addEventListener('submit',function(){{
  b.style.display='block';bi.style.width='60%';i.textContent='uploading\\u2026';
}});
function del(p,name){{
  if(!confirm('Delete '+name+' ?'))return;
  var form=document.createElement('form');form.method='post';
  form.action='{delete_action}';
  var inp=document.createElement('input');inp.type='hidden';inp.name='path';inp.value=p;
  form.appendChild(inp);document.body.appendChild(form);form.submit();
}}
</script>
</body></html>
"""


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%.0f %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


class SafePathError(Exception):
    pass


class Store:
    """Resolves and validates every path the web layer is asked to touch."""

    def __init__(self, root):
        # realpath first so a symlinked root (or symlinked parents) cannot be
        # used to make the containment check pass for a path outside it.
        self.root = os.path.realpath(os.path.abspath(root))
        if self.root in FORBIDDEN_ROOTS:
            raise SystemExit("refusing to serve %s" % self.root)
        if not os.path.isdir(self.root):
            raise SystemExit("root is not a directory: %s" % self.root)

    def resolve(self, rel):
        """Map a request-relative path to an absolute path inside root.

        Raises SafePathError on anything that would escape, including via a
        symlink that points outside the root.
        """
        rel = (rel or "").strip()
        rel = urllib.parse.unquote(rel)
        rel = rel.replace("\\", "/")
        # Drop any leading slash so the join is unambiguously relative.
        while rel.startswith("/"):
            rel = rel[1:]
        candidate = os.path.realpath(os.path.join(self.root, rel))
        if candidate != self.root and not candidate.startswith(self.root + os.sep):
            raise SafePathError("path escapes the shared root: %r" % rel)
        return candidate

    def relative(self, abspath):
        rel = os.path.relpath(abspath, self.root).replace(os.sep, "/")
        return "" if rel == "." else rel


class Sessions:
    """Random session ids issued only after a successful password check."""

    def __init__(self):
        self._lock = threading.Lock()
        self._sid = {}     # sid -> [username, created, last_seen]

    def create(self, username):
        sid = secrets.token_hex(16)
        now = time.time()
        with self._lock:
            self._sid[sid] = [username, now, now]
        return sid

    def user(self, sid):
        if not sid:
            return None
        now = time.time()
        with self._lock:
            rec = self._sid.get(sid)
            if not rec:
                return None
            created = rec[1]
            if now - created > SESSION_TTL or now - rec[2] > SESSION_IDLE:
                del self._sid[sid]
                return None
            rec[2] = now
            return rec[0]

    def revoke(self, sid):
        with self._lock:
            self._sid.pop(sid, None)


class Throttle:
    """Slows password guessing from one address.

    The login endpoint is a password oracle on the LAN, so failures cost time and
    repeated failures lock that address out for a while.
    """

    MAX_FAILS = 5
    LOCKOUT = 120
    DELAY = 1.5

    def __init__(self):
        self._lock = threading.Lock()
        self._state = {}   # ip -> [fails, locked_until]

    def blocked(self, ip):
        with self._lock:
            rec = self._state.get(ip)
            return bool(rec and rec[1] > time.time())

    def seconds_locked(self, ip):
        with self._lock:
            rec = self._state.get(ip)
            return int(max(0, rec[1] - time.time())) if rec else 0

    def fail(self, ip):
        with self._lock:
            rec = self._state.setdefault(ip, [0, 0.0])
            rec[0] += 1
            if rec[0] >= self.MAX_FAILS:
                rec[1] = time.time() + self.LOCKOUT
                rec[0] = 0

    def success(self, ip):
        with self._lock:
            self._state.pop(ip, None)


def check_password(password):
    """Verify the invoking user's password. Never logs or stores the value."""
    if not password:
        return False
    try:
        proc = subprocess.run(
            ["sudo", "-S", "-k", "-p", "", "true"],
            input=(password + "\n").encode("utf-8", "replace"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def parse_multipart(rfile, boundary, length, dest_dir):
    """Stream a multipart/form-data body to disk.

    Returns a list of (field_name, filename_or_None, saved_path_or_value, size).
    File parts are written to a temp file in dest_dir as they arrive; the body is
    never held in memory whole, so upload size is bounded by disk, not RAM.
    """
    delim = b"--" + boundary
    keep = len(delim) + 8
    buf = bytearray()
    remaining = length
    results = []

    def refill(want):
        nonlocal buf, remaining
        while len(buf) < want and remaining > 0:
            # Bound the read by what is actually wanted. A negative or zero count
            # would mean "read until EOF", which blocks forever on keep-alive.
            n = min(CHUNK, remaining, want - len(buf))
            if n <= 0:
                break
            chunk = rfile.read(n)
            if not chunk:
                remaining = 0
                break
            remaining -= len(chunk)
            buf += chunk

    def consume(n):
        nonlocal buf
        del buf[:n]

    # Skip the preamble up to and including the first boundary line. Top up past
    # the retention window: refill(keep) alone stops reading once the buffer is
    # exactly `keep` bytes, which would spin forever on a multi-chunk body.
    refill(keep + CHUNK)
    idx = buf.find(delim)
    if idx < 0:
        return results
    consume(idx + len(delim))
    refill(2)
    if bytes(buf[:2]) == b"--":
        return results
    consume(2)  # the CRLF after the boundary

    while True:
        refill(keep + CHUNK)
        hend = buf.find(b"\r\n\r\n")
        while hend < 0 and remaining > 0:
            refill(len(buf) + CHUNK)
            hend = buf.find(b"\r\n\r\n")
        if hend < 0:
            break
        header_blob = bytes(buf[:hend])
        consume(hend + 4)

        name, filename = None, None
        for line in header_blob.split(b"\r\n"):
            if not line.lower().startswith(b"content-disposition:"):
                continue
            text = line.decode("utf-8", "replace")
            for piece in text.split(";"):
                piece = piece.strip()
                if piece.startswith("name="):
                    name = piece[5:].strip('"')
                elif piece.startswith("filename="):
                    filename = piece[9:].strip('"')

        if filename:
            # Never trust a client-supplied filename: strip any directory part
            # and reject empty or dot-only names.
            base = os.path.basename(filename.replace("\\", "/"))
            if base in ("", ".", ".."):
                base = "upload"
            fd, tmp = tempfile.mkstemp(prefix=".czup-", dir=dest_dir)
            os.close(fd)
            written = 0
            try:
                with open(tmp, "wb") as out:
                    while True:
                        refill(keep + CHUNK)
                        pos = buf.find(delim)
                        if pos >= 0:
                            # Data ends 2 bytes before the delimiter (its CRLF).
                            out.write(bytes(buf[:max(0, pos - 2)]))
                            written += max(0, pos - 2)
                            consume(pos + len(delim))
                            break
                        if len(buf) > keep:
                            safe = len(buf) - keep
                            out.write(bytes(buf[:safe]))
                            written += safe
                            consume(safe)
                        if remaining <= 0:
                            break
                results.append((name, base, tmp, written))
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        else:
            value = bytearray()
            while True:
                refill(keep + CHUNK)
                pos = buf.find(delim)
                if pos >= 0:
                    value += buf[:max(0, pos - 2)]
                    consume(pos + len(delim))
                    break
                if len(buf) > keep:
                    safe = len(buf) - keep
                    value += buf[:safe]
                    consume(safe)
                if remaining <= 0:
                    break
            results.append((name, None, bytes(value).decode("utf-8", "replace"), len(value)))

        refill(2)
        if bytes(buf[:2]) == b"--":
            break
        consume(2)

    return results


class Handler(BaseHTTPRequestHandler):
    server_version = "cz-files-web/2.0"
    protocol_version = "HTTP/1.1"

    # ---- helpers -------------------------------------------------------
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def cookie(self, name):
        raw = self.headers.get("Cookie")
        if not raw:
            return ""
        try:
            jar = SimpleCookie()
            jar.load(raw)
            morsel = jar.get(name)
            return morsel.value if morsel else ""
        except Exception:
            return ""

    def current_user(self):
        return self.sessions.user(self.cookie(COOKIE))

    def _send_html(self, body, code=200, cookie=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(data)

    def _login_page(self, message=None, error=None, code=200):
        msgs = ""
        if error:
            msgs = '<div class="msg err">%s</div>' % html.escape(error)
        if message:
            msgs += '<div class="msg ok">%s</div>' % html.escape(message)
        self._send_html(LOGIN.format(css=CSS, user=html.escape(RUN_USER),
                                     messages=msgs), code)

    def _error_page(self, title, detail, code=400):
        self._send_html(PAGE.format(
            css=CSS, host=html.escape(self.cfg.host_label), user=html.escape(RUN_USER),
            root=html.escape(self.store.root), free="",
            messages='<div class="msg err"><b>%s</b> %s</div>' % (
                html.escape(title), html.escape(detail)),
            crumbs="", upload_action="#", mkdir_action="#", delete_action="#",
            maxname=MAX_NAME,
            listing='<div class="empty">nothing to show</div>'), code)

    def _redirect(self, rel, message=None, error=None, cookie=None, drop_cookie=False):
        target = "/?path=%s" % urllib.parse.quote(rel or "")
        if message:
            target += "&msg=" + urllib.parse.quote(message)
        if error:
            target += "&err=" + urllib.parse.quote(error)
        self.send_response(303)
        self.send_header("Location", target)
        if drop_cookie:
            self.send_header("Set-Cookie", "%s=; Path=/; Max-Age=0" % COOKIE)
        elif cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _read_form(self, length):
        raw = self.rfile.read(length) if length and length > 0 else b""
        return dict(urllib.parse.parse_qsl(raw.decode("utf-8", "replace")))

    # ---- routing -------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        self.query = dict(urllib.parse.parse_qsl(parsed.query))
        if not self.current_user():
            if parsed.path in ("/", "/index.html", "/login"):
                return self._login_page()
            return self._login_page(error="Sign in first.", code=403)
        if parsed.path in ("/", "/index.html"):
            return self.render_index()
        if parsed.path == "/download":
            return self.render_download()
        return self._error_page("Not found", parsed.path, 404)

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        self.query = dict(urllib.parse.parse_qsl(parsed.query))
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0

        if parsed.path == "/login":
            return self.render_login(length)
        if not self.current_user():
            return self._login_page(error="Session expired, sign in again.", code=403)
        # /logout carries no form fields, so it must be handled before the
        # empty-body guard below rejects it.
        if parsed.path == "/logout":
            self.sessions.revoke(self.cookie(COOKIE))
            return self._redirect("", drop_cookie=True)
        if length <= 0:
            return self._error_page("Bad request", "Empty request body.", 400)

        if parsed.path == "/mkdir":
            return self.render_mkdir(length)
        if parsed.path == "/delete":
            return self.render_delete(length)
        if parsed.path == "/upload":
            ctype = self.headers.get("Content-Type", "")
            # Only /upload is multipart. The other forms post urlencoded, so this
            # content-type requirement belongs here rather than in do_POST.
            if "multipart/form-data" not in ctype or "boundary=" not in ctype:
                return self._error_page("Bad request", "Expected multipart/form-data.", 400)
            boundary = ctype.split("boundary=", 1)[1].strip().strip('"').encode()
            return self.render_upload(length, boundary)
        return self._error_page("Not found", parsed.path, 404)

    # ---- pages ---------------------------------------------------------
    def render_login(self, length):
        ip = self.address_string()
        if self.throttle.blocked(ip):
            return self._login_page(
                error="Too many failed attempts. Try again in %ds."
                      % self.throttle.seconds_locked(ip), code=429)
        form = self._read_form(length)
        username = (form.get("username") or "").strip()
        password = form.get("password") or ""
        # Check the username too, so this endpoint cannot be used to test
        # passwords for accounts other than the one running the server. The
        # error message is identical either way to avoid leaking which part was
        # wrong.
        if username != RUN_USER or not check_password(password):
            self.throttle.fail(ip)
            time.sleep(self.throttle.DELAY)
            sys.stderr.write("login failed for %r from %s\n" % (username, ip))
            return self._login_page(error="Wrong username or password.", code=401)
        self.throttle.success(ip)
        sid = self.sessions.create(username)
        sys.stderr.write("login ok for %s from %s\n" % (username, ip))
        return self._redirect("", cookie="%s=%s; Path=/; HttpOnly; SameSite=Strict"
                              % (COOKIE, sid))

    def render_index(self):
        rel = self.query.get("path", "")
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if not os.path.isdir(target):
            return self._error_page("Not a directory", rel, 404)
        rel_norm = self.store.relative(target)

        try:
            entries = sorted(os.scandir(target),
                             key=lambda e: (not e.is_dir(), e.name.lower()))
        except OSError as e:
            return self._error_page("Cannot read directory", str(e), 500)

        rows = []
        count = 0
        if rel_norm:
            parent = posixpath.dirname(rel_norm)
            rows.append('<tr><td><a class="dir" href="/?path=%s">..</a></td>'
                        '<td class="sz"></td><td class="dt"></td><td></td></tr>'
                        % urllib.parse.quote(parent))
        for e in entries:
            count += 1
            name = e.name
            q = urllib.parse.quote(posixpath.join(rel_norm, name) if rel_norm else name)
            if e.is_dir():
                rows.append('<tr><td><a class="dir" href="/?path=%s">%s/</a></td>'
                            '<td class="sz"></td><td class="dt"></td><td></td></tr>'
                            % (q, html.escape(name)))
                continue
            try:
                st = e.stat()
                size, mtime = human(st.st_size), self._fmt_time(st.st_mtime)
            except OSError:
                size, mtime = "?", "?"
            rows.append(
                '<tr><td><a href="/download?path=%s">%s</a></td>'
                '<td class="sz">%s</td><td class="dt">%s</td>'
                '<td><button class="danger" onclick="del(\'%s\',\'%s\')">del</button></td></tr>'
                % (q, html.escape(name), size, mtime,
                   q.replace("'", "%27"), html.escape(name).replace("'", "\\'")))

        # A subdirectory always contributes a ".." row, so `rows` being
        # non-empty does not mean the folder has contents; count tracks entries.
        listing = ""
        if rows:
            listing = ("<table><tr><th>Name</th><th class='sz'>Size</th>"
                       "<th class='dt'>Modified</th><th></th></tr>%s</table>"
                       % "".join(rows))
        if count == 0:
            listing += '<div class="empty">empty folder</div>'

        crumbs = ['<a href="/">root</a>']
        acc = ""
        for part in (rel_norm.split("/") if rel_norm else []):
            acc = posixpath.join(acc, part) if acc else part
            crumbs.append('<a href="/?path=%s">%s</a>'
                          % (urllib.parse.quote(acc), html.escape(part)))

        messages = []
        if self.query.get("msg"):
            messages.append('<div class="msg ok">%s</div>' % html.escape(self.query["msg"]))
        if self.query.get("err"):
            messages.append('<div class="msg err">%s</div>' % html.escape(self.query["err"]))

        try:
            usage = shutil.disk_usage(self.store.root)
            free = "%s free of %s" % (human(usage.free), human(usage.total))
        except OSError:
            free = ""

        q_rel = urllib.parse.quote(rel_norm)
        self._send_html(PAGE.format(
            css=CSS, host=html.escape(self.cfg.host_label), user=html.escape(RUN_USER),
            root=html.escape(self.store.root), free=free, messages="".join(messages),
            crumbs=" / ".join(crumbs),
            upload_action="/upload?path=%s" % q_rel,
            mkdir_action="/mkdir?path=%s" % q_rel,
            delete_action="/delete", maxname=MAX_NAME, listing=listing))

    @staticmethod
    def _fmt_time(ts):
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))

    def render_download(self):
        rel = self.query.get("path", "")
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if not os.path.isfile(target):
            return self._error_page("Not a file", rel, 404)
        try:
            size = os.path.getsize(target)
            f = open(target, "rb")
        except OSError as e:
            return self._error_page("Cannot open", str(e), 500)
        with f:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            name = os.path.basename(target)
            self.send_header("Content-Disposition",
                             "attachment; filename=\"%s\"; filename*=UTF-8''%s"
                             % (name.replace('"', ""), urllib.parse.quote(name)))
            self.end_headers()
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return

    def render_mkdir(self, length):
        form = self._read_form(length)
        rel = self.query.get("path", "") or form.get("path", "")
        name = (form.get("name") or "").strip()
        # Reject separators outright: a folder name has no business containing a
        # path, and resolve() alone would happily create nested directories.
        if (not name or name in (".", "..") or "/" in name or "\\" in name
                or "\0" in name or len(name) > MAX_NAME):
            return self._redirect(rel, error="invalid folder name")
        try:
            self.store.resolve(rel)
            target = self.store.resolve(posixpath.join(rel, name) if rel else name)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if os.path.exists(target):
            return self._redirect(rel, error="already exists: %s" % name)
        try:
            os.mkdir(target, 0o755)
        except OSError as e:
            return self._redirect(rel, error="could not create folder: %s" % e)
        new_rel = posixpath.join(rel, name) if rel else name
        return self._redirect(new_rel, message="created folder %s" % name)

    def render_upload(self, length, boundary):
        rel = self.query.get("path", "")
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if not os.path.isdir(target):
            return self._error_page("Not a directory", rel, 404)

        saved, failed = [], []
        try:
            parts = parse_multipart(self.rfile, boundary, length, target)
        except Exception as e:
            return self._error_page("Upload failed", str(e), 500)

        for _name, filename, payload, _size in parts:
            if not filename:
                continue
            dest = self._unique(target, filename)
            try:
                shutil.move(payload, dest)
                # mkstemp creates 0600; an uploaded file should be readable like
                # anything else the user drops in this directory.
                os.chmod(dest, 0o644)
                saved.append(os.path.basename(dest))
            except OSError as e:
                failed.append("%s (%s)" % (filename, e))
                try:
                    os.unlink(payload)
                except OSError:
                    pass
        # Sweep temp files left behind by an interrupted transfer.
        for junk in os.listdir(target):
            if junk.startswith(".czup-"):
                try:
                    os.unlink(os.path.join(target, junk))
                except OSError:
                    pass

        if failed and not saved:
            return self._redirect(rel, error="upload failed: " + ", ".join(failed))
        note = "uploaded %d file%s" % (len(saved), "" if len(saved) == 1 else "s")
        if failed:
            note += ", %d failed" % len(failed)
        return self._redirect(rel, message=note)

    @staticmethod
    def _unique(directory, filename):
        """Avoid clobbering an existing file by appending -1, -2, ..."""
        base, ext = os.path.splitext(filename)
        candidate = os.path.join(directory, filename)
        n = 1
        while os.path.exists(candidate):
            candidate = os.path.join(directory, "%s-%d%s" % (base, n, ext))
            n += 1
        return candidate

    def render_delete(self, length):
        # The delete form posts application/x-www-form-urlencoded, not multipart.
        form = self._read_form(length)
        rel = form.get("path", "")
        parent = posixpath.dirname(rel)
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if target == self.store.root:
            return self._redirect(parent, error="cannot delete the shared root")
        if os.path.isdir(target):
            return self._redirect(parent,
                                  error="folders cannot be deleted from the web UI")
        if not os.path.isfile(target):
            return self._redirect(parent, error="no such file")
        try:
            os.unlink(target)
        except OSError as e:
            return self._redirect(parent, error="delete failed: %s" % e)
        return self._redirect(parent, message="deleted %s" % os.path.basename(target))


class Config:
    def __init__(self, root, host, port):
        self.root = root
        self.host = host
        self.port = port
        self.host_label = "%s:%d" % (host if host not in ("0.0.0.0", "") else "lan", port)


def lan_ip():
    """Best-effort LAN address for display. Never raises."""
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"
    finally:
        if s is not None:
            s.close()


def main(argv):
    import argparse
    p = argparse.ArgumentParser(
        description="CardputerZero on-demand file transfer web UI")
    p.add_argument("--root", required=True, help="directory to share")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    args = p.parse_args(argv[1:])

    cfg = Config(args.root, args.host, args.port)
    store = Store(cfg.root)
    # Bind through a tuple: `cfg = cfg` inside a class body would resolve against
    # the class namespace, not this function, and raise NameError.
    bound = (cfg, store, Sessions(), Throttle())

    class Bound(Handler):
        cfg, store, sessions, throttle = bound

    httpd = ThreadingHTTPServer((cfg.host, cfg.port), Bound)
    httpd.daemon_threads = True
    real_port = httpd.server_address[1]
    sys.stderr.write("cz-files-web: root=%s url=http://%s:%d/ user=%s\n"
                     % (store.root, lan_ip(), real_port, RUN_USER))
    sys.stderr.flush()
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
