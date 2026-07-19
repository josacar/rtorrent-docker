.DEFAULT_GOAL := help

IMAGE ?= rtorrent:rock3a
PLATFORM ?= linux/arm64
GHCR ?= ghcr.io/josacar/rtorrent-docker

# Pretty help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	  /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Build the arm64 image (QEMU if you're on amd64)
	podman build --platform $(PLATFORM) -t $(IMAGE) .

build-native: ## Build natively on an aarch64 host (no QEMU)
	podman build -t $(IMAGE) .

run: ## Run the image in the foreground with default volumes
	podman run --rm -it \
		-p 5000:5000 -p 6881:6881 -p 6881:6881/udp \
		-v rtorrent-data:/data \
		-v rtorrent-session:/session \
		-v rtorrent-watch:/watch \
		-v rtorrent-config:/config \
		$(IMAGE)

shell: ## Exec sh into the running container (set NAME to override)
	NAME ?= rtorrent
	podman exec -it $(NAME) /bin/sh

inspect: ## Drop into a one-shot container and dump ELF attributes of rtorrent
	podman run --rm --entrypoint /bin/sh $(IMAGE) -c \
		'command -v readelf >/dev/null && readelf -A /usr/local/bin/rtorrent; \
		 command -v objdump >/dev/null && objdump -d /usr/local/bin/rtorrent \
		   | grep -E "aese|sha1h|pmull|crc32" | head -8'

ghcr-login: ## Log in to GHCR via `podman login`
	@echo "Set GHCR_TOKEN to a classic PAT with write:packages"; \
	echo podman login $(GHCR) -u $$USER --password-stdin <<< $$GHCR_TOKEN

ghcr-push: ## Tag and push the local image to GHCR
	podman tag $(IMAGE) $(GHCR):dev-arm64
	podman push $(GHCR):dev-arm64

clean: ## Remove local volumes
	podman volume rm rtorrent-data rtorrent-session rtorrent-watch rtorrent-config \
		2>/dev/null || true

.PHONY: help build build-native run shell inspect ghcr-login ghcr-push clean