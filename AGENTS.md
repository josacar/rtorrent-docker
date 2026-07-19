# AGENTS.md — guide for AI agents working on this repository

This file tells an AI assistant (Claude, GPT, Copilot, Crush, etc.) how to navigate and modify **rtorrent-docker**. It is the source of truth for "how do we do things here." Match the conventions here when editing.

---

## Repository purpose

A *minimal*, *performance-tuned* Docker image of [rakshasa/rtorrent](https://github.com/rakshasa/rtorrent) **0.16.18** built for the **Radxa Rock 3A** (RK3568, quad-core Cortex-A55 @ 2.0 GHz, ARMv8.2-A). The image exposes **XML-RPC and JSON-RPC** over SCGI so [Flood](https://github.com/jesec/flood) can talk to it directly — without requiring an external `xmlrpc-c` build, because rtorrent 0.16.x bundles `tinyxml2` and `nlohmann/json`.

The image is **arm64 only** and lives on GHCR. Everything in the repo is a packaging layer over upstream rakshasa releases; we do not fork rakshasa here.

## Project facts to keep in mind

- **Target ISA/microarch:** ARMv8.2-A, Cortex-A55. The Dockerfile's `OPT_FLAGS` is the canonical place to tune. If you change it, justify the change in the comment block above the `ENV OPT_FLAGS=...` line.
- **Builder and runtime base:** `debian:trixie-slim` (gcc 14, glibc 2.41). Do not switch to Alpine/musl without re-evaluating `libtorrent`'s glibc-specific configure probes (`execinfo`, `posix_spawn` `close_range`, etc.) — see the comparison table in `README.md`.
- **Upstream versions** are pinned to `0.16.18` for both libtorrent and rtorrent; match them (they release in lockstep). Override at build time via build-args if you need to test an older release.
- **C++20 is mandatory** for rtorrent 0.16.x. The stock Debian `g++-12` satisfies it.
- **The published manifest is `linux/arm64` only.** There is no amd64 image; that is intentional. If you want a multi-arch manifest you'll need to rewrite `.github/workflows/build.yml`.

## Repo layout

```
|.
├── .env.example                    # Runtime env vars reference
├── .github/dependabot.yml          # Weekly dependency bump PRs
├── .github/workflows/build.yml     # Native arm64 build + GHCR push
├── Dockerfile                      # Multi-stage: builder (tuned) → runtime (minimal)
├── docker-compose.yml              # rtorrent + Flood one-command deploy
├── docker-entrypoint.sh            # Seeds config and overlays runtime env overrides
├── rtorrent.rc                     # Default config shipped as /config/rtorrent.rc.default
├── Makefile                        # Local dev helpers wrapping podman
├── LICENSE                         # MIT for packaging layer (rtorrent is GPL-2.0+)
├── README.md
└── AGENTS.md                       # This file
```

Key conventions:

- `Dockerfile` has **two stages**: `builder` and `runtime`. The `builder` stage has no `--platform=$BUILDPLATFORM` prefix, so it runs as the target platform (arm64). That's deliberate — without it, the Cortex-A55 gcc flags would be invalid on amd64. Keep it that way.
- The runtime stage copies `rtorrent` + `libtorrent.so*` only. If you need a runtime tool (`nc`, `curl`, `dtach`, etc.), add it via `apt-get install --no-install-recommends` and weigh size vs. function.
- The default config ships at `/config/rtorrent.rc.default`. `docker-entrypoint.sh` copies it to `/config/rtorrent.rc` **only if the latter is empty/missing** (i.e. fresh volume). This is so a user-mounted custom `rtorrent.rc` is never overwritten.
- The entrypoint applies runtime env overrides (`RT_*` vars) as an appended `import=` snippet, so users don't have to remount a config file to tweak a port or path.

## Build & test commands

| Action | Command |
| --- | --- |
| Lint the Dockerfile parses | `podman build --target builder --no-cache --progress=plain . 2>&1 \| head -50` |
| Build on arm64 host (Rock 3A, native, fast) | `podman build -t rtorrent:rock3a .` |
| Build on amd64 host (QEMU, slow) | `podman build --platform linux/arm64 -t rtorrent:rock3a .` |
| Run container in foreground | `make run` |
| Verify ELF tuning printed | `make inspect` |
| Validate workflow YAML | `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))"` |
| Validate entrypoint shell syntax | `dash -n docker-entrypoint.sh` |

There is **no test suite** — this is a packaging repo. The closest thing to a test is the end-to-end build, run, and `nc -z 127.0.0.1 5000` healthcheck in the Dockerfile itself.

### What "passing" means

- `Dockerfile` builds end-to-end on `linux/arm64` (natively or via QEMU).
- `podman run` reaches a healthy endpoint at `127.0.0.1:5000` (Flood can connect).
- `make inspect` shows `Tag_CPU_arch: v8.2-A` and `aese`/`sha1h`/`pmull`/`crc32` intrinsics in the binary.
- The GHCR workflow publishes with SBOM + provenance intact.

## Conventions for edits

- **Match the existing comment style:** comments in `Dockerfile` are *descriptive* ("Tune recipe (Cortex-A55 / RK3568):" followed by a column-aligned table of `-flag` → purpose). Don't inline terse `# note:` comments.
- **Don't add comments** that explain what the next line does. We already have them where it matters (build flags, entrypoint responsibilities). User-facing *why* comments are encouraged; mechanical *what* comments are noise.
- **Never use em dashes (`—`) in code or config.** Use commas, periods, parentheses, or semicolons. The build flags comment blocks are a good reference for the right voice.
- **Indentation:** `Dockerfile` uses 4-space continuation indent under each `RUN`/`LABEL`/`ENV`; `&&` chains wrap with `\` at end of line, next line continues with 4 spaces.
- **YAML:** `.github/workflows/build.yml` uses 2-space indent.
- **Shell:** `docker-entrypoint.sh` is POSIX `sh` (shebang `#!/bin/sh`, checks pass under `dash -n`). **Do not** introduce bashisms (`[[`, arrays, `<()` process substitution, etc.) unless you also change the shebang.
- **Tags & labels:** use lowercase `org.opencontainers.image.*` labels in the runtime stage. Don't invent new label prefixes.
- **Build args** are upper-snake-case (`RTORRENT_VERSION`, `LIBTORRENT_VERSION`, `PARALLELISM`). Runtime env vars are `RT_*` upper-snake. Match this.

## When changing versions

rtorrent and libtorrent release **in lockstep**. They live in the same GitHub release tarball set (`https://github.com/rakshasa/rtorrent/releases/download/vX.Y.Z/libtorrent-X.Y.Z.tar.gz` and `.../rtorrent-X.Y.Z.tar.gz`). If you bump one, bump the other.

After a bump:

1. Update the `ARG RTORRENT_VERSION=` and `ARG LIBTORRENT_VERSION=` defaults in `Dockerfile`.
2. Update the `ARG RTORRENT_VERSION=` default in the `runtime` stage if present.
3. Update `RTORRENT_VERSION` build-arg defaults in `.github/workflows/build.yml` (the `workflow_dispatch` default and the `build-args:` value).
4. Update the **Versions** table at the bottom of `README.md`.
5. Re-run `python3 -c "import yaml; ..."` on the workflow and `dash -n docker-entrypoint.sh` to confirm you didn't break anything.

## When changing build flags

The `OPT_FLAGS` string in the `builder` stage is the heart of the project. If you change it:

- Keep it **one line** (multi-word env value); a single `ENV` is easier to grep and override than several.
- Document each flag in the comment block above it (right-aligned explanation), matching the existing table style.
- Don't introduce flags that aren't valid for both C and C++ frontends — the same `OPT_FLAGS` feeds both the `libtorrent` (C) and `rtorrent` (C++) stages. If you truly need a C++-only flag, apply it via per-stage `CXXFLAGS` only.
- Re-test with `make inspect` and confirm `readelf -A` still reports `Tag_CPU_arch: v8.2-A`.

## When changing the entrypoint

The contract is:

1. **First-run seeding:** if `/config/rtorrent.rc` is empty or missing, copy from `/config/rtorrent.rc.default`. Never overwrite a non-empty user file.
2. **Overlay env overrides** (`RT_*` variables) into `/config/.runtime-overrides.rc`.
3. **Append an `-o import=/config/.runtime-overrides.rc`** to the user-supplied `argv` if and only if the override file is non-empty. `rtorrent` supports repeated `-o import=...` lines.
4. **Exec** the user's command — never `fork`+`exit`. The PID 1 contract matters for orchestrators.

If you add a new `RT_*` override, also document it in the README's "Runtime overrides" table.

## When changing CI

`.github/workflows/build.yml` uses `actions/checkout@v7` + `docker/setup-buildx-action@v4` + `docker/login-action@v4` + `docker/metadata-action@v6` + `docker/build-push-action@v7`. Caching is `type=gha,scope=arm64`. Keep:

- `platforms: linux/arm64` (single-arch, by design).
- `cache-from: type=gha,scope=arm64` and `cache-to: type=gha,mode=max,scope=arm64` (uses GitHub Actions cache, scope namespaced by arch so a future multi-arch build doesn't collide).
- `provenance: true` and `sbom: true` — these are deliberate; do not remove them.

If changing tags/labels, edit the `tags:` multi-line block under `steps.meta`. The convention is `latest-armv8.2-rock3a` for the moving tip and `arm64` for an arch alias; semver tagging is handled by `type=semver,pattern=…`.

`docker-compose.yml` ships rtorrent + Flood in a single compose file. If you add extra services (Caddy, health dashboard, etc.), keep them behind optional profiles so the default `docker compose up -d` still starts only rtorrent + Flood.

`docker-compose.yml` uses `FLOOD_OPTION_rthost` / `FLOOD_OPTION_rtport` (Flood v4 CLI option names, mapped via yargs`.env('FLOOD_OPTION_')`). If Flood adds new client-connection options, mirror them in the compose file.

## Things not to do
- Don't pin to a musl-based image to "save space" without a benchmark that beats the glibc 2.41-Cortex-A55-tuned string routines in throughput. Surface size is not the priority for this image.
- Don't change the license. The packaging layer is MIT; rakshasa binaries it ships are GPL-2.0-or-later. This split is documented in both `LICENSE` and `README.md`.
- Don't add multi-arch manifests in passing — that's a deliberate single-arch image. If you need a fallback for non-Rock arm64 hosts, prefer a separate workflow or stage over loosening the build flags.
- Don't add a `--platform=$BUILDPLATFORM` to the `builder` stage. The Cortex-A55 flags are only valid on arm64 gcc; making the builder match the host would fail on amd64.
- Don't introduce `bash`/`curl`/`jq` runtime deps so you can do a fancier healthcheck — the current `nc -z` probe is a deliberate size/perf tradeoff. A real SCGI pulse is the responsibility of the downstream UI (Flood), not the container's own healthcheck.
- Don't commit binary artifacts or downloaded tarballs. `Dockerfile` curls them at build time and `.gitignore` blocks the obvious detritus.

## rtorrent 0.16.x command-name gotchas

The doc files shipped in `rakshasa/rtorrent` v0.16.x (`doc/rtorrent.rc` and `doc/rtorrent.rc-example`) are **partly stale**. The binary was refactored when 0.9.x was merged into the 0.16.x trunk, and the example rc files were not fully updated.

If your container starts and immediately exits with `Command "<name>" does not exist`, grep the source, don't trust the doc files:

| Doc says | Binary accepts in 0.16.18 | Registered at |
| --- | --- | --- |
| `schedule2 = name, i, j, command` | `schedule = name, i, j, command` | `src/command_events.cc:343` (`CMD2_ANY_LIST("schedule", ...)`) |
| `network.port_range.set = ...` | `network.listen.port.range.set = "..."` | `src/command_network.cc:324` |
| `network.port_random.set = ...` | `network.listen.port.random.set = ...` | `src/command_network.cc:322` |
| `dht.port.set = ...` | `dht.override_port.set = ...` (old logs a deprecation warning) | `src/command_tracker.cc:145` |
| `trackers.use_udp.set = ...` | **Removed** — logs "no longer supported" and does nothing. UDP trackers are always enabled in 0.16.x. | `src/command_tracker.cc:135-137` |
| `pieces.hash.on_completion.set = ...` | **Removed** — not found in v0.16.18 source. | N/A |
| `load.start=./path/*.torrent` (with `=`) | `((load.start, (cat, ./path/, "*.torrent")))` (comma form, single arg) or `load.start, "./path/file.torrent"` | `src/command_events.cc:351` |
| `method.set_key = <event>, <key>, <command>` | Only valid for **real** event names like `download.start`, `system.network.*`. Don't invent events like `watch_directory`. | `src/main.cc` |

To enumerate the binary's actual commands at runtime:

```
rtorrent -n -o 'print=(system.list_methods)'
```

…or via SCGI from Flood. Treat `doc/rtorrent.rc*` as a rough guide, not a syntax reference. The reliable reference is the cmd-ref docs at <https://rtorrent-docs.readthedocs.io/en/latest/cmd-ref.html>.

## Useful upstream references

- rtorrent source tree: https://github.com/rakshasa/rtorrent/tree/v0.16.18
- `src/rpc/jsonrpc.cc` and `src/rpc/xmlrpc.cc` are proof that both transports ship in 0.16.x without external libs.
- `configure.ac` flags are authoritative for build knobs (`--disable-debug`, `--without-lua`, `--with-xmlrpc-tinyxml2`, `--without-ncurses`, `TORRENT_WITH_XMLRPC_C`, `TORRENT_WITH_LUA`, `TORRENT_WITH_TINYXML2`, `TORRENT_WITH_SYSTEMD`).
- Reference rtorrent.rc: https://github.com/rakshasa/rtorrent/blob/v0.16.18/doc/rtorrent.rc
- Command reference docs: https://rtorrent-docs.readthedocs.io/
- Release tarballs: https://github.com/rakshasa/rtorrent/releases (libtorrent and rtorrent in the same release set)

## Default branches and PR style

- The default branch is `main`. Keep commits small and focused; one logical change per commit.
- Squash-merge is fine. The workflow re-runs on squash to `main` and republishes `latest-armv8.2-rock3a`.
- Tag releases as `vX.Y.Z` (mirroring the upstream rtorrent version it ships), e.g. `v0.16.18`. The workflow's `type=semver` patterns then produce `:0.16.18`, `:0.16`, `:0`.

## Quick agent checklist before you commit

- [ ] `dash -n docker-entrypoint.sh` passes.
- [ ] `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))"` passes.
- [ ] You bumped `RTORRENT_VERSION` *and* `LIBTORRENT_VERSION` in lockstep.
- [ ] If you changed `OPT_FLAGS`, you explained every new flag in the comment block.
- [ ] If you added an `RT_*` env override, you documented it in the README table.
- [ ] No em dashes in code/config.
- [ ] No multi-arch manifest changes sneaked in.
- [ ] No new runtime deps unless the size is worth the feature.
- [ ] If you added a new config or service file (`docker-compose.yml`, `.env.example`) you updated this checklist and the repo layout diagram.
- [ ] `--disable-execinfo` is NOT in the Dockerfile — we removed it to keep crash backtraces on glibc.