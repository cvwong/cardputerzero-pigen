#!/bin/bash
# Layout test for cz-menu-theme: render main + a submenu, strip ANSI, and verify
# every line is exactly 53 columns and each screen fits the console row budget.
# Run: bash tests/cz-menu-theme-layout.sh
set -u
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../stage2/06-cpz-features/files/cz-menu-theme"
# cz-menu-theme sources the shared theme lib from /usr/local/lib, which does not
# exist on a dev machine, so point it at the copy in the source tree.
export CZ_THEME="$HERE/../stage2/06-cpz-features/files/cz-theme.sh"
[ -r "$CZ_THEME" ] || { echo "missing $CZ_THEME"; exit 1; }
FUNCS="$(mktemp)"
trap 'rm -f "$FUNCS"' EXIT
# Load only the function/theme definitions, not the interactive main loop.
n=$(grep -n '^while :; do' "$SRC" | tail -1 | cut -d: -f1)
head -n $((n-1)) "$SRC" > "$FUNCS"
source "$FUNCS"
# Mock environment-dependent helpers so the test runs anywhere.
clear() { :; }
bat() { printf '%s' '85%'; }
bl()  { printf '%s' '60'; }
blm() { printf '%s' '100'; }
vol() { printf '%s' '40%'; }
temp() { printf '%s' '45.0°C'; }

# Render the real screens from cz-menu-theme rather than a hand-copied mirror, so
# this test cannot silently drift from the menu it is supposed to be checking.
# menu() draws the whole screen before reading a key, so feeding it the Back key
# makes it render exactly once and return without executing any menu command.
# Repeated so a stray earlier read cannot leave us looping on EOF.
Z='0000000000'
render_main()    { main_screen; }
render_sub()     { printf '%s' "$Z" | m_audio; }
render_system()  { printf '%s' "$Z" | m_system; }
render_display() { printf '%s' "$Z" | m_display; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
check() {
    local label="$1" body="$2" bad=0 w l rows
    echo "----- $label -----"
    printf '%s\n' "$body"
    while IFS= read -r l; do
        w=${#l}; [ "$w" -ne 53 ] && { echo "  !! width $w (want 53): [$l]"; bad=1; }
    done <<< "$body"
    rows=$(printf '%s\n' "$body" | wc -l)
    # A render that silently produced too little would still satisfy the width
    # loop and the row budget, so require a plausible minimum as well.
    [ "$rows" -lt 6 ] && { echo "  !! only $rows rows - render looks empty/truncated"; bad=1; }
    echo "  rows=$rows (console=14, tmux~13)  widths_ok=$([ $bad = 0 ] && echo yes || echo NO)"
    [ "$bad" = 0 ] && [ "$rows" -le 13 ]
}
render_ask() { printf 'n' | ask "Reboot the device?"; }
main_s="$(render_main | strip)"; sub_s="$(render_sub | strip)"; sys_s="$(render_system | strip)"; disp_s="$(render_display | strip)"
check "MAIN" "$main_s"; a=$?
check "AUDIO submenu" "$sub_s"; b=$?
check "SYSTEM submenu" "$sys_s"; s=$?
check "DISPLAY submenu" "$disp_s"; d=$?
check "CONFIRM(ask)" "$(render_ask | strip)"; c=$?
# Status bar fields per context.
st=0
case "$main_s" in *"Battery:"*"Date:"*"Time:"*) ;; *) st=1 ;; esac
case "$sub_s" in *"Vol:"*) ;; *) st=1 ;; esac
case "$sys_s" in *"BL:"*"Temp:"*) ;; *) st=1 ;; esac
case "$disp_s" in *"BL:"*) ;; *) st=1 ;; esac
[[ "$main_s" =~ Time:\ [0-9][0-9]:[0-9][0-9](am|pm) ]] || { st=1; echo "  !! main Time not in am/pm"; }
echo "status fields (main=Battery/Date/Time, audio=Vol, system=BL/Temp, display=BL): $([ $st = 0 ] && echo OK || echo FAIL)"
# Every key the main screen advertises must have a matching case branch in the
# real script, and every case branch must be advertised. This is what catches a
# menu edit that updated the labels but forgot the dispatch, or the reverse.
bind=0
rendered=$(printf '%s\n' "$main_s" | grep -v 'Battery:' \
    | grep -oE '[0-9] [A-Z][A-Za-z]*' | awk '{print $1}' | sort -u)
dispatched=$(grep -oE '^      [0-9]\)' "$SRC" | grep -oE '[0-9]' | sort -u)
# NB: do not reuse a/b/s/d/c here -- those hold the check() results.
for key in $rendered; do
    printf '%s\n' "$dispatched" | grep -qx "$key" \
        || { echo "  !! main screen shows key $key but no case branch handles it"; bind=1; }
done
for key in $dispatched; do
    printf '%s\n' "$rendered" | grep -qx "$key" \
        || { echo "  !! case branch $key is not shown on the main screen"; bind=1; }
done
echo "main screen keys match the case dispatch: $([ $bind = 0 ] && echo OK || echo FAIL)"
echo "  rendered=[$(echo $rendered | tr -s ' ')] dispatched=[$(echo $dispatched | tr -s ' ')]"
# ask must confirm only on y/Y; anything else (incl. Enter) is No.
printf 'y'  | ask "Q?" >/dev/null; r1=$?
printf 'Y'  | ask "Q?" >/dev/null; r2=$?
printf 'n'  | ask "Q?" >/dev/null; r3=$?
printf '\n' | ask "Q?" >/dev/null; r4=$?
beh=0; [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$r3" = 1 ] && [ "$r4" = 1 ] || beh=1
echo "ask accepts y/Y only (y=$r1 Y=$r2 n=$r3 enter=$r4): $([ $beh = 0 ] && echo OK || echo FAIL)"
echo
if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$s" = 0 ] && [ "$d" = 0 ] && [ "$c" = 0 ] && [ "$beh" = 0 ] && [ "$st" = 0 ] && [ "$bind" = 0 ]; then echo "LAYOUT OK"; else echo "LAYOUT PROBLEM"; exit 1; fi
