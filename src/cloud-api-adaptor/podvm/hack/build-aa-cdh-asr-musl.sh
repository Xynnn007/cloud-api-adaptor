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

log() { printf '[build-aa-cdh-asr] %s\n' "$*"; }

export GIT_TERMINAL_PROMPT=0

# GitHub-hosted runners reach upstream reliably. Local builds keep China mirrors.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  USE_CN_MIRROR="${USE_CN_MIRROR:-0}"
else
  USE_CN_MIRROR="${USE_CN_MIRROR:-1}"
fi
if [[ "${USE_CN_MIRROR}" == "1" ]]; then
  RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://mirrors.ustc.edu.cn/rust-static}"
  RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://mirrors.ustc.edu.cn/rust-static/rustup}"
else
  RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://static.rust-lang.org}"
  RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://static.rust-lang.org/rustup}"
fi

docker_pull() {
  local image="$1" attempt
  for attempt in 1 2 3; do
    if docker pull "${image}"; then
      return 0
    fi
    log "docker pull attempt ${attempt}/3 failed: ${image}"
    sleep $((attempt * 5))
  done
  log "ERROR: docker pull failed: ${image}"
  return 1
}

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

if [[ ! -d "${GC_DIR}/.git" ]]; then
  log "Cloning guest-components (${GC_REF}) from ${GC_REPO} -> ${GC_DIR}"
  mkdir -p "$(dirname "${GC_DIR}")"
  git clone --filter=blob:none --no-checkout "${GC_REPO}" "${GC_DIR}"
fi
git -C "${GC_DIR}" fetch --depth=1 origin "${GC_REF}" \
  || git -C "${GC_DIR}" fetch origin "${GC_REF}" \
  || git -C "${GC_DIR}" fetch origin
git -C "${GC_DIR}" checkout "${GC_REF}"

# Ensure rustup-init exists for Alpine container bootstrap.
# The container is musl, so the installer itself must be a musl binary.
RUSTUP_INIT_HOST="${BUILD_DIR}/rustup-init"
if [[ ! -x "${RUSTUP_INIT_HOST}" ]]; then
  log "Downloading rustup-init"
  rustup_urls=(
    "${RUSTUP_DIST_SERVER}/rustup/dist/x86_64-unknown-linux-musl/rustup-init"
    "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-musl/rustup-init"
    "https://mirrors.ustc.edu.cn/rust-static/rustup/dist/x86_64-unknown-linux-musl/rustup-init"
  )
  rustup_ok=0
  for rustup_url in "${rustup_urls[@]}"; do
    log "Trying ${rustup_url}"
    if curl -fL --retry 3 --retry-delay 2 "${rustup_url}" -o "${RUSTUP_INIT_HOST}.tmp"; then
      mv -f "${RUSTUP_INIT_HOST}.tmp" "${RUSTUP_INIT_HOST}"
      chmod +x "${RUSTUP_INIT_HOST}"
      rustup_ok=1
      break
    fi
    rm -f "${RUSTUP_INIT_HOST}.tmp"
  done
  if [[ "${rustup_ok}" -ne 1 ]]; then
    log "ERROR: failed to download rustup-init"
    exit 1
  fi
fi

if ! docker image inspect "${ALPINE_IMAGE}" >/dev/null 2>&1; then
  log "Pulling ${ALPINE_IMAGE}"
  docker_pull "${ALPINE_IMAGE}"
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

docker run --rm --network=host --entrypoint sh \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  -e no_proxy="${no_proxy:-}" -e NO_PROXY="${NO_PROXY:-}" \
  -e RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER}" \
  -e RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT}" \
  -e USE_CN_MIRROR="${USE_CN_MIRROR}" \
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
  -c '
set -euo pipefail

if [ "${USE_CN_MIRROR:-0}" = "1" ] && [ -f /etc/apk/repositories ]; then
  sed -i "s#https\\?://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g" /etc/apk/repositories || true
fi
apk update
apk add --no-cache \
  build-base curl ca-certificates protobuf protobuf-dev \
  openssl-dev openssl-libs-static linux-headers pkgconfig perl make git file \
  clang clang-dev llvm-dev tpm2-tss-dev tpm2-tss-static

# bindgen (tdx-attest-sys) looks for libclang.so, which Alpine ships versioned.
if [ ! -e /usr/lib/libclang.so ]; then
  clang_so=$(ls /usr/lib/libclang.so.* 2>/dev/null | head -n 1 || true)
  if [ -n "${clang_so}" ]; then
    ln -s "${clang_so}" /usr/lib/libclang.so
  fi
fi
export LIBCLANG_PATH=/usr/lib

# tdx-attester links libtdx_attest and bindgen needs tdx_attest.h. The Intel
# RPM is a glibc shared library, which cannot be linked into a musl static
# binary, so build a musl static archive from the DCAP sources cargo pins.
build_libtdx_attest() {
  echo "== Building static musl libtdx_attest =="
  td_src=/tmp/dcap-src
  rm -rf "${td_src}"
  cloned=0
  attempt=1
  while [ "${attempt}" -le 3 ]; do
    if git clone --depth 1 --branch DCAP_1.22 \
      https://github.com/intel/SGXDataCenterAttestationPrimitives.git "${td_src}"; then
      cloned=1
      break
    fi
    rm -rf "${td_src}"
    echo "git clone DCAP_1.22 failed (${attempt}/3)"
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
  done
  [ "${cloned}" = "1" ]
  qw="${td_src}/QuoteGeneration/quote_wrapper"
  # -fno-exceptions/-fno-rtti keep the C++ objects from pulling libstdc++.
  make -C "${qw}/qgs_msg_lib/linux" \
    CXXFLAGS="-std=c++14 -O2 -fPIC -fno-exceptions -fno-rtti -ffunction-sections -fdata-sections"
  cc -c -O2 -fPIC \
    -I"${qw}/tdx_attest" \
    -I"${qw}/qgs_msg_lib/inc" \
    "${qw}/tdx_attest/tdx_attest.c" \
    -o /tmp/tdx_attest.o
  rm -rf /tmp/tdxlib
  mkdir -p /tmp/tdxlib
  ( cd /tmp/tdxlib && ar x "${qw}/qgs_msg_lib/linux/libqgs_msg.a" )
  qgs_obj=$(find /tmp/tdxlib -maxdepth 1 -type f -name '*.o' | head -n 1)
  [ -n "${qgs_obj}" ]
  # tdx_attest.o must come first so a single-pass link pulls qgs_msg next.
  ar rcs /usr/lib/libtdx_attest.a /tmp/tdx_attest.o "${qgs_obj}"
  install -D -m0644 "${qw}/tdx_attest/tdx_attest.h" /usr/include/tdx_attest.h
  rm -rf "${td_src}" /tmp/tdxlib /tmp/tdx_attest.o
}

case ",${AA_ATTESTER}," in
  *,tdx-attester,*) build_libtdx_attest ;;
esac

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
