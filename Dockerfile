# syntax=docker/dockerfile:1.6
#
# Multi-stage build for rtorrent + libtorrent (rakshasa fork).
#
# rtorrent links against a *specific* libtorrent ABI from
# https://github.com/rakshasa/libtorrent. Pin LIBTORRENT_REF to a tag
# matching this rtorrent version (see configure.ac AC_INIT version).

ARG DEBIAN_VERSION=bookworm

# ---------- builder ----------
FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG LIBTORRENT_REF=master

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        git \
        ca-certificates \
        libcurl4-openssl-dev \
        libncurses-dev \
        libssl-dev \
        libtinyxml2-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Build libtorrent (rakshasa fork) at the matching ref.
WORKDIR /src
RUN git clone --depth 1 --branch "${LIBTORRENT_REF}" \
        https://github.com/rakshasa/libtorrent.git libtorrent
WORKDIR /src/libtorrent
RUN libtoolize \
 && aclocal -I scripts \
 && autoconf -i \
 && autoheader \
 && automake --add-missing \
 && ./configure --prefix=/usr/local --disable-debug \
 && make -j"$(nproc)" \
 && make install

# Build rtorrent from the current source tree.
WORKDIR /src/rtorrent
COPY . .
RUN libtoolize \
 && aclocal -I scripts \
 && autoconf -i \
 && autoheader \
 && automake --add-missing \
 && ./configure --prefix=/usr/local --with-xmlrpc-tinyxml2 --disable-debug \
 && make -j"$(nproc)" \
 && make install \
 && strip /usr/local/bin/rtorrent /usr/local/lib/libtorrent.so.*.*.*

# ---------- runtime ----------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl4 \
        libncursesw6 \
        libtinyxml2-9 \
        zlib1g \
        tini \
        gosu \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/rtorrent /usr/local/bin/rtorrent
COPY --from=builder /usr/local/lib/libtorrent.so* /usr/local/lib/
RUN ldconfig

# Create a default rtorrent user (uid/gid overridable via PUID/PGID env vars
# resolved by entrypoint).
RUN groupadd -g 1000 rtorrent \
 && useradd  -u 1000 -g 1000 -d /home/rtorrent -m -s /usr/sbin/nologin rtorrent \
 && mkdir -p /config /data/session /data/watch /data/download \
 && chown -R rtorrent:rtorrent /config /data /home/rtorrent

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 6881 = BT peer port (tcp) + DHT (udp); 5000 = SCGI/XMLRPC.
EXPOSE 6881/tcp 6881/udp 5000/tcp

VOLUME ["/data/session", "/data/watch", "/data/download"]

ENV PUID=1000 PGID=1000 \
    RTORRENT_RC=/config/rtorrent.rc

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["rtorrent", "-n", "-O", "import=/config/rtorrent.rc"]
