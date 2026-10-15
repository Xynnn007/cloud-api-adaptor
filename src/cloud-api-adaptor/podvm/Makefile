include ../Makefile.defaults
include ./Makefile.inc

# Makefile.inc re-includes ../Makefile.defaults. At that point the last word in
# $(MAKEFILE_LIST) is Makefile.inc, so Makefile.defaults recomputes ROOT_PATH
# relative to podvm/ and VERSIONS_SRC points to a non-existent file under
# podvm/. Reset it to the real project-root versions.yaml and recompute the
# derived values that the alinux3 build uses.
VERSIONS_SRC := $(abspath $(dir $(CURDIR))/versions.yaml)
VERSIONS_HASH := $(firstword $(shell sha256sum $(VERSIONS_SRC)))
ifeq ($(PODVM_TAG),)
	PODVM_TAG := $(VERSIONS_HASH)
endif
# Re-evaluate the alinux image variables using the corrected VERSIONS_SRC.
alinux_amd64_IMAGE_URL := $(call query,cloudimg.alinux.$(alinux_RELEASE).amd64.url)
alinux_amd64_IMAGE_CHECKSUM := $(shell $(YQ_COMMAND) '.cloudimg.alinux.$(alinux_RELEASE).amd64.checksum' $(VERSIONS_SRC) 2>/dev/null)

SE_BOOT   ?= false
IS_DEBIAN := $(shell if grep -q 'ID_LIKE=debian' /etc/os-release; then echo "true"; else echo "false"; fi)

REGISTRY ?= quay.io/confidential-containers
ifeq ($(PODVM_TAG),)
	PODVM_TAG := $(VERSIONS_HASH)
endif
PODVM_BUILDER_IMAGE ?= $(REGISTRY)/podvm-builder-ubuntu-$(DISTRO_ARCH):$(PODVM_TAG)
PODVM_BINARIES_IMAGE ?= $(REGISTRY)/podvm-binaries-ubuntu-$(DISTRO_ARCH):$(PODVM_TAG)
PODVM_IMAGE ?= $(REGISTRY)/podvm-generic-ubuntu$(if $(filter $(SE_BOOT),true),-se,)-$(DISTRO_ARCH):$(PODVM_TAG)
PODVM_CONTAINER_NAME ?= $(REGISTRY)/podvm-docker-image-$(DISTRO_ARCH)
PODVM_BYOM_BINARIES_IMAGE ?= $(REGISTRY)/podvm-byom-binaries-ubuntu-$(DISTRO_ARCH)
PODVM_BYOM_E2E_CONTAINER_NAME ?= $(REGISTRY)/podvm-byom-e2e-image-$(DISTRO_ARCH)
VERIFY_PROVENANCE ?= no
MKOSI_VERSION ?= v26

# Alibaba Cloud Linux 3 Pod VM image settings
ALINUX3_BUILDER_IMAGE ?= $(call query,oci.alinux3.registry):$(call query,oci.alinux3.tag)
PODVM_ALINUX3_CUSTOMIZER_IMAGE ?= $(REGISTRY)/podvm-alinux3-customizer-$(DISTRO_ARCH):$(PODVM_TAG)
PODVM_ALINUX3_IMAGE ?= $(REGISTRY)/podvm-alinux3-$(DISTRO_ARCH):$(PODVM_TAG)

# If HTTP_PROXY/HTTPS_PROXY are set in the environment, propagate them as build
# args so BuildKit containers use the proxy even when the daemon-level config is
# not picked up.
#
# Build containers are on the docker bridge network. 127.0.0.1/localhost inside
# a container is the container itself, not the host, so rewrite such proxy URLs
# to the docker bridge gateway address.
# Prefer reading docker0 directly. `docker network inspect` may emit a blank
# line on stdout before failing (e.g. permission denied), which would pollute
# the IP when combined with `||`.
_DOCKER_BRIDGE_IP := $(shell ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 | tr -d '[:space:]')

