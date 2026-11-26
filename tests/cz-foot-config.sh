#!/bin/bash
# Regression test for the monitor terminal's foot configuration.
#
# Two defects made Alt+P (return the console to the panel) inert, which is a dead
# end rather than an inconvenience: once cage holds the input seat, the kernel
# keymap in cz-console-switch.map no longer reaches the console, so foot's
# binding is the only way back to the panel.
#
#   1. foot.ini was installed to /etc/foot/foot.ini, which foot never reads - it
#      searches $XDG_CONFIG_HOME/foot/foot.ini and /etc/xdg/foot/foot.ini (the
#      latter owned by the foot package).
#   2. The binding read `Alt+P=spawn cz-output panel`. foot's syntax is
#      action=[argv] key, and there is no "spawn" action, so foot rejected the
#      file outright: "not a valid action: Alt+P", exit 230. Pointing foot at the
#      file via --config without also fixing the syntax would have stopped the
#      monitor terminal from starting at all - strictly worse than the dead key.
#
# foot is not installed on the build host, so this validates structurally against
# the action list that foot 1.21.0 documents in its own shipped default config
# (/etc/xdg/foot/foot.ini on the device). Re-derive that list if foot is
# upgraded; `foot --check-config --config=<file>` on the device is authoritative
# and is how both defects above were confirmed.
# Run: bash tests/cz-foot-config.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INI="$HERE/../stage2/06-cpz-features/files/foot.ini"
UNIT="$HERE/../stage2/06-cpz-features/files/cz-cage.service"
INSTALL="$HERE/../stage2/06-cpz-features/01-run.sh"

ACTIONS="scrollback-up-page scrollback-up-half-page scrollback-up-line
scrollback-down-page scrollback-down-half-page scrollback-down-line
scrollback-home scrollback-end clipboard-copy clipboard-paste primary-paste
search-start font-increase font-decrease font-reset spawn-terminal minimize
maximize fullscreen pipe-visible pipe-scrollback pipe-selected
pipe-command-output show-urls-launch show-urls-copy show-urls-persistent
prompt-prev prompt-next unicode-input noop quit"

fail=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }
is_action() { local a; for a in $ACTIONS; do [ "$a" = "$1" ] && return 0; done; return 1; }

echo "=== [key-bindings] syntax: action=[argv] key, never key=command ==="
in_sec=0; checked=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) continue ;;
        '['*']') if [ "$line" = "[key-bindings]" ]; then in_sec=1; else in_sec=0; fi; continue ;;
    esac
    [ "$in_sec" = 1 ] || continue
    checked=$((checked+1))
    lhs=${line%%=*}; rhs=${line#*=}
    case "$lhs" in
        *+*) bad "binding is written key=action (backwards): $line"; continue ;;
    esac
    if is_action "$lhs"; then ok "'$lhs' is an action foot accepts"
    else bad "'$lhs' is not a valid foot action: $line"; fi
    case "$rhs" in
        '['*']'*) ok "argv is bracketed as foot requires: $rhs" ;;
        *) bad "argv is not bracketed (foot needs [cmd args] key): $rhs" ;;
    esac
done < "$INI"
[ "$checked" -gt 0 ] && ok "checked $checked binding(s)" \
    || bad "no bindings found under [key-bindings] - this test would be vacuous"

echo "=== the binding actually returns to the panel ==="
grep -q 'cz-output panel' "$INI" && ok "runs cz-output panel" || bad "no cz-output panel binding"
grep -qE 'Alt\+p' "$INI" && ok "bound to Alt+p (the keysym the keypad reports)" \
    || bad "not bound to Alt+p"

echo "=== foot must be pointed at our config explicitly ==="
grep -q -- '--config=/etc/foot/foot.ini' "$UNIT" \
    && ok "cz-cage.service passes --config" \
    || bad "no --config: foot reads /etc/xdg/foot/foot.ini and never sees our binding"
UNITCFG=$(sed -n 's|.*--config=\([^ ]*\).*|\1|p' "$UNIT" | head -1)
[ -n "$UNITCFG" ] && ok "unit points at $UNITCFG" || bad "could not parse --config path"
if [ -n "$UNITCFG" ]; then
    pat='"${ROOTFS_DIR}'"$UNITCFG"'"'
    grep -qF -- "$pat" "$INSTALL" && ok "01-run.sh installs foot.ini to exactly that path" \
        || bad "01-run.sh does not install to $UNITCFG (looked for $pat)"
fi
grep -qF 'files/foot.ini' "$INSTALL" && ok "the source file installed is files/foot.ini" \
    || bad "files/foot.ini is never installed"

echo
if [ "$fail" = 0 ]; then echo "CZ-FOOT-CONFIG OK"; else echo "CZ-FOOT-CONFIG PROBLEM"; exit 1; fi
