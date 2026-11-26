#!/bin/bash
# End-to-end test for cz-record: exercises record/list/play/delete/check/gain
# against mocked arecord/aplay/amixer so it runs on any dev machine, without an
# ES8389 card. The mocked mixer control list mirrors what a real CardputerZero
# reports, so a rename there fails here. Also verifies that a silent capture is
# reported instead of being saved as a "successful" recording.
# Run: bash tests/cz-record-e2e.sh
set -u
# Pin stdin off any terminal. cz-record branches on `[ -t 0 ]`: with a tty it
# waits for a keypress to stop a capture, without one it simply waits for the
# capture to finish. This suite drives the non-interactive path and feeds keys
# only where it means to (menu, picker, delete confirm), so the outcome must not
# depend on whether the harness happens to allocate a pty. Individual commands
# still override this with an explicit pipe.
exec < /dev/null
# Box drawing is multibyte; without a UTF-8 locale awk counts bytes, not columns.
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/../stage2/06-cpz-features/files/cz-record"
# cz-record sources the shared theme lib from /usr/local/lib, absent on a dev box.
export CZ_THEME="$HERE/../stage2/06-cpz-features/files/cz-theme.sh"
[ -r "$CZ_THEME" ] || { echo "missing $CZ_THEME"; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MOCK="$WORK/bin"
mkdir -p "$MOCK"

# Fake ALSA card list, matching /proc/asound/cards on the device.
printf ' 1 [ES8389Audio    ]: cardputerzero-a - ES8389-Audio\n' > "$WORK/cards"

export CZ_TEST_CALLS="$WORK/calls.log"
export CZ_RECORD_CARDS="$WORK/cards"
export CZ_TEST_TONE=1
export CZ_TEST_DUR=1

# Mock arecord writes a real 48kHz mono S16 WAV (440Hz tone, or silence when
# CZ_TEST_TONE=0).
cat > "$MOCK/arecord" <<'EOF'
#!/bin/bash
# Ignore the stop signal so the WAV is always written in full: cz-record sends
# SIGINT to end a capture, and a truncated file would make the test racy.
trap '' INT TERM
printf '%s\n' "arecord $*" >> "$CZ_TEST_CALLS"
out="${@: -1}"; dur="${CZ_TEST_DUR:-1}"
while [ $# -gt 0 ]; do [ "$1" = -d ] && dur="$2"; shift; done
[ -n "${CZ_TEST_SLEEP:-}" ] && sleep "$CZ_TEST_SLEEP"
python3 -c '
import math, os, struct, sys, wave
out, dur, tone = sys.argv[1], float(sys.argv[2]), os.environ.get("CZ_TEST_TONE", "1") == "1"
fr = 48000
w = wave.open(out, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(fr)
buf = bytearray()
for i in range(max(1, int(fr * dur))):
    buf += struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / fr)) if tone else 0)
w.writeframes(bytes(buf)); w.close()
' "$out" "$dur"
EOF
cat > "$MOCK/aplay" <<'EOF'
#!/bin/bash
printf '%s\n' "aplay $*" >> "$CZ_TEST_CALLS"
EOF
# Control names are the short ALSA simple-control names as reported by the real
# device: amixer strips the "Capture Volume" / "Switch" suffixes.
cat > "$MOCK/amixer" <<'EOF'
#!/bin/bash
printf '%s\n' "amixer $*" >> "$CZ_TEST_CALLS"
# $* has no shell quoting, so "sget ADCL PGA" arrives as bare words.
case " $* " in
  *" scontrols "*)
    printf "Simple mixer control '%s',0\n" Speaker 'Mic Jack' 'ADC MUX' \
      'ADC OSR' 'ADCL' 'ADCL PGA' 'ADCR' 'ADCR PGA' 'ALC' DACL DACR \
      'PGAL Select' 'PGAR Select' ;;
  *" sget ADC MUX "*)      echo "  Item0: 'AMIC'" ;;
  *" sget Mic Jack "*)     echo "  Mono: Playback [on]" ;;
  *" sget ADCL PGA "*)     echo "  Mono: 8 [57%] [24.00dB]" ;;
  *" sget PGAL Select "*)  echo "  Item0: 'DifferentialL'" ;;
  *" sget PGAR Select "*)  echo "  Item0: 'DifferentialR'" ;;
  *" sget "*)              echo "  Mono: Capture 191 [75%] [0.00dB]" ;;
