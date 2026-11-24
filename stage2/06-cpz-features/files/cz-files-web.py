#!/usr/bin/env python3
"""cz-files-web — on-demand file transfer web UI for the CardputerZero.

Started by cz-files when the user opens the file manager and stopped when they
leave, so nothing listens on the LAN except during an active transfer session.

Three constraints shaped this code:

1. Python 3.13 removed the `cgi` module, so multipart/form-data is parsed here.
   Uploads stream straight to disk rather than being buffered: the device has
   ~450MB of RAM and a user may push an SD-card-sized file from a phone.
2. This serves file read, write and delete to the local network, so every
   request path is resolved and checked against the shared root. A request for
   ../../etc/passwd must not escape, and must not escape via a symlink either.
3. Being on the LAN is not sufficient to use it. A random token, displayed on
   the device LCD, is required on every request.

Only files can be deleted, never directories -- recursive deletion over a web
form is too easy to trigger by accident for the benefit it adds.
"""

import html
import os
import posixpath
import shutil
import socket
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = 256 * 1024
# Directory the shared root is not allowed to be, to avoid serving the whole
# filesystem by accident.
FORBIDDEN_ROOTS = frozenset({"/", "/etc", "/bin", "/sbin", "/usr", "/boot", "/dev", "/proc", "/sys"})

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
form.up{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
input[type=file]{flex:1 1 220px;min-width:0;color:#c9d1d9}
button{background:#2f6feb;border:0;color:#fff;padding:9px 14px;border-radius:7px;
       font:inherit;cursor:pointer}
button:hover{background:#3d7bf7}
button.sec{background:#30363d}
button.sec:hover{background:#3d444d}
button.danger{background:#0000;color:#f07178;border:1px solid #4a2b2e;padding:4px 9px}
button.danger:hover{background:#3a1f22}
.crumb a{color:#7ab8ff}
.crumb{margin-bottom:10px;font-size:13px;word-break:break-all}
.msg{padding:9px 12px;border-radius:7px;margin-bottom:14px;font-size:13px}
.msg.ok{background:#12301f;border:1px solid #1f5c39;color:#7ee2a8}
.msg.err{background:#331a1c;border:1px solid #5c2429;color:#ff9aa2}
.empty{color:#9aa4b2;padding:14px 8px;text-align:center}
.bar{height:6px;background:#232b35;border-radius:3px;overflow:hidden;margin-top:10px;display:none}
.bar>i{display:block;height:100%;width:0;background:#2f6feb}
.free{color:#9aa4b2;font-size:12px}
"""

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CardputerZero Files</title>
<style>{css}</style>
</head><body>
<h1>CardputerZero Files</h1>
<div class="sub">{host} &middot; sharing <code>{root}</code> &middot; <span class="free">{free}</span></div>
{messages}
<div class="card">
  <div class="crumb">{crumbs}</div>
  <form class="up" method="post" action="{upload_action}" enctype="multipart/form-data" id="upform">
    <input type="file" name="files" id="files" multiple>
    <button type="submit">Upload</button>
    <span class="sz" id="upinfo"></span>
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
        # Drop any drive letter or leading slash so it is unambiguously relative.
        while rel.startswith("/"):
            rel = rel[1:]
        candidate = os.path.realpath(os.path.join(self.root, rel))
        if candidate != self.root and not candidate.startswith(self.root + os.sep):
            raise SafePathError("path escapes the shared root: %r" % rel)
        return candidate

    def relative(self, abspath):
        return os.path.relpath(abspath, self.root).replace(os.sep, "/")


def parse_multipart(rfile, boundary, length, dest_dir):
    """Stream a multipart/form-data body to disk.

    Returns a list of (field_name, filename_or_None, saved_path_or_value).
    File parts are written to a temp file in dest_dir as they arrive; the body
    is never held in memory whole, so upload size is bounded by disk, not RAM.
    """
    delim = b"--" + boundary
    keep = len(delim) + 8
    buf = bytearray()
    remaining = length
    results = []

    def refill(want):
        nonlocal buf, remaining
        while len(buf) < want and remaining > 0:
            # Bound the read by what is actually wanted. Passing a negative or
            # zero count to rfile.read() would mean "read until EOF", which
            # blocks forever on a keep-alive connection.
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
        # Headers for this part.
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
            low = line.lower()
            if not low.startswith(b"content-disposition:"):
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
            # Plain form field: small, collect in memory.
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
    server_version = "cz-files-web/1.0"
    protocol_version = "HTTP/1.1"

    # ---- helpers -------------------------------------------------------
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _authorized(self):
        return self.cfg.token == "" or self.query.get("token") == self.cfg.token

    def _send_html(self, body, code=200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _error_page(self, title, detail, code=400):
        self._send_html(PAGE.format(
            css=CSS, host=html.escape(self.cfg.host_label), root=html.escape(self.store.root),
            free="", messages='<div class="msg err"><b>%s</b> %s</div>' % (
                html.escape(title), html.escape(detail)),
            crumbs="", upload_action="#", delete_action="#",
            listing='<div class="empty">nothing to show</div>'), code)

    def _redirect(self, rel, message=None, error=None):
        target = "/?path=%s&token=%s" % (
            urllib.parse.quote(rel), urllib.parse.quote(self.cfg.token))
        if message:
            target += "&msg=" + urllib.parse.quote(message)
        if error:
            target += "&err=" + urllib.parse.quote(error)
        self.send_response(303)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- routing -------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        self.query = dict(urllib.parse.parse_qsl(parsed.query))
        if not self._authorized():
            return self._error_page("Not authorized", "Bad or missing token.", 403)
        if parsed.path in ("/", "/index.html"):
            return self.render_index()
        if parsed.path == "/download":
            return self.render_download()
        return self._error_page("Not found", parsed.path, 404)

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        self.query = dict(urllib.parse.parse_qsl(parsed.query))
        if not self._authorized():
            return self._error_page("Not authorized", "Bad or missing token.", 403)
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return self._error_page("Bad request", "Empty request body.", 400)
        # Only /upload is multipart. The delete form posts urlencoded, so the
        # content-type requirement must live in the upload branch, not here.
        if parsed.path == "/upload":
            ctype = self.headers.get("Content-Type", "")
            if "multipart/form-data" not in ctype or "boundary=" not in ctype:
                return self._error_page("Bad request", "Expected multipart/form-data.", 400)
            boundary = ctype.split("boundary=", 1)[1].strip().strip('"').encode()
            return self.render_upload(length, boundary)
        if parsed.path == "/delete":
            return self.render_delete(length)
        return self._error_page("Not found", parsed.path, 404)

    # ---- pages ---------------------------------------------------------
    def render_index(self):
        rel = self.query.get("path", "")
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if not os.path.isdir(target):
            return self._error_page("Not a directory", rel, 404)

        rel_norm = self.store.relative(target)
        rel_norm = "" if rel_norm == "." else rel_norm

        try:
            entries = sorted(os.scandir(target), key=lambda e: (not e.is_dir(), e.name.lower()))
        except OSError as e:
            return self._error_page("Cannot read directory", str(e), 500)

        rows = []
        count = 0
        if rel_norm:
            parent = posixpath.dirname(rel_norm)
            rows.append(
                '<tr><td><a class="dir" href="/?path=%s&token=%s">..</a></td>'
                '<td class="sz"></td><td class="dt"></td><td></td></tr>'
                % (urllib.parse.quote(parent), urllib.parse.quote(self.cfg.token)))
        for e in entries:
            name = e.name
            count += 1
            q = urllib.parse.quote(posixpath.join(rel_norm, name) if rel_norm else name)
            tok = urllib.parse.quote(self.cfg.token)
            if e.is_dir():
                rows.append(
                    '<tr><td><a class="dir" href="/?path=%s&token=%s">%s/</a></td>'
                    '<td class="sz"></td><td class="dt"></td><td></td></tr>'
                    % (q, tok, html.escape(name)))
                continue
            try:
                st = e.stat()
                size, mtime = human(st.st_size), self._fmt_time(st.st_mtime)
            except OSError:
                size, mtime = "?", "?"
            rows.append(
                '<tr><td><a href="/download?path=%s&token=%s">%s</a></td>'
                '<td class="sz">%s</td><td class="dt">%s</td>'
                '<td><button class="danger" onclick="del(\'%s\',\'%s\')">del</button></td></tr>'
                % (q, tok, html.escape(name), size, mtime,
                   q.replace("'", "%27"), html.escape(name).replace("'", "\\'")))

        # A subdirectory always contributes a ".." row, so `rows` being
        # non-empty does not mean the folder has contents; count tracks entries.
        listing = ""
        if rows:
            listing = ("<table><tr><th>Name</th><th class='sz'>Size</th>"
                       "<th class='dt'>Modified</th><th></th></tr>%s</table>" % "".join(rows))
        if count == 0:
            listing += '<div class="empty">empty folder</div>'

        crumbs = ['<a href="/?token=%s">root</a>' % urllib.parse.quote(self.cfg.token)]
        if rel_norm:
            acc = ""
            for part in rel_norm.split("/"):
                acc = posixpath.join(acc, part) if acc else part
                crumbs.append('<a href="/?path=%s&token=%s">%s</a>' % (
                    urllib.parse.quote(acc), urllib.parse.quote(self.cfg.token),
                    html.escape(part)))

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

        upload_action = "/upload?path=%s&token=%s" % (
            urllib.parse.quote(rel_norm), urllib.parse.quote(self.cfg.token))
        delete_action = "/delete?token=%s" % urllib.parse.quote(self.cfg.token)

        self._send_html(PAGE.format(
            css=CSS, host=html.escape(self.cfg.host_label), root=html.escape(self.store.root),
            free=free, messages="".join(messages), crumbs=" / ".join(crumbs),
            upload_action=upload_action, delete_action=delete_action, listing=listing))

    @staticmethod
    def _fmt_time(ts):
        import time
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

        for name, filename, payload, _size in parts:
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
        # Sweep any temp files left behind by an interrupted transfer.
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
        raw = self.rfile.read(length) if length else b""
        fields = dict(urllib.parse.parse_qsl(raw.decode("utf-8", "replace")))
        rel = fields.get("path", "")
        parent = posixpath.dirname(rel)
        try:
            target = self.store.resolve(rel)
        except SafePathError as e:
            return self._error_page("Rejected", str(e), 403)
        if target == self.store.root:
            return self._redirect(parent, error="cannot delete the shared root")
        if os.path.isdir(target):
            return self._redirect(parent, error="directories cannot be deleted from the web UI")
        if not os.path.isfile(target):
            return self._redirect(parent, error="no such file")
        try:
            os.unlink(target)
        except OSError as e:
            return self._redirect(parent, error="delete failed: %s" % e)
        return self._redirect(parent, message="deleted %s" % os.path.basename(target))


class Config:
    def __init__(self, root, host, port, token):
        self.root = root
        self.host = host
        self.port = port
        self.token = token
        self.host_label = "%s:%d" % (host if host not in ("0.0.0.0", "") else "lan", port)


def main(argv):
    import argparse
    p = argparse.ArgumentParser(description="CardputerZero on-demand file transfer web UI")
    p.add_argument("--root", required=True, help="directory to share")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--token", default="", help="shared secret required on every request")
    args = p.parse_args(argv[1:])

    cfg = Config(args.root, args.host, args.port, args.token)
    store = Store(cfg.root)

    # Bind via distinct locals: `cfg = cfg` inside a class body resolves against
    # the class namespace, not the enclosing function, and raises NameError.
    bound_cfg, bound_store = cfg, store

    class Bound(Handler):
        cfg = bound_cfg
        store = bound_store

    httpd = ThreadingHTTPServer((cfg.host, cfg.port), Bound)
    httpd.daemon_threads = True
    real_port = httpd.server_address[1]
    ip = lan_ip()
    url = "http://%s:%d/" % (ip, real_port)
    if cfg.token:
        url += "?token=" + cfg.token
    sys.stderr.write("cz-files-web: root=%s url=%s\n" % (store.root, url))
    sys.stderr.flush()
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


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


if __name__ == "__main__":
    sys.exit(main(sys.argv))
