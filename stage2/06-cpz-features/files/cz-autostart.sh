# Start the status-bar session on the built-in LCD console only.
if [ -t 1 ] && [ "$(tty)" = "/dev/tty1" ] && [ -z "${TMUX:-}" ]; then
    if [ -x /usr/local/bin/cz ]; then
        MPID=""
        if [ -x /usr/local/bin/cz-monitor-shell ]; then
            cz-monitor-shell & MPID=$!
            printf 'prompt\n' > /tmp/.cz-repaint 2>/dev/null
        fi
        /usr/local/bin/cz
        [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
        printf 'waiting\n' > /tmp/.cz-repaint 2>/dev/null
    fi
fi