esac
exit 0
EOF
chmod +x "$MOCK/arecord" "$MOCK/aplay" "$MOCK/amixer"
# Stub clear so the width check measures content, not screen-clearing escapes
# (tests/cz-menu-theme-layout.sh does the same).
printf '#!/bin/bash\nexit 0\n' > "$MOCK/clear"
chmod +x "$MOCK/clear"
export PATH="$MOCK:$PATH"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
# Screen output is themed, so literals like "peak -8.7dB" are split by ANSI
# escapes. Every content assertion matches against the stripped form.
# pause() prints "press any key" with no trailing newline; on a real console the
# next screen's clear wipes it, but in captured output it runs into the following
# box top, so split it back onto its own line.
strip() { printf '%s' "$1" \
    | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/press any key/&\n/' \
    | tr -d '\r'; }
has() { local h; h=$(strip "$1")
        case "$h" in *"$2"*) ok "$3" ;; *) bad "$3 — missing [$2] in: $h" ;; esac; }
hasnt(){ local h; h=$(strip "$1")
        case "$h" in *"$2"*) bad "$3 — unexpected [$2] in: $h" ;; *) ok "$3" ;; esac; }
# Match a whole line by regex, so assertions do not depend on exact padding.
line_has() {
    if strip "$1" | grep -qE "$2"; then ok "$3"
    else bad "$3 — no line matching /$2/"; fi
}
# The LCD console is 53 columns wide (see tests/cz-menu-theme-layout.sh). Count
# with bash's ${#l}, not awk: mawk's length() reports bytes, and the box-drawing
# characters are 3 bytes each, so a 53-column row measures 159.
wide() {
    local body l w over=0
    body=$(strip "$2")
    while IFS= read -r l; do
        w=${#l}
        [ "$w" -gt 53 ] && { bad "$1 line is $w columns (want <=53): [$l]"; over=1; }
    done <<< "$body"
    [ "$over" = 0 ] && ok "$1 fits 53 columns"
    return $over
}
# boxed <label> <output> — every themed screen must be a well-formed box:
# a 53-wide ╔═╗ top, a ╚═╝ bottom, and each ║ row exactly 53 columns and closed.
boxed() {
    local body l w b=0
    body=$(strip "$2")
    printf '%s\n' "$body" | grep -q '^╔═\{51\}╗$' || { bad "$1 has no 53-wide box top"; b=1; }
    printf '%s\n' "$body" | grep -q '^╚═\{51\}╝$' || { bad "$1 has no 53-wide box bottom"; b=1; }
    while IFS= read -r l; do
        case "$l" in
            '║'*) w=${#l}
                  [ "$w" -eq 53 ] || { bad "$1 box row is $w wide, want 53: [$l]"; b=1; }
                  case "$l" in *'║') ;; *) bad "$1 box row does not close: [$l]"; b=1 ;; esac ;;
        esac
    done <<< "$body"
    [ "$b" = 0 ] && ok "$1 is a well-formed 53-wide box"
    return $b
}
calls() { cat "$CZ_TEST_CALLS" 2>/dev/null; }
reset_calls() { : > "$CZ_TEST_CALLS"; }
# env(1) so the knobs are genuinely exported to the mocked arecord.
rec() { local d="$1"; shift; env CZ_RECORD_DIR="$d" bash "$CZ" "$@"; }
seed() { # seed <dir> <basename> <age-seconds>
    mkdir -p "$1"; printf 'RIFF\0\0\0\0WAVE' > "$1/$2.wav"
    touch -d "-$3 seconds" "$1/$2.wav"; }

