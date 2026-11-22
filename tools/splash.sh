#!/bin/bash
# splash.sh to-png | to-raw — convert between the editable PNG and the blitted RGB565
set -e
cd "$(dirname "$0")/../stage2/06-cpz-features/files"
case "${1:-}" in
  to-png)
    python3 - <<'PY'
d = open('cz-splash.rgb565','rb').read()
assert len(d) == 320*170*2, len(d)
o = bytearray()
for i in range(0, len(d), 2):
    v = d[i] | (d[i+1] << 8)
    r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    o += bytes(((r<<3)|(r>>2), (g<<2)|(g>>4), (b<<3)|(b>>2)))
open('/tmp/splash.rgb','wb').write(o)
PY
    convert -size 320x170 -depth 8 rgb:/tmp/splash.rgb cz-splash.png
    echo "wrote cz-splash.png" ;;
  to-raw)
    convert cz-splash.png -resize 320x170! -depth 8 rgb:/tmp/splash.rgb
    python3 - <<'PY'
import struct
d = open('/tmp/splash.rgb','rb').read()
assert len(d) == 320*170*3, len(d)
o = bytearray()
for i in range(0, len(d), 3):
    r, g, b = d[i], d[i+1], d[i+2]
    o += struct.pack('<H', ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
open('cz-splash.rgb565','wb').write(o)
PY
    echo "wrote cz-splash.rgb565" ;;
  *) echo "usage: splash.sh to-png|to-raw"; exit 1 ;;
esac
