# rtorrent-docker

> Minimal, performance-tuned Docker image of [rakshasa/rtorrent](https://github.com/rakshasa/rtorrent) **0.16.18** for the [Radxa Rock 3A](https://wiki.radxa.com/Rock3/3a) (RK3568, quad-core Cortex-A55 @ 2.0 GHz, ARMv8.2-A). Ships with **XML-RPC and JSON-RPC** over SCGI so [Flood](https://github.com/jesec/flood) works out of the box — no `xmlrpc-c` dependency, since rtorrent 0.16.x bundles `tinyxml2` and `nlohmann/json`.

Published as **arm64 only** to GHCR. Running it on a non-Cortex-A55 arm64 board still works (the ISA baseline is ARMv8.2-A) but loses the microarchitectural scheduling benefit.

---

## TL;DR

```sh
docker run -d \
  --name rtorrent \
  -p 5000:5000 \
  -p 6881:6881 \
  -p 6881:6881/udp \
  -v rtorrent-data:/data \
  -v rtorrent-session:/session \
  -v rtorrent-watch:/watch \
  -v rtorrent-config:/config \
  ghcr.io/josacar/rtorrent-docker:latest-armv8.2-rock3a
```

Pair with Flood:

```yaml
services:
  rtorrent:
    image: ghcr.io/josacar/rtorrent-docker:latest-armv8.2-rock3a
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
      FLOOD_OPTION_rtorrent_host: rtorrent
      FLOOD_OPTION_rtorrent_port: "5000"
      FLOOD_OPTION_rtorrent_socket: "false"
    volumes:
      - rtorrent-data:/data
      - flood-db:/flood-db
    ports:
      - "3000:3000"
    depends_on: [rtorrent]
```

Point Flood's SCGI endpoint at `rtorrent:5000`. Both XML-RPC and JSON-RPC are live simultaneously — pick whichever your Flood release prefers.

---

## Why these choices

### Version: rtorrent / libtorrent **0.16.18**

Latest stable from rakshasa (released 2026-07-17; the 0.16.x lineage began 2025-09-05 with `v0.16.0`). It mandates C++20, merges many long-standing 0.9.x PRs, and critically **bundles `tinyxml2` and `nlohmann/json`** so the binary speaks XML-RPC and JSON-RPC natively without an external `xmlrpc-c` build. Configure-time it's selected by:

```
--with-xmlrpc-tinyxml2
```

and at runtime:

```
network.rpc.use_xmlrpc.set = true
network.rpc.use_jsonrpc.set = true
```

### Distro: `debian:bookworm-slim` (glibc 2.36)

Picked for the **best sustained throughput** on the RK3568 specifically — not the smallest image and not the trendiest. The reasoning:

| Concern | Debian bookworm-slim | Alpine 3.20 (musl) | Distroless (gcr.io/distroless/cc) |
| --- | --- | --- | --- |
| Cortex-A55-tuned `memcpy`/`memmove` strings | Yes (glibc 2.36 ships armv8.2-tuned paths used at every piece-hash boundary) | No (musl is generic C) | Yes (same glibc as Debian) |
| Size (runtime layer) | ~22 MB | ~13 MB | ~20 MB |
| Has `bash`/`sh`/tools for debugging on device | Yes | Yes (busybox) | No |
| C++20 support in stock gcc | Yes (gcc 12) | Yes (gcc 13) | N/A (no compiler in image) |
| rtorrent historical compatibility | Excellent (most distros ship this) | Mixed (musl lacks `execinfo`, `posix_spawn` `close_range` auto-detected and disabled — minor features lost) | Fine, but you cannot run a shell in it |
| ASLR / allocator overhead | glibc malloc, competitive | musl allocator, lower RSS but slower under high-rate SCGI churn | Same Debian glibc |

**Verdict:** Debian bookworm-slim wins for the Rock 3A workload — rtorrent is a long-running C++ daemon that hammers small allocations on hash-piece boundaries and does frequent small SCGI round-trips with Flood. glibc 2.36 already carries Cortex-A55-tuned memory/string routines, so the runtime image benefits from the same target microarchitecture as the builder. The ~9 MB extra surface over Alpine is negligible for a daemon that sits in RAM for weeks.

### Build flags (Cortex-A55 / RK3568)

Applies in both the C (libtorrent) and C++ (rtorrent) stages, via `CFLAGS`/`CXXFLAGS`:

```
-O3
-march=armv8.2-a+crypto+crc+simd    # AES/SHA2/PMULL/CRC32/NEON for the A55
-mcpu=cortex-a55                    # scheduling + A55 erratum workarounds
-mtune=cortex-a55                   # schedule for A55 even if -mcpu is relaxed later
-flto=auto -ffat-lto-objects        # whole-program link-time optimization
-fgraph-ite -fdevirtualize-at-ltrans  # Graphite on hot loops + cheaper devirt at LTRANS
-fno-semantic-interposition          # hide lib symbols so callers inline our code
-fipa-pta                            # interprocedural points-to (better aliasing for LTO)
-fno-plt                             # skip PLT indirection for hidden symbols
```

Linker:

```
-Wl,-O1 -Wl,--as-needed -Wl,-z,now -Wl,-z,relro -Wl,--hash-style=gnu
```

The stage runs as `TARGETPLATFORM=linux/arm64` (via QEMU on amd64 GitHub runners, or natively on the device), so the gcc inside the stage is arm64 gcc and accepts the Cortex-A55 flags without complaint.

### CI: QEMU `arm64` only, published to GHCR

`.github/workflows/build.yml` runs on `ubuntu-latest`, sets up QEMU for `linux/arm64`, and builds via Buildx with GHA caching (`scope=arm64`). Tags:

- `latest-armv8.2-rock3a`, `arm64` — always point to the latest `main` build.
- `0.16.18` (full semver), `0.16`, `0` — produced by `v*` git tags.
- Branch and PR refs — for review builds.

SBOM and provenance attestation are generated for every published image. Tagging convention lives in `docker/metadata-action@v5`; override in the workflow if you want different tags.

A manual dispatch lets you build against a different 0.16.x release without editing files:

> Actions → `build-and-publish` → **Run workflow** → enter e.g. `0.16.17`.

---

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

To mount your own `rtorrent.rc`, bind-mount it at `/config/rtorrent.rc` and the entrypoint will leave it alone.

## Volumes

| Mount | Purpose |
| --- | --- |
| `/data` | Downloaded torrent data |
| `/config` | The `rtorrent.rc` + log |
| `/session` | rTorrent resume state (do **not** share across containers) |
| `/watch` | Drop `*.torrent` here to auto-load+start them |
| `/rpc` | Reserved for an SCGI unix socket if you prefer that over TCP |

## Exposed ports

| Port | Protocol | Use |
| --- | --- | --- |
| `5000` | TCP | SCGI endpoint for Flood / ruTorrent / web UIs |
| `6881` | TCP | BitTorrent peer wire |
| `6881` | UDP | BitTorrent DHT / UDP trackers |

---

## Build locally

```sh
# On the Rock 3A itself — fastest, no emulation, ~5 minutes.
podman build -t rtorrent:rock3a .

# On an x86_64 host — QEMU arm64 emulation; ~25–35 minutes.
podman build --platform linux/arm64 -t rtorrent:rock3a .
```

Override the pinned upstream version without editing the Dockerfile:

```sh
podman build \
  --build-arg RTORRENT_VERSION=0.16.17 \
  --build-arg LIBTORRENT_VERSION=0.16.17 \
  --platform linux/arm64 -t rtorrent:rock3a .
```

`make` wraps the common operations:

```sh
make build        # podman build --platform linux/arm64
make build-native # podman build (one-shot, on aarch64 host)
make run          # foreground run with default volumes
make shell        # exec sh into the running container
make inspect      # print rtorrent ELF attributes and look for crypto/crc intrinsics
make ghcr-push    # tag and push to ghcr.io/josacar/rtorrent-docker
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
```

```sh
$ objdump -d /usr/local/bin/rtorrent | grep -E 'aese|sha1h|pmull|crc32' | head
# intrinsics from -march=armv8.2-a+crypto+crc emitted by libtorrent
```

`make inspect` does both of these in a one-shot container.

## Healthcheck

The runtime image includes a TCP-listener healthcheck using `nc -z` (the minimal `netcat-openbsd` package):

```
HEALTHCHECK CMD nc -z 127.0.0.1 5000 || exit 1
```

It reports whether rTorrent has bound the SCGI port. A real SCGI-level probe (send a JSON-RPC `system.listMethods` and parse the response) would be possible but cost heavier runtime deps, so we trade precision for image size; pair this with `Flood`'s own connection-state UI for full RPC liveness.

---

## Versions

| Component | Version | Notes |
| --- | --- | --- |
| rakshasa/rtorrent | `0.16.18` (2026-07-17) | Latest stable; C++20, bundled `tinyxml2` + `nlohmann/json` |
| rakshasa/libtorrent | `0.16.18` (2026-07-17) | Paired release with rtorrent 0.16.18 |
| Builder | `debian:bookworm-slim` | gcc 12, autotools |
| Runtime | `debian:bookworm-slim` | glibc 2.36, libstdc++6, zlib1g, ca-certificates, netcat-openbsd |

Override at build time with `--build-arg RTORRENT_VERSION=…`.

## License

The rtorrent and libtorrent (rakshasa) source is **GPL-2.0-or-later**. Everything in this repository — the Dockerfile, entrypoint, default `rtorrent.rc`, Makefile, GitHub workflow — is **MIT** (see `LICENSE`). The combined container image that ships rakshasa binaries is GPL-2.0-or-later as a derivative work; pull-and-run freely.

## Acknowledgements

Thanks to rakshasa (Jari Sundell) and contributors for the original rtorrent/libtorrent. Thanks to the Flood maintainers for the web UI this image targets.