echo "=== cz-record rec (tone) ==="
D="$WORK/r1"; mkdir -p "$D"; reset_calls
out=$(rec "$D" rec '' 1 2>&1); rc=$?
echo "$out"
n=$(find "$D" -name '*.wav' | wc -l)
if [ "$rc" = 0 ] && [ "$n" = 1 ]; then ok "rec saved exactly one wav"; else bad "rec saved $n wav(s), rc=$rc"; fi
has "$out" "RECORDING" "rec draws the themed RECORDING screen"
has "$out" "-> REC-" "rec names the saved file"
has "$out" "peak -8.7dB" "rec reports the tone peak level"
hasnt "$out" "SILENT" "tone recording is not flagged silent"
# Control names must be the short ALSA simple-control names the device reports.
has "$(calls)" "sset ADC MUX AMIC" "setup_mic selects the analog mic (AMIC)"
has "$(calls)" "sset Mic Jack on" "setup_mic enables the Mic Jack pin switch"
has "$(calls)" "sset ADCL 191" "setup_mic sets 0dBFS capture volume (191)"
has "$(calls)" "sset ADCR 191" "setup_mic sets both capture channels"
hasnt "$(calls)" "Capture Volume" "no long-form control names (they do not exist)"
hasnt "$(calls)" "PGA" "setup_mic leaves the DT-default PGA gain alone"
hasnt "$(calls)" "grove_5v_out" "capture does not touch the Grove 5V rail"
has "$(calls)" "-c 1 -r 48000" "captures mono 48kHz"
has "$(calls)" "plughw:CARD=ES8389Audio" "captures from the ES8389 card"
has "$(calls)" "-d 1" "an explicit duration is passed to arecord"
wide "rec output" "$out"
boxed "rec screen" "$out"

echo "=== cz-record rec (named) ==="
D="$WORK/r2"; mkdir -p "$D"; reset_calls
out=$(rec "$D" rec meeting 1 2>&1)
if find "$D" -name 'meeting-*.wav' | grep -q .; then ok "named recording uses <name>-<timestamp>.wav"; else bad "named recording not created: $out"; fi

echo "=== cz-record rec refuses to run unbounded without a tty ==="
D="$WORK/r9"; mkdir -p "$D"; reset_calls
out=$(rec "$D" rec < /dev/null 2>&1); rc=$?
echo "$out"
has "$out" "not a tty" "no-tty capture without a duration is refused"
has "$out" "cz-record rec note 10" "the refusal shows the duration syntax"
[ "$rc" = 1 ] && ok "unbounded no-tty capture exits 1" || bad "unbounded no-tty rc=$rc"
[ -z "$(find "$D" -name '*.wav' 2>/dev/null)" ] && ok "refused capture wrote no file" || bad "refused capture still wrote a file"

echo "=== cz-record rec rejects a non-numeric duration ==="
out=$(rec "$WORK/r9" rec '' abc 2>&1); rc=$?
has "$out" "seconds must be a number" "non-numeric duration is rejected"
[ "$rc" = 1 ] && ok "non-numeric duration exits 1" || bad "non-numeric duration rc=$rc"

echo "=== elapsed clock tracks real time (regression: it used to spin) ==="
D="$WORK/r7"; mkdir -p "$D"; reset_calls
export CZ_TEST_SLEEP=3
out=$(rec "$D" rec '' 3 2>&1)
unset CZ_TEST_SLEEP
t=$(strip "$out" | grep -F 'recording 3s' | grep -oE '[0-9][0-9]:[0-9][0-9]' | head -1)
if [ -z "$t" ]; then
    bad "no elapsed clock in output: $out"
