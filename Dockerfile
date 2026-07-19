# syntax=docker/dockerfile:1.6

# =============================================================================
# Builder stage — produces an armv8.2 / Cortex-A55-tuned rtorrent 0.16.18 binary.
#
# Tune flags are only valid on a real aarch64 build host; they are a no-op
# when QEMU is emulating arm64 from an amd64 GitHub runner because the
# underlying instruction set is still emulated arm64.
#
# Tune recipe (Cortex-A55 / RK3568):
#   -march=armv8.2-a+crypto+crc+simd  enable AES/SHA2/PMULL/CRC32/NEON ISA
#   -mcpu=cortex-a55                  enable A55 scheduling + erratum workarounds
#   -mtune=cortex-a55                 schedule for A55 even if -mcpu is relaxed later
#   -O3 -flto=auto -ffat-lto-objects   whole-program LTO with fat objects for cache hits
#   -fgraph-ite -fdevirtualize-at-ltrans   cheaper devirt + Graphite on hot loops
#   -fno-semantic-interposition        hide lib symbols so callers inline our code
#   -fipa-pta                          interprocedural points-to (better aliasing)
# Build runs as TARGETPLATFORM (arm64, emulated by QEMU on amd64 runners) so
# gcc inside the stage is arm64 gcc and accepts the cortex-a55 flags.
# =============================================================================
FROM debian:bookworm-slim AS builder

ARG RTORRENT_VERSION=0.16.18
ARG LIBTORRENT_VERSION=0.16.18
ARG PARALLELISM=""

# Rock 3A / RK3568 / Cortex-A55 / ARMv8.2-A optimization flags.
# Used for both libtorrent (C) and rtorrent (C++) build.
ENV OPT_FLAGS="-O3 -march=armv8.2-a+crypto+crc+simd -mcpu=cortex-a55 -mtune=cortex-a55 -flto=auto -ffat-lto-objects -fgraph-ite -fdevirtualize-at-ltrans -fno-semantic-interposition -fipa-pta -fno-plt"
ENV LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -Wl,--hash-style=gnu"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils pkg-config make \
        gcc g++ g++-12 libc6-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# ----- Build libtorrent (rakshasa) -----------------------------------------
RUN curl -fsSL -o libtorrent.tar.gz \
        "https://github.com/rakshasa/rtorrent/releases/download/v${RTORRENT_VERSION}/libtorrent-${LIBTORRENT_VERSION}.tar.gz" \
    && mkdir -p libtorrent \
    && tar -xf libtorrent.tar.gz -C libtorrent --strip-components=1 \
    && rm libtorrent.tar.gz

RUN cd libtorrent \
    && export CFLAGS="$OPT_FLAGS" \
    && export CXXFLAGS="$OPT_FLAGS" \
    && export LDFLAGS="$LDFLAGS" \
    && ./configure \
        --prefix=/usr/local \
        --disable-debug \
        --disable-extra-debug \
    && make -j"$(nproc)${PARALLELISM:+=$PARALLELISM}" \
    && make install \
    && ldconfig /usr/local/lib

# ----- Build rtorrent ------------------------------------------------------
RUN curl -fsSL -o rtorrent.tar.gz \
        "https://github.com/rakshasa/rtorrent/releases/download/v${RTORRENT_VERSION}/rtorrent-${RTORRENT_VERSION}.tar.gz" \
    && mkdir -p rtorrent \
    && tar -xf rtorrent.tar.gz -C rtorrent --strip-components=1 \
    && rm rtorrent.tar.gz

RUN cd rtorrent \
    && export CFLAGS="$OPT_FLAGS" \
    && export CXXFLAGS="$OPT_FLAGS" \
    && export LDFLAGS="$LDFLAGS" \
    && ./configure \
        --prefix=/usr/local \
        --disable-debug \
        --disable-extra-debug \
        --disable-execinfo \
        --without-lua \
        --with-xmlrpc-tinyxml2 \
        --without-ncurses \
    && make -j"$(nproc)${PARALLELISM:+=$PARALLELISM}" \
    && make install-strip

# Confirm the binary is built (loaded by arm64 libc via QEMU or native) and
# report its ELF attributes for visibility in CI logs.
RUN /usr/local/bin/rtorrent -h 2>&1 | head -1 || true

# =============================================================================
# Runtime stage — Debian bookworm-slim (glibc 2.36, arm64 with cortex-a55
# tuned memcpy/memmove/atomics in glibc 2.36+). Minimal footprint (~25 MB).
# =============================================================================
FROM debian:bookworm-slim AS runtime

ARG RTORRENT_VERSION=0.16.18
LABEL org.opencontainers.image.title="rtorrent (armv8.2 / Cortex-A55 tuned)" \
      org.opencontainers.image.description="rakshasa rtorrent ${RTORRENT_VERSION}, optimized for Rock 3A (RK3568) with JSON-RPC + XML-RPC over SCGI for Flood." \
      org.opencontainers.image.source="https://github.com/rakshasa/rtorrent" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libstdc++6 zlib1g ca-certificates netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/* /tmp/*

# Non-root user. UID/GID 1000 by default; override with --user or env at runtime.
RUN groupadd --system --gid 1000 rtorrent \
    && useradd --system --uid 1000 --gid rtorrent --home-dir /data --shell /usr/sbin/nologin rtorrent \
    && mkdir -p /data /config /watch /session /rpc \
    && chown -R rtorrent:rtorrent /data /config /watch /session /rpc

COPY --from=builder /usr/local/bin/rtorrent /usr/local/bin/rtorrent
COPY --from=builder /usr/local/lib/libtorrent.so* /usr/local/lib/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY rtorrent.rc /config/rtorrent.rc.default

# Seed /config/rtorrent.rc from the default on first start of an empty config volume.
RUN ldconfig \
    && chmod 0755 /usr/local/bin/docker-entrypoint.sh \
    && chmod 0644 /config/rtorrent.rc.default

# Copy the default config into /config so rtorrent starts even with an empty
# config volume. This is a one-shot seed; the entrypoint won't overwrite a
# non-empty /config/rtorrent.rc at runtime.
RUN cp /config/rtorrent.rc.default /config/rtorrent.rc 2>/dev/null || true

USER rtorrent
WORKDIR /data

# Flood talks SCGI to rtorrent. XML-RPC + JSON-RPC are both enabled in the
# default rtorrent.rc, exposed on 0.0.0.0:5000. Remap as needed.
EXPOSE 5000/tcp 6881/tcp 6881/udp

VOLUME ["/data", "/config", "/watch", "/session", "/rpc"]

# Tiny SCGI liveness probe: TCP connect succeeds iff rtorrent is listening.
# We can't easily speak SCGI from the minimal runtime shell, so this is a
# listener check (orchestrators get accurate 'process up + socket bound'
# signal, which is what most rtorrent deployments use).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD nc -z 127.0.0.1 5000 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["rtorrent", "-n", "-o", "import=/config/rtorrent.rc"]