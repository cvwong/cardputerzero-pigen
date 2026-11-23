#!/bin/bash
# cz-theme.sh — shared themed-console helpers for CardputerZero (53x14 console).
# Sourced by cz-menu-theme and cz-record so the recorder and the menus cannot
# drift apart visually. Not meant to be executed on its own.
#
# Installed to /usr/local/lib/cz-theme.sh. Callers locate it via:
#   CZ_THEME="${CZ_THEME:-/usr/local/lib/cz-theme.sh}"
# which the tests override to point at the copy in the source tree.

# ---------------- configuration ----------------
BL="${CZ_BACKLIGHT:-/sys/class/backlight/backlight}"
CARD="${CZ_AUDIO_CARD:-ES8389Audio}"

# ---------------- THEME (fbcon-safe 16-color ANSI) ----------------
R=$'\e[0m'            # reset
BORDER=$'\e[34m'      # box border ......... blue
TITLE=$'\e[1;36m'     # screen title ....... bold cyan
NUM=$'\e[1;33m'       # option numbers ..... bold yellow
LBL=$'\e[1;37m'       # option labels ...... bold white
DIM=$'\e[90m'         # captions / hints ... gray
ACCENT=$'\e[36m'      # clock / accents .... cyan
OK=$'\e[32m'          # battery good ....... green
WARN=$'\e[33m'        # battery mid ........ yellow
BAD=$'\e[31m'         # battery low ........ red
# ------------------------------------------------------------------

# Linux console palette tweak so NUM's bold yellow reads as ffff55. Guarded on a
# tty: emitting an OSC sequence into a pipe would corrupt captured output.
cz_palette() { [ -t 1 ] && printf '\e]PBffff55'; return 0; }

# Box geometry: outer width 53, inner width 51.
_sp=$(printf '%51s' ''); HL=${_sp// /═}
sp()   { printf '%*s' "$1" ''; }
btop() { printf '%s╔%s╗%s\n' "$BORDER" "$HL" "$R"; }
bsep() { printf '%s╠%s╣%s\n' "$BORDER" "$HL" "$R"; }
bbot() { printf '%s╚%s╝%s\n' "$BORDER" "$HL" "$R"; }
# brow <plain-for-width> <colored-content>
brow() {
    local pad=$(( 51 - ${#1} )); (( pad < 0 )) && pad=0
    printf '%s║%s%s%*s%s║%s\n' "$BORDER" "$2" "$R" "$pad" '' "$BORDER" "$R"
}
title_row() {
    local t="$1" len l r
    len=${#t}
    l=$(( (51 - len) / 2 ))
    r=$(( 51 - len - l ))
    brow "$(sp "$l")$t$(sp "$r")" "$(sp "$l")$TITLE$t$R$(sp "$r")"
}

have()  { command -v "$1" >/dev/null 2>&1; }
pause() { printf '\npress any key'; read -r -n1 -s _; }

# ---------------- status values for the header line ----------------
bl()    { cat "$BL/brightness" 2>/dev/null || echo 0; }
blm()   { cat "$BL/max_brightness" 2>/dev/null || echo 100; }

vctl() { local names
    names=$(amixer -c "$CARD" scontrols 2>/dev/null \
            | sed -n "s/^Simple mixer control '\([^']*\)'.*/\1/p")
    printf '%s\n' "$names" | grep -m1 -E '^DAC[LR]$' || printf '%s\n' "$names" | head -1; }
VC=$(vctl)
vol() { if [ -n "$VC" ]; then
            amixer -c "$CARD" sget "$VC" 2>/dev/null | grep -o '[0-9]*%' | head -1
        else printf '?'; fi; }

bat() { for p in /sys/class/power_supply/*; do
          [ -r "$p/capacity" ] && { printf '%s%%' "$(cat "$p/capacity")"; return; }
        done; printf '?'; }
batcol() { local n; n=$(bat); n=${n%%%}
    case "$n" in
      ''|*[!0-9]*) printf '%s' "$DIM" ;;
      *) if [ "$n" -le 20 ]; then printf '%s' "$BAD"
         elif [ "$n" -le 50 ]; then printf '%s' "$WARN"
         else printf '%s' "$OK"; fi ;;
    esac; }
temp() { if have vcgencmd; then
             vcgencmd measure_temp 2>/dev/null | sed -e "s/^temp=//" -e "s/'C\$/°C/"
         else awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null; fi; }

# Boxed header: top border, centered title, context status line, separator.
# hdr <title> [mode]  mode: main=Battery/Date/Time, audio=Battery/Vol/Time,
# system=Battery/BL/Temp.
hdr() {
    clear
    btop
    title_row "$1"
    local mode="${2:-main}" bv tv dv midp midc tp tc
    bv=$(bat); tv=$(date +%I:%M%P); dv=$(date +%Y-%m-%d)
    case "$mode" in
      audio)  midp="Vol: $(vol)";      midc="${DIM}Vol:${R} ${LBL}$(vol)${R}" ;;
      system) midp="BL: $(bl)/$(blm)"; midc="${DIM}BL:${R} ${LBL}$(bl)/$(blm)${R}" ;;
      *)      midp="Date: $dv";        midc="${DIM}Date:${R} ${LBL}${dv}${R}" ;;
    esac
    if [ "$mode" = system ]; then
      tp="Temp: $(temp)"; tc="${DIM}Temp:${R} ${LBL}$(temp)${R}"
    else
      tp="Time: $tv";     tc="${DIM}Time:${R} ${ACCENT}$tv${R}"
    fi
    brow "  Battery: $bv  $midp  $tp" \
         "  ${DIM}Battery:${R} $(batcol)$bv$R  $midc  $tc"
    bsep
}

# hdr_lite <title> — boxed title with no status line, for content-heavy screens
# that need every remaining row (a full hdr costs one more line).
hdr_lite() {
    clear
    btop
    title_row "$1"
    bsep
}

# One-column item row (submenus): "  N Label"
row1() {
    local plain colored
    plain=$(printf '  %s %s' "$1" "$2")
    colored=$(printf '  %s%s%s %s%s%s' "$NUM" "$1" "$R" "$LBL" "$2" "$R")
    brow "$plain" "$colored"
}
# Two-column item row (main screen): "  N Label   N Label"
row2() {
    local plain colored
    plain=$(printf '  %s %-18s %s %s' "$1" "$2" "$3" "$4")
    colored=$(printf '  %s%s%s %s%-18s%s %s%s%s %s%s%s' \
        "$NUM" "$1" "$R" "$LBL" "$2" "$R" "$NUM" "$3" "$R" "$LBL" "$4" "$R")
    brow "$plain" "$colored"
}

# Themed yes/no confirmation. ask <question> -> 0 only on y/Y (default No).
ask() {
    local q="$1" c len l r
    clear
    btop
    title_row "CONFIRM"
    brow "" ""
    len=${#q}; l=$(( (51 - len) / 2 )); r=$(( 51 - len - l ))
    brow "$(sp "$l")$q$(sp "$r")" "$(sp "$l")$LBL$q$R$(sp "$r")"
    brow "" ""
    len=9; l=$(( (51 - len) / 2 )); r=$(( 51 - len - l ))
    brow "$(sp "$l")[ Y / N ]$(sp "$r")" \
         "$(sp "$l")${DIM}[ ${OK}Y${DIM} / ${BAD}N${DIM} ]${R}$(sp "$r")"
    brow "" ""
    bbot
    read -r -n1 -s c
    case "$c" in y|Y) return 0 ;; *) return 1 ;; esac
}
