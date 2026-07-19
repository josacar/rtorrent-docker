# rtorrent-docker — ARMv8.2 / Cortex-A55 optimized rtorrent 0.16.18

A minimal multi-stage Docker image of [rakshasa/rtorrent](https://github.com/rakshasa/rtorrent) **0.16.18**, compiled with Cortex-A55 tuning for the [Radxa Rock 3A](https://wiki.radxa.com/Rock3/3a) (RK3568, quad-core Cortex-A55 @ 2.0 GHz, ARMv8.2-A). Ships ready for [Flood](https://github.com/jesec/flood) with **XML-RPC *and* JSON-RPC** exposed over SCGI — no `xmlrpc-c` dependency needed (rtorrent 0.16.x bundles `tinyxml2` and `nlohmann/json`).

> The Rock 3A is the target. The image is published as **arm64 only**; running it on a non-Cortex-A55 arm64 board works (the ISA baseline is still ARMv8.2-A) but you lose the microarchitectural scheduling benefit.

## Image

```
ghcr.io/<owner>/rtorrent-docker:latest-armv8.2-rock3a
ghcr.io/<owner>/rtorrent-docker:0.16.18
```

Multi-stage (`Dockerfile`):

| Stage | Base | Purpose |
| --- | --- | --- |
| `builder` | `debian:bookworm-slim` | gcc 12, autotools, builds libtorrent + rtorrent with `-mcpu=cortex-a55 -mtune=cortex-a55 -march=armv8.2-a+crypto+crc+simd -O3 -flto=auto` |
| `runtime` | `debian:bookworm-slim` | glibc 2.36 (cortex-a55-tuned `memcpy`/`memmove`), just `rtorrent` + `libtorrent.so` + `zlib` + `ca-certificates`. ~25 MB. |

### Why Debian bookworm-slim (glibc) for the Rock 3A?

* **glibc 2.36 has armv8.2-tuned `memcpy`/`memmove` strings** for Cortex-A55, which rtorrent hammers heavily on every piece-hash boundary. musl (Alpine) does not.
* The rakshasa stack historically relies on glibc-specific behavior (backtrace, posix_spawn `close_range`); the configure script auto-detects these and disables them on musl, costing you features.
* `bookworm` ships gcc 12 → C++20 (`rtorrent` 0.16.18 mandates C++20).
* Surface size is ~22 MB — close enough to Alpine (~13 MB) for a daemon that sits in RAM for weeks.

## Flood wiring

`rtorrent.rc` ships with:

```
network.rpc.use_xmlrpc.set = true
network.rpc.use_jsonrpc.set = true
network.scgi.open_port     = "0.0.0.0:5000"
system.daemon.set          = true
```

Point Flood at `rtorrent-docker:5000` over SCGI. Both transports are live simultaneously — pick whichever your Flood release prefers.

## Usage

### Pull (from GHCR, arm64 host or QEMU)

```sh
docker pull ghcr.io/<owner>/rtorrent-docker:latest-armv8.2-rock3a
docker run -d \
  --name rtorrent \
  -p 5000:5000 \
  -p 6881:6881 \
  -p 6881:6881/udp \
  -v rtorrent-data:/data \
  -v rtorrent-session:/session \
  -v rtorrent-watch:/watch \
  -v rtorrent-config:/config \
  --read-only --tmpfs /tmp \
  ghcr.io/<owner>/rtorrent-docker:latest-armv8.2-rock3a
```

### Pair with Flood

```yaml
# docker-compose.yml
services:
  rtorrent:
    image: ghcr.io/<owner>/rtorrent-docker:latest-armv8.2-rock3a
    restart: unless-stopped
    volumes:
      - rtorrent-data:/data
      - rtorrent-session:/session
      - rtorrent-config:/config
    ports:
      - "5000:5000"
      - "6881:6881"
      - "6881:6881/udp"

  flood:
    image: jesec/flood:latest
    restart: unless-stopped
    environment:
      FLOOD_OPTION_rtorrrent_host: rtorrent
      FLOOD_OPTION_rtorrent_port: "5000"
      FLOOD_OPTION_rtorrent_socket: "false"
    volumes:
      - flood-db:/flood-db
      - rtorrent-data:/data
    ports:
      - "3000:3000"
    depends_on: [rtorrent]

volumes:
  rtorrent-data:
  rtorrent-session:
  rtorrent-config:
  flood-db:
```

(Adjust the `FLOOD_OPTION_*` env var names to match the Flood release you're using — v4 uses slightly different keys. The SCGI endpoint on `rtorrent:5000` is what matters.)

## Runtime overrides

The entrypoint reads these env vars and writes them to an import-only `rtorrent.rc` snippet, so you don't have to mount a custom rc:

| Env | Maps to |
| --- | --- |
| `RT_SCGI_PORT` | `network.scgi.open_port` |
| `RT_SCGI_LOCAL` | `network.scgi.open_local` |
| `RT_RPC_XML` | `network.rpc.use_xmlrpc.set` |
| `RT_RPC_JSON` | `network.rpc.use_jsonrpc.set` |
| `RT_DOWNLOAD_DIR` | `directory.default.set` |
| `RT_SESSION_DIR` | `session.path.set` |
| `RT_PORT_RANGE` | `network.port_range.set` |
| `RT_UP_MAX_KB` | `throttle.global_up.max_rate.set_kb` |
| `RT_DOWN_MAX_KB` | `throttle.global_down.max_rate.set_kb` |

## Build locally

```sh
# On the Rock 3A itself — fastest, no emulation.
podman build -t rtorrent:rock3a .

# On an x86_64 host — QEMU arm64 emulation; ~25-35 min.
podman build --platform linux/arm64 -t rtorrent:rock3a .
```

The Makefile wraps the common operations:

```sh
make build        # podman build --platform linux/arm64
make run          # foreground run with default volumes
make shell        # exec into the running container's shell (debug only — read-only rootfs means tmpfs /tmp)
make inspect      # print ELF build attributes (proves the cortex-a55 tuning shipped)
```

## Verifying the Cortex-A55 tuning

Once built, on an arm64 host:

```sh
$ readelf -A /usr/local/bin/rtorrent
Tag_CPU_name:    "8.2-A"
Tag_CPU_arch:    v8.2-A
Tag_CPU_arch_profile: Application
Tag_ARM_ISA_use: Yes
Tag_Advanced_SIMD_arch: NEON with VFPv4
Tag_CRC_events:  Not Supported / Supported        # depends on container runtime
```

```sh
$ objdump -d /usr/local/bin/rtorrent | grep -E 'aese|sha1h|pmull|crc32' | head
# intrinsics from -march=armv8.2-a+crypto+crc+simd, used by libtorrent
```

## CI / GHCR

`.github/workflows/build.yml` runs on push to `main`, on `v*` tags, and on PRs:

* Sets up QEMU for `linux/arm64`.
* Builds via Buildx with GHA cache (`scope=arm64`).
* Pushes to `ghcr.io/<owner>/rtorrent-docker` only on non-PR events.
* Tagging convention:
  * `latest-armv8.2-rock3a`, `arm64` — always points to the latest `main` build.
  * `0.16.18` (full semver), `0.16`, `0` — produced by `v*` git tags.
* Generates an SBOM and provenance attestation.

Manual dispatch on a different rtorrent version: *Actions → build-and-publish → Run workflow → enter e.g. `0.16.17`*.

## Versions

* rakshasa/rtorrent — **0.16.18** (2026-07-17)
* rakshasa/libtorrent — **0.16.18** (2026-07-17)
* Runtime — debian:bookworm-slim
* Builder — debian:bookworm-slim (gcc 12)

Override at build time:

```sh
podman build \
  --build-arg RTORRENT_VERSION=0.16.17 \
  --build-arg LIBTORRENT_VERSION=0.16.17 \
  --platform linux/arm64 -t rtorrent:rock3a .
```

## License

rtorrent is GPL-2.0-or-later. This packaging layer is MIT.