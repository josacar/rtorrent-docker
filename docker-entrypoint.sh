#!/bin/sh
set -eu

# rtorrent-docker entrypoint
#
# Responsibilities:
#   1. Seed a sensible rtorrent.rc if the volume is empty.
#   2. Resolve several env vars onto import= overrides at runtime.
#   3. Exec rtorrent with the user-provided args.

if [ ! -s /config/rtorrent.rc ]; then
    # Fall back to the bundled default config the runtime image ships at
    # /config/rtorrent.rc.default (Docker copies image-dir contents into a
    # newly-attached volume, so this file should be present on first start).
    cp /config/rtorrent.rc.default /config/rtorrent.rc 2>/dev/null \
        || true
fi

# Allow runtime overrides without editing the rc file. rtorrent merges
# multiple imports in order, so we append a generated snippet last.
OVERRIDE_FILE=/config/.runtime-overrides.rc
: > "$OVERRIDE_FILE"

add_override() {
    printf '%s\n' "$1" >> "$OVERRIDE_FILE"
}

if [ -n "${RT_SCGI_PORT:-}" ]; then
    add_override "network.scgi.open_port = \"0.0.0.0:${RT_SCGI_PORT}\""
fi
if [ -n "${RT_SCGI_LOCAL:-}" ]; then
    add_override "network.scgi.open_local = \"${RT_SCGI_LOCAL}\""
fi
if [ -n "${RT_RPC_XML:-}" ]; then
    add_override "network.rpc.use_xmlrpc.set = ${RT_RPC_XML}"
fi
if [ -n "${RT_RPC_JSON:-}" ]; then
    add_override "network.rpc.use_jsonrpc.set = ${RT_RPC_JSON}"
fi
if [ -n "${RT_DOWNLOAD_DIR:-}" ]; then
    add_override "directory.default.set = \"${RT_DOWNLOAD_DIR}\""
fi
if [ -n "${RT_SESSION_DIR:-}" ]; then
    add_override "session.path.set = \"${RT_SESSION_DIR}\""
fi
if [ -n "${RT_PORT_RANGE:-}" ]; then
    add_override "network.listen.port.range.set = \"${RT_PORT_RANGE}\""
fi
if [ -n "${RT_UP_MAX_KB:-}" ]; then
    add_override "throttle.global_up.max_rate.set_kb = ${RT_UP_MAX_KB}"
fi
if [ -n "${RT_DOWN_MAX_KB:-}" ]; then
    add_override "throttle.global_down.max_rate.set_kb = ${RT_DOWN_MAX_KB}"
fi

# If there is any override, append -o import=... to argv. rtorrent supports
# multiple -o flags; we don't modify the user's argv, just prepend config.
if [ -s "$OVERRIDE_FILE" ]; then
    set -- "$@" -o "import=$OVERRIDE_FILE"
fi

exec "$@"