# Rewrite loopback proxy URLs so build containers can reach the host proxy.
ifeq ($(_DOCKER_BRIDGE_IP),)
_HTTP_PROXY_FOR_BUILD := $(HTTP_PROXY)
_HTTPS_PROXY_FOR_BUILD := $(HTTPS_PROXY)
else
_HTTP_PROXY_FOR_BUILD := $(subst ://127.0.0.1,://$(_DOCKER_BRIDGE_IP),$(subst ://localhost,://$(_DOCKER_BRIDGE_IP),$(HTTP_PROXY)))
_HTTPS_PROXY_FOR_BUILD := $(subst ://127.0.0.1,://$(_DOCKER_BRIDGE_IP),$(subst ://localhost,://$(_DOCKER_BRIDGE_IP),$(HTTPS_PROXY)))
endif

DOCKER_OPTS ?=
ifneq ($(_HTTP_PROXY_FOR_BUILD),)
	DOCKER_OPTS += --build-arg http_proxy=$(_HTTP_PROXY_FOR_BUILD)
endif
ifneq ($(_HTTPS_PROXY_FOR_BUILD),)
	DOCKER_OPTS += --build-arg https_proxy=$(_HTTPS_PROXY_FOR_BUILD)
endif
ifneq ($(NO_PROXY),)
	DOCKER_OPTS += --build-arg no_proxy=$(NO_PROXY)
endif

_SHA := $(shell git rev-parse --short HEAD)
_SHA_DIRTY := $(shell [ -n "$$(git status --porcelain 2>/dev/null)" ] && printf -- '-dirty')
IMAGE_VERSION ?= $(_SHA)$(_SHA_DIRTY)

export IMAGE_VERSION
export MKOSI_VERSION

.DEFAULT_GOAL := all
.PHONY: all
all: podvm-binaries image

.PHONY: debug
debug: podvm-binaries image-debug

.PHONY: sftp
sftp: podvm-binaries image-sftp

.PHONY: container
container: podvm-binaries image-container

.PHONY: byom-e2e-container
byom-e2e-container: image-byom-e2e-container

DISTRO_NAME := ubuntu
DISTRO_IMAGE := ubuntu:24.04
DISTRO_RELEASE := noble
DISTRO_REPOS := --repositories=universe
PKG_INSTALL := apt-get update && apt-get install -y debian-archive-keyring

define run_mkosi_in_container
	docker run --rm --privileged \
		-v "$(shell pwd)":/workspace \
		-w /workspace \
		$(DISTRO_IMAGE) \
		bash -c "$(PKG_INSTALL) bubblewrap coreutils git python3; mkdir -p /build; git clone -b $(MKOSI_VERSION) https://github.com/systemd/mkosi /build/mkosi; export PATH="/build/mkosi/bin:$$PATH"; mkosi --tools-tree=default --tools-tree-release=$(DISTRO_RELEASE) --tools-tree-distribution=$(DISTRO_NAME) --distribution=$(DISTRO_NAME) --release=$(DISTRO_RELEASE) $(DISTRO_REPOS) $(1)"
endef

.PHONY: podvm-binaries
podvm-binaries:
	@echo "Building podvm binaries using Docker..."
	rm -rf ./resources/binaries-tree
ifeq ($(IS_DEBIAN),true)
	docker buildx use default
endif
	docker buildx build \
		-t $(PODVM_BINARIES_IMAGE) \
		--progress=plain \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg ARCH=$(ARCH) \
		--build-arg GO_ARCH=$(GO_ARCH) \
		--build-arg DISTRO_ARCH=$(DISTRO_ARCH) \
		--build-arg PROTOC_VERSION=$(PROTOC_VERSION) \
		--build-arg PROTOC_ARCH=$(PROTOC_ARCH) \
		--build-arg YQ_VERSION=$(YQ_VERSION) \
		--build-arg YQ_CHECKSUM=$(YQ_CHECKSUM_$(YQ_ARCH)) \
		--build-arg YQ_ARCH=$(YQ_ARCH) \
		--build-arg ORAS_VERSION=$(ORAS_VERSION) \
		--build-arg TEE_PLATFORM=$(TEE_PLATFORM) \
		--build-arg PAUSE_REPO=$(PAUSE_REPO) \
		--build-arg PAUSE_VERSION=$(PAUSE_VERSION) \
		--build-arg PAUSE_BIN=$(PAUSE_BIN) \
		--build-arg IMAGE_NAME=mkosi-podvm-binaries \
		--build-arg VERIFY_PROVENANCE=$(VERIFY_PROVENANCE) \
		$(if $(AUTHFILE),--build-arg AUTHFILE=$(AUTHFILE),) \
		$(if $(DEFAULT_AGENT_POLICY_FILE),--build-arg DEFAULT_AGENT_POLICY_FILE=$(DEFAULT_AGENT_POLICY_FILE),) \
		$(if $(filter $(PUSH),true),,-o type=local,dest="./resources/binaries-tree") \
		$(DOCKER_OPTS) \
		-f Dockerfile.podvm_binaries ../../

.PHONY: podvm-binaries-alinux3
podvm-binaries-alinux3:
	@echo "Building alinux3 podvm binaries overlay..."
	rm -rf ./build-alinux3/overlay
	mkdir -p ./build-alinux3/overlay
	docker buildx build \
		--progress=plain \
		--build-arg ALINUX3_BUILDER_IMAGE=$(ALINUX3_BUILDER_IMAGE) \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--build-arg ARCH=$(ARCH) \
		--build-arg GO_ARCH=$(GO_ARCH) \
		--build-arg DISTRO_ARCH=$(DISTRO_ARCH) \
		--build-arg PROTOC_VERSION=$(PROTOC_VERSION) \
		--build-arg PROTOC_ARCH=$(PROTOC_ARCH) \
		--build-arg YQ_VERSION=$(YQ_VERSION) \
		--build-arg YQ_CHECKSUM=$(YQ_CHECKSUM_$(YQ_ARCH)) \
		--build-arg YQ_ARCH=$(YQ_ARCH) \
		--build-arg ORAS_VERSION=$(ORAS_VERSION) \
		--build-arg PAUSE_REPO=$(PAUSE_REPO) \
		--build-arg PAUSE_VERSION=$(PAUSE_VERSION) \
		--build-arg PAUSE_BIN=$(PAUSE_BIN) \
		--build-arg TEE_PLATFORM=$(TEE_PLATFORM) \
		--build-arg IMAGE_NAME=alinux3-podvm-binaries \
		--build-arg VERIFY_PROVENANCE=$(VERIFY_PROVENANCE) \
		$(if $(AUTHFILE),--build-arg AUTHFILE=$(AUTHFILE),) \
		$(if $(DEFAULT_AGENT_POLICY_FILE),--build-arg DEFAULT_AGENT_POLICY_FILE=$(DEFAULT_AGENT_POLICY_FILE),) \
		$(DOCKER_OPTS) \
		-o type=local,dest=./build-alinux3/overlay \
		-f Dockerfile.podvm_alinux3_binaries \
		../..

.PHONY: image-alinux3
image-alinux3: podvm-binaries-alinux3
	@echo "Building alinux3-based Pod VM image..."
	rm -rf ./build-alinux3/output
	mkdir -p ./build-alinux3/output
	@if [ ! -f ./build-alinux3/base.qcow2 ]; then \
		curl -fsSL -o ./build-alinux3/base.qcow2 $(alinux_amd64_IMAGE_URL); \
	else \
		echo "Reusing existing ./build-alinux3/base.qcow2"; \
	fi
	if [ -n "$(alinux_amd64_IMAGE_CHECKSUM)" ]; then \
		echo "$(alinux_amd64_IMAGE_CHECKSUM)  ./build-alinux3/base.qcow2" | sha256sum -c; \
	fi
	docker build \
		-t $(PODVM_ALINUX3_CUSTOMIZER_IMAGE) \
		$(DOCKER_OPTS) \
		-f Dockerfile.podvm_alinux3_customizer \
		.
	docker run --rm --privileged \
		-v /dev:/dev \
		-v /boot:/boot:ro \
		-v /lib/modules:/lib/modules:ro \
		-v "$(shell pwd)/build-alinux3/base.qcow2:/input/base.qcow2:ro" \
		-v "$(shell pwd)/build-alinux3/overlay:/overlay:ro" \
		-v "$(shell pwd)/build-alinux3/output:/output" \
		-e "OUTPUT_NAME=podvm-alinux3-$(DISTRO_ARCH).qcow2" \
		-e "GUEST_PKGS=iptables,iproute,tpm2-tools,e2fsprogs,cryptsetup,ca-certificates" \
		$(PODVM_ALINUX3_CUSTOMIZER_IMAGE) \
		/input/base.qcow2 /output

.PHONY: podvm-alinux3-tree
podvm-alinux3-tree:
	./hack/ci-build-podvm-alinux3-tree.sh

# Re-run only the qcow2 customization step (skips binaries rebuild).
.PHONY: image-alinux3-customize
image-alinux3-customize:
	@test -f ./build-alinux3/base.qcow2 || (echo "missing build-alinux3/base.qcow2" >&2; exit 1)
	@test -d ./build-alinux3/overlay/usr || (echo "missing build-alinux3/overlay" >&2; exit 1)
	rm -rf ./build-alinux3/output
	mkdir -p ./build-alinux3/output
	docker build \
		-t $(PODVM_ALINUX3_CUSTOMIZER_IMAGE) \
		$(DOCKER_OPTS) \
		-f Dockerfile.podvm_alinux3_customizer \
		.
	docker run --rm --privileged \
		-v /dev:/dev \
		-v /boot:/boot:ro \
		-v /lib/modules:/lib/modules:ro \
		-v "$(shell pwd)/build-alinux3/base.qcow2:/input/base.qcow2:ro" \
		-v "$(shell pwd)/build-alinux3/overlay:/overlay:ro" \
		-v "$(shell pwd)/build-alinux3/output:/output" \
		-e "OUTPUT_NAME=podvm-alinux3-$(DISTRO_ARCH).qcow2" \
		-e "GUEST_PKGS=iptables,iproute,tpm2-tools,e2fsprogs,cryptsetup,ca-certificates" \
		$(PODVM_ALINUX3_CUSTOMIZER_IMAGE) \
		/input/base.qcow2 /output

PHONY: insecure-builder
insecure-builder:
	docker buildx ls | grep "^insecure-builder" || docker buildx create \
		--driver-opt image=moby/buildkit:master \
		--name insecure-builder \
		--buildkitd-flags '--allow-insecure-entitlement security.insecure'

PHONY: image
image: insecure-builder
	rm -rf ./build
	@echo "Building image..."
ifeq ($(SE_BOOT),true)
	$(call run_mkosi_in_container,--profile production)
	sudo -E ../hack/build-s390x-se-image.sh
else ifeq ($(ARCH),s390x)
	$(call run_mkosi_in_container,--profile production)
	sudo -E ../hack/build-s390x-image.sh
else
	mkdir -p build
	docker buildx build \
		-f Dockerfile.mkosi \
		-t $(PODVM_IMAGE) \
		--build-arg PROFILE=production \
		--build-arg IMAGE_VERSION \
		--build-arg MKOSI_VERSION \
		--progress=plain \
		-o type=local,dest=./build \
		--builder insecure-builder \
		--allow security.insecure \
		.
	qemu-img convert -f raw -O qcow2 build/system.raw build/podvm-ubuntu-$(DISTRO_ARCH).qcow2
endif

PHONY: image-debug
image-debug: insecure-builder
	rm -rf ./build
	@echo "Building debug image..."
ifeq ($(SE_BOOT),true)
	$(call run_mkosi_in_container,--profile debug)
	sudo -E ../hack/build-s390x-se-image.sh
else ifeq ($(ARCH),s390x)
	$(call run_mkosi_in_container,--profile debug)
	sudo -E ../hack/build-s390x-image.sh
else

	mkdir -p build
	docker buildx build \
		-f Dockerfile.mkosi \
		-t $(PODVM_IMAGE) \
		--build-arg PROFILE=debug \
		--build-arg IMAGE_VERSION \
		--build-arg MKOSI_VERSION \
		--progress=plain \
		-o type=local,dest=./build \
		--builder insecure-builder \
		--allow security.insecure \
		.
	qemu-img convert -f raw -O qcow2 build/system.raw build/podvm-ubuntu-$(DISTRO_ARCH).qcow2
endif

PHONY: image-sftp
image-sftp: insecure-builder
	rm -rf ./build
	@echo "Building sftp image..."
ifeq ($(SE_BOOT),true)
	$(call run_mkosi_in_container,--profile sftp)
	sudo -E ../hack/build-s390x-se-image.sh
else ifeq ($(ARCH),s390x)
	$(call run_mkosi_in_container,--profile sftp)
	sudo -E ../hack/build-s390x-image.sh
else
	mkdir -p build
	docker buildx build \
		-f Dockerfile.mkosi \
		-t $(PODVM_IMAGE) \
		--build-arg PROFILE=sftp \
		--build-arg IMAGE_VERSION \
		--build-arg MKOSI_VERSION \
		--progress=plain \
		-o type=local,dest=./build \
		--builder insecure-builder \
		--allow security.insecure \
		.
	qemu-img convert -f raw -O qcow2 build/system.raw build/podvm-ubuntu-$(DISTRO_ARCH).qcow2
endif

PHONY: image-container
image-container:
	@echo "Building podvm container image..."
	cd .. && docker buildx build \
		-t $(PODVM_CONTAINER_NAME):$(PODVM_TAG) \
		-t $(PODVM_CONTAINER_NAME):latest \
		-f podvm/Dockerfile.podvm_docker_provider .

.PHONY: podvm-byom-binaries-image
podvm-byom-binaries-image:
	@echo "Building BYOM binaries image..."
	docker buildx build \
		-t $(PODVM_BYOM_BINARIES_IMAGE):$(PODVM_TAG) \
		-t $(PODVM_BYOM_BINARIES_IMAGE):latest \
		--build-arg BINARIES_IMG=$(PODVM_BINARIES_IMAGE) \
		--progress=plain \
		-f Dockerfile.podvm_byom_binaries \
		$(DOCKER_OPTS) \
		..

.PHONY: image-byom-e2e-container
image-byom-e2e-container:
	@echo "Building BYOM podvm container image with SSH support..."
	docker buildx build \
		-t $(PODVM_BYOM_E2E_CONTAINER_NAME):$(PODVM_TAG) \
		-t $(PODVM_BYOM_E2E_CONTAINER_NAME):latest \
		--build-arg BASE_IMAGE=$(PODVM_CONTAINER_NAME):latest \
		-f Dockerfile.podvm_byom_docker_provider .

PHONY: push-image
push-image:
	@echo "Push podvm image to remote repository..."
ifeq ($(SE_BOOT),true)
	docker push $(PODVM_NAME)-se:$(PODVM_TAG)
	docker push $(PODVM_NAME)-se:latest
else
	docker push $(PODVM_NAME):$(PODVM_TAG)
	docker push $(PODVM_NAME):latest
endif

PHONY: push-image-container
push-image-container:
	@echo "Push podvm container image to remote repository..."
	docker push $(PODVM_CONTAINER_NAME):$(PODVM_TAG)

.PHONY: push-podvm-byom-binaries-image
push-podvm-byom-binaries-image:
	@echo "Push BYOM binaries image to remote repository..."
	docker push $(PODVM_BYOM_BINARIES_IMAGE):$(PODVM_TAG)

.PHONY: push-image-byom-e2e-container
push-image-byom-e2e-container:
	@echo "Push BYOM podvm container image to remote repository..."
	docker push $(PODVM_BYOM_E2E_CONTAINER_NAME):$(PODVM_TAG)

.PHONY: clean
clean:
	rm -rf ./build
	rm -rf ./resources/binaries-tree
	rm -rf ./build-alinux3
