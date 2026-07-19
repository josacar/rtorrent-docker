# syntax=docker/dockerfile:1.6

# =============================================================================
# Builder stage — produces a tuned rtorrent 0.16.18 binary for either
# arm64 (Cortex-A55 / Rock 3A) or amd64 (x86-64-v3).
#
# The TARGETPLATFORM build-arg (supplied automatically by buildx) selects
# arch-specific gcc flags. On ubuntu-24.04-arm the arm64 flags compile
# natively; on ubuntu-latest the amd64 flags compile natively. QEMU is not
# needed because the Dockerfile's own CI runs each arch on native hardware.
#
# Tune recipes:
#
#   arm64 (Cortex-A55 / RK3568):
#     -march=armv8.2-a+crypto+crc+simd  enable AES/SHA2/PMULL/CRC32/NEON ISA
#     -mcpu=cortex-a55                  enable A55 scheduling + erratum workarounds
#     -mtune=cortex-a55                 schedule for A55 even if -mcpu is relaxed later
#     -O3 -flto=auto -ffat-lto-objects
#     -fgraphite -fdevirtualize-at-ltrans
#     -fno-semantic-interposition
#     -fipa-pta                         interprocedural points-to (LTO)
#     -fno-plt
#
#   amd64 (x86-64-v3 baseline):
#     -march=x86-64-v3                  Haswell+ baseline (AVX2, BMI, FMA, MOVBE)
#     -O3 -flto=auto -ffat-lto-objects
#     -fgraphite -fdevirtualize-at-ltrans
#     -fno-semantic-interposition
#     -fno-plt
# =============================================================================
FROM debian:trixie-slim AS builder

ARG RTORRENT_VERSION=0.16.18
ARG LIBTORRENT_VERSION=0.16.18
ARG PARALLELISM=""

# TARGETPLATFORM is set automatically by buildx (e.g. linux/arm64, linux/amd64).
# We use it to select arch-specific optimization flags.
ARG TARGETPLATFORM

# Write arch-specific flags once; each subsequent RUN sources this file.
RUN printf 'case "$TARGETPLATFORM" in\n  linux/arm64)\n    OPT_FLAGS="-O3 -march=armv8.2-a+crypto+crc+simd -mcpu=cortex-a55 -mtune=cortex-a55 -flto=auto -ffat-lto-objects -fgraphite -fdevirtualize-at-ltrans -fno-semantic-interposition -fipa-pta -fno-plt"\n    ;;\n  linux/amd64)\n    OPT_FLAGS="-O3 -march=x86-64-v3 -flto=auto -ffat-lto-objects -fgraphite -fdevirtualize-at-ltrans -fno-semantic-interposition -fno-plt"\n    ;;\n  *)\n    echo "Unsupported target: $TARGETPLATFORM" >&2; exit 1 ;;\nesac\n' > /tmp/arch_flags.sh

ENV LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -Wl,--hash-style=gnu"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils pkg-config make \
        gcc g++ libc6-dev zlib1g-dev \
        libssl-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Pre-configure sanity check: compile a trivial program with the chosen flags.
# If a flag is bogus, gcc prints the real diagnostic (not autoconf's terse
# "C compiler cannot create executables").
RUN . /tmp/arch_flags.sh \
    && printf 'int main(void){return 0;}\n' > /tmp/conftest.c \
    && gcc $OPT_FLAGS $LDFLAGS -o /tmp/conftest /tmp/conftest.c \
    && /tmp/conftest

# ----- Build libtorrent (rakshasa) -----------------------------------------
RUN curl -fsSL -o libtorrent.tar.gz \
        "https://github.com/rakshasa/rtorrent/releases/download/v${RTORRENT_VERSION}/libtorrent-${LIBTORRENT_VERSION}.tar.gz" \
    && mkdir -p libtorrent \
    && tar -xf libtorrent.tar.gz -C libtorrent --strip-components=1 \
    && rm libtorrent.tar.gz

RUN . /tmp/arch_flags.sh \
    && export CFLAGS="$OPT_FLAGS" \
    && export CXXFLAGS="$OPT_FLAGS" \
    && export LDFLAGS="$LDFLAGS" \
    && cd libtorrent \
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

RUN . /tmp/arch_flags.sh \
    && export CFLAGS="$OPT_FLAGS" \
    && export CXXFLAGS="$OPT_FLAGS" \
    && export LDFLAGS="$LDFLAGS" \
    && cd rtorrent \
    && ./configure \
        --prefix=/usr/local \
        --disable-debug \
        --disable-extra-debug \
        --without-lua \
        --with-xmlrpc-tinyxml2 \
        --without-ncurses \
    && make -j"$(nproc)${PARALLELISM:+=$PARALLELISM}" \
    && make install-strip

# Confirm rtorrent runs.
RUN /usr/local/bin/rtorrent -h 2>&1 | head -1 || true

# =============================================================================
# Runtime stage. Minimal trixie-slim (~29 MB arm64, ~26 MB amd64) with just
# enough runtime deps for the rtorrent binary.
# =============================================================================
FROM debian:trixie-slim AS runtime

ARG RTORRENT_VERSION=0.16.18
LABEL org.opencontainers.image.title="rtorrent (optimized)" \
      org.opencontainers.image.description="rakshasa rtorrent ${RTORRENT_VERSION}, tuned per-arch with JSON-RPC + XML-RPC over SCGI for Flood." \
      org.opencontainers.image.source="https://github.com/rakshasa/rtorrent" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libstdc++6 zlib1g libssl3t64 libcurl4t64 ca-certificates netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/* /tmp/*

# Non-root user. UID/GID 1000 by default; override with --user or env at runtime.
RUN groupadd --system --gid 1000 rtorrent \
    && useradd --system --uid 1000 --gid rtorrent --home-dir /data --shell /usr/sbin/nologin rtorrent \
    && mkdir -p /data /config /watch /session \
    && chown -R rtorrent:rtorrent /data /config /watch /session

COPY --from=builder /usr/local/bin/rtorrent /usr/local/bin/rtorrent
COPY --from=builder /usr/local/lib/libtorrent.so* /usr/local/lib/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY rtorrent.rc /config/rtorrent.rc.default

# Seed /config/rtorrent.rc from the default on first start of an empty config volume.
RUN ldconfig \
    && chmod 0755 /usr/local/bin/docker-entrypoint.sh \
    && chmod 0644 /config/rtorrent.rc.default

# Copy the default config into /config so rtorrent starts even with an empty
# config volume. The entrypoint won't overwrite a user-mounted file.
RUN cp /config/rtorrent.rc.default /config/rtorrent.rc 2>/dev/null || true

USER rtorrent
WORKDIR /data

# Flood talks SCGI to rtorrent. XML-RPC + JSON-RPC are both enabled in the
# default rtorrent.rc, exposed on 0.0.0.0:5000.  The BitTorrent port range
# is configurable via env or a mounted rc file.
EXPOSE 5000/tcp 6881/tcp 6881/udp

VOLUME ["/data", "/config", "/watch", "/session"]

# TCP-connect liveness probe: confirms rtorrent bound the SCGI port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD nc -z 127.0.0.1 5000 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["rtorrent", "-n", "-o", "import=/config/rtorrent.rc"]