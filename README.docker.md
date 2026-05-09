Running rTorrent in Docker
==========================

This repo ships a self-contained Docker setup that builds rTorrent (and the
matching `rakshasa/libtorrent`) from source and runs it as a headless daemon
with the session, watch, and download directories bind-mounted from the host.

* Configuration file: a host-side `rtorrent.rc` mounted into the container.
* Persistent state:   host directories for `session/`, `watch/`, `download/`.
* Daemon mode:        `system.daemon.set = true` — no TTY, runs as PID 1.
* External access:    SCGI/XMLRPC on `127.0.0.1:5000` and BT peer port `6881`.

Quick start
-----------

```sh
# 1. Prepare host directories.
mkdir -p config data/session data/watch/load data/watch/start data/download

# 2. Drop in a starting rtorrent.rc.
cp docker/rtorrent.rc.example config/rtorrent.rc
$EDITOR config/rtorrent.rc        # tweak as needed (see "Paths" below)

# 3. Build and start.
docker compose up -d --build

# 4. Watch the log.
docker compose logs -f rtorrent
```

Adding a torrent: drop a `.torrent` file into `data/watch/start/` (auto-start)
or `data/watch/load/` (load paused). The `schedule2` lines in the sample
`rtorrent.rc` poll those directories every 10 seconds.

To stop: `docker compose down`. The session directory is on the host, so
restarts pick up exactly where the previous run left off.

File layout
-----------

| Path                          | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `Dockerfile`                  | Multi-stage build: builds libtorrent + rtorrent, slim runtime.   |
| `docker-compose.yml`          | Service definition, port publishes, volume bindings.             |
| `docker/entrypoint.sh`        | Aligns container uid/gid to `PUID`/`PGID`, then drops privileges via `gosu`. |
| `docker/rtorrent.rc.example`  | Starter config preconfigured for the in-container paths.         |
| `.dockerignore`               | Keeps autotools intermediates out of the build context.          |

In-container paths the image expects:

| Container path           | Mounted from (default in compose) | Contents                              |
| ------------------------ | --------------------------------- | ------------------------------------- |
| `/config/rtorrent.rc`    | `./config/rtorrent.rc` (ro)       | Config file loaded via `-O import=`.  |
| `/data/session`          | `./data/session`                  | rTorrent session state (resume data). |
| `/data/watch`            | `./data/watch`                    | Drop-in directory for `.torrent` files. |
| `/data/download`         | `./data/download`                 | Default download directory.           |

The example `rtorrent.rc` already references these in-container paths, so the
only thing you typically need to edit on the host is *which* host directories
sit on the left side of the `volumes:` mappings.

Ports
-----

| Port               | Protocol | Purpose                                              |
| ------------------ | -------- | ---------------------------------------------------- |
| `6881`             | TCP      | Incoming BitTorrent peer connections.                |
| `6881`             | UDP      | DHT.                                                 |
| `127.0.0.1:5000`   | TCP      | SCGI / XMLRPC (RuTorrent, Flood, `xmlrpc-cli`, etc.).|

The SCGI port is bound to loopback on the host because **SCGI has no
authentication**. To make it reachable from another machine, put a reverse
proxy (nginx, Caddy) with auth in front of it instead of publishing the port
publicly.

If you change `network.port_range.set` in `rtorrent.rc`, update the `ports:`
block in `docker-compose.yml` to match — they have to be the same number for
inbound peers to actually reach the container.

Configuration
-------------

The image runs `rtorrent -n -O import=/config/rtorrent.rc` as PID 1
(via `tini` for signal forwarding):

* `-n` skips loading the default `~/.rtorrent.rc`.
* `-O import=...` loads exactly the file you mounted at `/config/rtorrent.rc`.

Required directives in your `rtorrent.rc`:

```
system.daemon.set       = true              # disables ncurses; container needs no TTY
network.scgi.open_port  = 0.0.0.0:5000      # bind inside the container, not on the host
session.path.set        = /data/session
directory.default.set   = /data/download
```

The provided `docker/rtorrent.rc.example` covers all of these plus sensible
peer/throttle/DHT defaults.

Build args
----------

| Build arg          | Default       | Notes                                                                |
| ------------------ | ------------- | -------------------------------------------------------------------- |
| `LIBTORRENT_REF`   | `master`      | Git ref of `rakshasa/libtorrent` to build. Tracks master because rtorrent's `develop` branch uses post-0.16.11 libtorrent headers (e.g. `torrent/runtime/network_config.h`). Pin to a commit hash for reproducible builds. |
| `DEBIAN_VERSION`   | `bookworm`    | Base image tag for both stages.                                      |

Override at build time:

```sh
docker compose build --build-arg LIBTORRENT_REF=master
```

Runtime environment
-------------------

| Env var       | Default                  | Notes                                                       |
| ------------- | ------------------------ | ----------------------------------------------------------- |
| `PUID`        | `1000`                   | Numeric uid the rtorrent process drops to.                  |
| `PGID`        | `1000`                   | Numeric gid the rtorrent process drops to.                  |
| `TZ`          | `Asia/Tokyo` (in compose)| Affects log timestamps.                                     |
| `RTORRENT_RC` | `/config/rtorrent.rc`    | Path the entrypoint checks for existence before exec.       |

Set `PUID`/`PGID` to your host user's ids if `1000:1000` doesn't match — this
keeps files in `data/download/` owned by you on the host, not by some random
container uid.

Accessing the running daemon
----------------------------

From the host, anything that speaks SCGI works against `127.0.0.1:5000`. A
quick sanity-check:

```sh
# Using xmlrpc2scgi.py from the rtorrent wiki, or a tool like rtxmlrpc:
rtxmlrpc -D scgi://127.0.0.1:5000 system.client_version
```

To attach another container (RuTorrent, Flood, …) on the same compose
network, point it at `rtorrent:5000` rather than the host port. You can
either add the second service to this `docker-compose.yml` or use an external
network.

Troubleshooting
---------------

* **`rtorrent` exits immediately with no error.** Almost always means daemon
  mode is off and rtorrent tried to open ncurses. Make sure
  `system.daemon.set = true` is in `rtorrent.rc`.
* **SCGI port refuses connections.** Check that `network.scgi.open_port` is
  `0.0.0.0:5000`, not `127.0.0.1:5000` — the loopback in the container is not
  reachable through the published port.
* **Permissions on `data/download/`.** Set `PUID`/`PGID` to match the host
  user that owns those directories.
* **Build fails on the libtorrent step.** Bump or pin `LIBTORRENT_REF` to a
  ref that matches this rTorrent version (see `configure.ac` `AC_INIT`).
* **Peers can't connect.** Confirm the same port number appears in
  `network.port_range.set` (in `rtorrent.rc`) and in `docker-compose.yml`'s
  `ports:` block, and that your router/firewall forwards it.
