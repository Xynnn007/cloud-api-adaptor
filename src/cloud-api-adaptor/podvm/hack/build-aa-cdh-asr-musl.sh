#!/usr/bin/env bash
# Build musl-static AA / CDH / ASR from inclavare-containers/guest-components.
#
# Default attesters for the private-cloud Pod VM rootfs:
#   csv-attester,hygon-dcu-attester,tdx-attester,tpm-attester
#
# Recommended host: Docker + Alpine musl image (or Ubuntu + musl-tools).
# Outputs: attestation-agent, confidential-data-hub, api-server-rest
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# repo root: .../cloud-api-adaptor (monorepo) — hack -> podvm -> cloud-api-adaptor -> src -> root
ROOT="$(cd "${HERE}/../../../.." && pwd)"
GC_DIR="${GC_DIR:-${ROOT}/work/inclavare-guest-components}"
OUT_DIR="${OUT_DIR:-${ROOT}/work/build-artifacts}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/work/build-cdh-musl}"
RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://mirrors.ustc.edu.cn/rust-static}"
RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://mirrors.ustc.edu.cn/rust-static/rustup}"

log() { printf '[build-aa-cdh-asr] %s\n' "$*"; }

# GC_REPO / GC_REF / AA_ATTESTER / ALPINE_IMAGE / RUST_VERSION from versions.yaml
# (env overrides win). Requires yq when defaults are needed.
if [[ -z "${GC_REPO:-}" || -z "${GC_REF:-}" || -z "${AA_ATTESTER:-}" || -z "${ALPINE_IMAGE:-}" || -z "${RUST_VERSION:-}" ]]; then
  if ! command -v yq >/dev/null 2>&1; then
    log "ERROR: yq required to read versions.yaml (or set GC_REPO/GC_REF/AA_ATTESTER/ALPINE_IMAGE/RUST_VERSION)"
    exit 1
  fi
  # shellcheck source=load-versions.sh
  source "${HERE}/load-versions.sh"
  load_versions
fi
: "${GC_REPO:?}"
: "${GC_REF:?}"
: "${AA_ATTESTER:?}"
: "${ALPINE_IMAGE:?}"
: "${RUST_VERSION:?}"

mkdir -p "${BUILD_DIR}/cargo-cache" "${BUILD_DIR}/rustup-cache" "${OUT_DIR}"

if [[ ! -d "${GC_DIR}/attestation-agent" ]]; then
  log "Cloning guest-components (${GC_REF}) from ${GC_REPO} -> ${GC_DIR}"
  mkdir -p "$(dirname "${GC_DIR}")"
  git clone --filter=blob:none "${GC_REPO}" "${GC_DIR}"
  git -C "${GC_DIR}" checkout "${GC_REF}"
elif [[ -n "${GC_REF}" ]]; then
  # Ensure pinned revision when directory already exists
  git -C "${GC_DIR}" fetch --depth=1 origin "${GC_REF}" 2>/dev/null || \
    git -C "${GC_DIR}" fetch origin "${GC_REF}" 2>/dev/null || true
  git -C "${GC_DIR}" checkout "${GC_REF}"
fi

# Ensure rustup-init exists for Alpine container bootstrap
RUSTUP_INIT_HOST="${BUILD_DIR}/rustup-init"
if [[ ! -x "${RUSTUP_INIT_HOST}" ]]; then
  log "Downloading rustup-init"
  curl -fsSL "${RUSTUP_DIST_SERVER}/rustup/dist/x86_64-unknown-linux-musl/rustup-init" \
    -o "${RUSTUP_INIT_HOST}"
  chmod +x "${RUSTUP_INIT_HOST}"
fi

if ! docker image inspect "${ALPINE_IMAGE}" >/dev/null 2>&1; then
  log "Pulling ${ALPINE_IMAGE}"
  docker pull "${ALPINE_IMAGE}"
fi

# Pin toolchain so Alpine musl host does not pick a broken cargo
TOOLCHAIN_BAK=""
if [[ -f "${GC_DIR}/rust-toolchain.toml" ]]; then
  TOOLCHAIN_BAK="${GC_DIR}/rust-toolchain.toml.bak.$$"
  cp -a "${GC_DIR}/rust-toolchain.toml" "${TOOLCHAIN_BAK}"
  cat > "${GC_DIR}/rust-toolchain.toml" <<EOF
[toolchain]
channel = "${RUST_VERSION}"
components = ["clippy", "rustfmt"]
profile = "minimal"
EOF
  trap '[[ -n "${TOOLCHAIN_BAK}" ]] && mv -f "${TOOLCHAIN_BAK}" "${GC_DIR}/rust-toolchain.toml" 2>/dev/null || true' EXIT
fi

log "Alpine musl-native build, toolchain=${RUST_VERSION}, ATTESTER=${AA_ATTESTER}"