else
    secs=$(( 10#${t%%:*} * 60 + 10#${t##*:} ))
    if [ "$secs" -ge 3 ] && [ "$secs" -le 8 ]; then ok "a 3s capture reports $t, not a spun counter"
    else bad "elapsed clock wrong for a 3s capture: $t ($secs s)"; fi
fi
has "$out" "peak -8.7dB" "capture that ran to completion is a valid, non-silent WAV"

echo "=== running() rejects a zombie (regression: kill -0 does not) ==="
# Source only the function definitions, not the subcommand dispatch at the bottom.
FUNCS=$(mktemp); trap 'rm -rf "$WORK"; rm -f "$FUNCS"' EXIT
n=$(grep -n '^case "\${1:-}" in' "$CZ" | tail -1 | cut -d: -f1)
head -n $((n-1)) "$CZ" > "$FUNCS"
zout=$(
    source "$FUNCS"
    sleep 0.1 & p=$!
    for _ in $(seq 1 40); do
        st=$(sed -e 's/.*) //' -e 's/ .*//' "/proc/$p/stat" 2>/dev/null)
        [ "$st" = Z ] && break
        sleep 0.05
    done
    kill -0 "$p" 2>/dev/null && echo "kill0=alive" || echo "kill0=gone"
    running "$p" && echo "running=alive" || echo "running=gone"
    wait "$p" 2>/dev/null
)
echo "$zout"
has "$zout" "running=gone" "running() reports an exited child as not running"
case "$zout" in
  *kill0=alive*) ok "kill -0 still saw it (zombie), so the old loop would have hung" ;;
  *) echo "INFO: bash reaped the child first (kill0=gone); zombie window not observed this run" ;;
esac

echo "=== cz-record rec (silence) ==="
D="$WORK/r3"; mkdir -p "$D"; reset_calls
export CZ_TEST_TONE=0
out=$(rec "$D" rec '' 1 2>&1); echo "$out"
export CZ_TEST_TONE=1
has "$out" "SILENT" "silent capture is reported, not silently accepted"
has "$out" "gain 210" "silence warning suggests raising the capture gain"

echo "=== cz-record rec (no card) ==="
export CZ_RECORD_CARDS="$WORK/nope"
out=$(rec "$WORK/r4" rec '' 1 2>&1); rc=$?
export CZ_RECORD_CARDS="$WORK/cards"
has "$out" "no ES8389 sound card" "missing card is reported"
[ "$rc" = 1 ] && ok "missing card exits 1" || bad "missing card rc=$rc"

echo "=== cz-record list / play / del ==="
D="$WORK/r5"; mkdir -p "$D"
seed "$D" newest 5; seed "$D" middle 50; seed "$D" oldest 500
out=$(rec "$D" list 2>&1); echo "$out"
has "$out" "newest" "list shows recordings"
has "$out" "dir: $D" "list reports the recordings directory"
first=$(printf '%s\n' "$out" | sed -n 1p | awk '{print $2}')
if [ "$first" = newest ]; then ok "list is newest-first"; else bad "list order: first=$first"; fi
has "$out" "3 oldest" "list numbers the recordings for play/del"
wide "list output" "$out"

reset_calls
out=$(printf 'x' | rec "$D" play 1 2>&1)
has "$(calls)" "aplay" "play invokes aplay"
has "$(calls)" "$D/newest.wav" "play 1 resolves to the newest recording"

out=$(printf 'y' | rec "$D" del 3 2>&1)
has "$out" "deleted" "del confirms deletion"
if [ -f "$D/oldest.wav" ]; then bad "del 3 removed the wrong file"; else ok "del 3 removed the oldest recording"; fi
[ -f "$D/newest.wav" ] && ok "del 3 left the newest recording intact" || bad "del 3 clobbered newest"

out=$(printf 'n' | rec "$D" del 1 2>&1)
has "$out" "kept" "declining delete keeps the file"
[ -f "$D/newest.wav" ] && ok "declined delete left the file on disk" || bad "declined delete removed the file"

out=$(rec "$D" play nosuchrec 2>&1); rc=$?
has "$out" "no recording: nosuchrec" "unknown name is reported"
[ "$rc" = 1 ] && ok "unknown name exits 1" || bad "unknown name rc=$rc"

