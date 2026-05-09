#!/bin/sh
# Entrypoint for the rtorrent container.
#
# - Re-aligns the rtorrent user to PUID/PGID so bind-mounted host
#   directories keep their ownership semantics.
# - Verifies the config file exists and is readable.
# - Drops privileges and execs rtorrent.

set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
RTORRENT_RC="${RTORRENT_RC:-/config/rtorrent.rc}"

if [ ! -f "${RTORRENT_RC}" ]; then
    echo "entrypoint: rtorrent config not found at ${RTORRENT_RC}" >&2
    echo "entrypoint: mount one with -v /path/on/host/rtorrent.rc:${RTORRENT_RC}:ro" >&2
    exit 1
fi

# Adjust user/group ids if the caller asked for something other than the
# defaults baked into the image. usermod/groupmod are idempotent.
current_uid="$(id -u rtorrent)"
current_gid="$(id -g rtorrent)"
if [ "${current_gid}" != "${PGID}" ]; then
    groupmod -o -g "${PGID}" rtorrent
fi
if [ "${current_uid}" != "${PUID}" ]; then
    usermod  -o -u "${PUID}" rtorrent
fi

# Ensure the data dirs are writable for the runtime user. We only chown the
# top-level mounts (cheap) — not the contents — to avoid pathological cost on
# large download trees.
for d in /config /data/session /data/watch /data/download; do
    [ -d "${d}" ] || continue
    own="$(stat -c '%u:%g' "${d}")"
    if [ "${own}" != "${PUID}:${PGID}" ]; then
        chown "${PUID}:${PGID}" "${d}" || true
    fi
done

exec gosu rtorrent "$@"