docker run --rm --network=host \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  -e no_proxy="${no_proxy:-}" -e NO_PROXY="${NO_PROXY:-}" \
  -e RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER}" \
  -e RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT}" \
  -e CARGO_HOME=/cargo \
  -e RUSTUP_HOME=/rustup \
  -e RUSTUP_TOOLCHAIN="${RUST_VERSION}-x86_64-unknown-linux-musl" \
  -e AA_ATTESTER="${AA_ATTESTER}" \
  -e RUST_VERSION="${RUST_VERSION}" \
  -v "${GC_DIR}:/src:rw" \
  -v "${BUILD_DIR}/cargo-cache:/cargo:rw" \
  -v "${BUILD_DIR}/rustup-cache:/rustup:rw" \
  -v "${RUSTUP_INIT_HOST}:/opt/rustup-init:ro" \
  -v "${OUT_DIR}:/out:rw" \
  -w /src \
  "${ALPINE_IMAGE}" \
  sh -c '
set -euo pipefail

if [ -f /etc/apk/repositories ]; then
  sed -i "s#https\\?://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g" /etc/apk/repositories || true
fi
apk update
apk add --no-cache \
  build-base curl ca-certificates protobuf protobuf-dev \
  openssl-dev openssl-libs-static linux-headers pkgconfig perl make git file \
  clang clang-dev llvm-dev tpm2-tss-dev

export PATH="${CARGO_HOME:-/cargo}/bin:${RUSTUP_HOME:-/rustup}/bin:${PATH}"
TOOLCHAIN="${RUST_VERSION}-x86_64-unknown-linux-musl"

if [ ! -x "/rustup/toolchains/${TOOLCHAIN}/bin/cargo" ]; then
  cp /opt/rustup-init /tmp/rustup-init && chmod +x /tmp/rustup-init
  /tmp/rustup-init -y --default-host x86_64-unknown-linux-musl \
    --default-toolchain "${RUST_VERSION}" --profile minimal --no-modify-path
fi
export PATH="/rustup/toolchains/${TOOLCHAIN}/bin:${CARGO_HOME}/bin:${PATH}"
rustup default "${TOOLCHAIN}" || true
rustup target add x86_64-unknown-linux-musl || true
export PATH="/rustup/toolchains/${TOOLCHAIN}/bin:${PATH}"
rustc --version
cargo --version

export OPENSSL_DIR=/usr
export OPENSSL_LIB_DIR=/usr/lib
export OPENSSL_INCLUDE_DIR=/usr/include
export OPENSSL_STATIC=1
export PKG_CONFIG_PATH=/usr/lib/pkgconfig
export PKG_CONFIG_ALLOW_CROSS=1

TARGET=x86_64-unknown-linux-musl

echo "== Building attestation-agent (ATTESTER=${AA_ATTESTER}) =="
cd /src
cargo build -p attestation-agent --release --bin ttrpc-aa \
  --no-default-features \
  --features "bin,ttrpc,rust-crypto,coco_as,kbs,${AA_ATTESTER}" \
  --target ${TARGET}
install -D -m0755 "target/${TARGET}/release/ttrpc-aa" /out/attestation-agent
file /out/attestation-agent

echo "== Building confidential-data-hub =="
cd /src
if cargo build -p confidential-data-hub --release --bin ttrpc-cdh \
    --no-default-features --features "bin,ttrpc,kbs,aliyun,resource_injection" \
    --target ${TARGET}; then
  SRC_BIN="target/${TARGET}/release/ttrpc-cdh"
else
  cd /src/confidential-data-hub
  make build LIBC=musl ARCH=x86_64 RESOURCE_PROVIDER=kbs KMS_PROVIDER=aliyun RPC=ttrpc
  SRC_BIN="/src/target/${TARGET}/release/confidential-data-hub"
  if [ ! -f "${SRC_BIN}" ]; then
    SRC_BIN="/src/target/${TARGET}/release/ttrpc-cdh"
  fi
fi
install -D -m0755 "${SRC_BIN}" /out/confidential-data-hub
file /out/confidential-data-hub

echo "== Building api-server-rest =="
cd /src
cargo build -p api-server-rest --release --target ${TARGET}
install -D -m0755 "target/${TARGET}/release/api-server-rest" /out/api-server-rest
file /out/api-server-rest

echo "== SUCCESS =="
ls -lh /out/attestation-agent /out/confidential-data-hub /out/api-server-rest
'

log "Artifacts:"
ls -lh "${OUT_DIR}/attestation-agent" "${OUT_DIR}/confidential-data-hub" "${OUT_DIR}/api-server-rest"
file "${OUT_DIR}/attestation-agent" "${OUT_DIR}/confidential-data-hub" "${OUT_DIR}/api-server-rest"