echo "=== cz-record check ==="
D="$WORK/r6"; mkdir -p "$D"; reset_calls
export CZ_RECORD_PROBE=2
out=$(rec "$D" check 2>&1); rc=$?
echo "$out"
has "$out" "MIC CHECK" "check prints its title"
has "$out" "ES8389" "check identifies the card"
line_has "$out" "card 1 +\[ES8389Audio\]" "check shows a compact card label, not a truncated line"
hasnt "$out" "ES8389-Aud║" "the card line is not cut mid-word"
line_has "$out" "ADC MUX +AMIC +Mic Jack +on" "check shows the analog mux and pin switch"
line_has "$out" "ADCL +0\.00dB +ADCL PGA +24\.00dB" "check shows capture volume and PGA gain"
line_has "$out" "PGAL Select +DifferentialL" "check shows the left input mux"
line_has "$out" "PGAR Select +DifferentialR" "check shows the right input mux"
has "$out" "mic is picking up signal" "check passes on a real signal"
[ "$rc" = 0 ] && ok "check exits 0 on signal" || bad "check rc=$rc on signal"
[ -z "$(find "$D" -name '*.wav' 2>/dev/null)" ] && ok "check leaves no probe file behind" || bad "check leaked a probe wav"
wide "mic check output" "$out"
boxed "mic check screen" "$out"

reset_calls
export CZ_TEST_TONE=0
out=$(rec "$D" check 2>&1); rc=$?
export CZ_TEST_TONE=1
has "$out" "SILENT" "check reports a silent mic"
has "$out" "check Mic Jack / ADC MUX" "check names the pin switch as a likely cause"
has "$out" "cz-record gain 210" "check suggests raising the capture gain"
[ "$rc" = 4 ] && ok "check exits 4 on silence" || bad "check rc=$rc on silence"
boxed "silent mic check screen" "$out"

echo "=== cz-record gain ==="
reset_calls
out=$(rec "$WORK/r1" gain 210 2>&1); echo "$out"
has "$out" "capture volume = 210" "gain reports the new value"
has "$out" "9.5 dB" "gain converts the raw value to dB (-95.5 + 0.5/step)"
has "$(calls)" "sset ADCL 210" "gain writes the left ADC channel"
has "$(calls)" "sset ADCR 210" "gain writes the right ADC channel too"
wide "gain output" "$out"
out=$(rec "$WORK/r1" gain 999 2>&1); rc=$?
has "$out" "gain must be 0-255" "out-of-range gain is rejected"
[ "$rc" = 1 ] && ok "out-of-range gain exits 1" || bad "out-of-range gain rc=$rc"

echo "=== cz-record menu (interactive) ==="
D="$WORK/r8"; mkdir -p "$D"; reset_calls
seed "$D" demo 5
out=$(printf '400' | rec "$D" 2>&1); echo "$out"
has "$out" "RECORDER" "menu prints its title"
has "$out" "saved" "menu reports the recording count"
has "$out" "mic ok" "menu reports that the card is present"
has "$out" "1 Record" "menu offers Record"
has "$out" "4 Mic check" "menu offers Mic check"
has "$out" "MIC CHECK" "menu item 4 runs the mic check"
wide "menu output" "$out"
boxed "recorder menu screen" "$out"

echo "=== cz-record pick screen ==="
out=$(printf '0' | rec "$D" play 2>&1); echo "$out"
has "$out" "RECORDINGS" "pick lists the recordings"
has "$out" "1 demo" "pick shows the seeded recording"
has "$out" "0 Back" "pick offers Back"
has "$out" "play which?" "pick shows its prompt"
wide "pick output" "$out"
boxed "pick screen" "$out"

echo "=== usage ==="
out=$(bash "$CZ" bogus 2>&1); rc=$?
has "$out" "usage: cz-record" "unknown subcommand prints usage"
wide "usage output" "$out"
[ "$rc" = 1 ] && ok "unknown subcommand exits 1" || bad "usage rc=$rc"

echo
if [ "$fail" = 0 ]; then echo "CZ-RECORD OK"; else echo "CZ-RECORD PROBLEM"; exit 1; fi
