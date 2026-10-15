#!/usr/bin/env bash
# CI / local entrypoint: build the alinux3 Pod VM rootfs overlay tree
# (same layout as work/podvm-alinux3-tree), validate systemd + pause_bundle 0777,
# and pack a tarball for CI artifacts or a GitHub Release.
#
# Prerequisites: docker, git, curl, make; go/yq/rust auto-bootstrap when missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../.." && pwd)"
CAA="${ROOT}/src/cloud-api-adaptor"
PODVM="${CAA}/podvm"
ART="${ART:-${ROOT}/work/build-artifacts}"
DEST="${DEST:-${ROOT}/work/podvm-alinux3-tree}"
OUT_TGZ="${OUT_TGZ:-${ROOT}/_output/podvm-alinux3-tree.tar.gz}"
TOOLS_DIR="${TOOLS_DIR:-${ROOT}/work/tools}"
KATA_SRC="${KATA_SRC:-${ROOT}/work/kata-containers}"
# Repo URL / rev / pause / AA attesters loaded from versions.yaml after ensure_yq
# (override any with env: KATA_REPO_URL, KATA_REF, GC_REPO, GC_REF, AA_ATTESTER, ...)
SKIP_AA_BUILD="${SKIP_AA_BUILD:-0}"
SKIP_KATA_BUILD="${SKIP_KATA_BUILD:-0}"
SKIP_GO_BUILD="${SKIP_GO_BUILD:-0}"
SKIP_PAUSE="${SKIP_PAUSE:-0}"
SKIP_TDX_TPM_RUNTIME="${SKIP_TDX_TPM_RUNTIME:-0}"

log() { printf '[ci-podvm-tree] %s\n' "$*"; }

host_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    s390x) echo s390x ;;
    *) echo amd64 ;;
  esac
}

# Install the pinned Go version into TOOLS_DIR when the host has no Go.
ensure_go() {
  if command -v go >/dev/null 2>&1; then
    log "go: $(command -v go) ($(go version 2>/dev/null || true))"
    return 0
  fi
  if [[ -x "${TOOLS_DIR}/go/bin/go" ]]; then
    export PATH="${TOOLS_DIR}/go/bin:${PATH}"
    log "go: ${TOOLS_DIR}/go/bin/go ($(go version))"
    return 0
  fi
  if [[ -x /usr/local/go/bin/go ]]; then
    export PATH="/usr/local/go/bin:${PATH}"
    log "go: /usr/local/go/bin/go ($(go version))"
    return 0
  fi

  local arch ver tarball
  arch="$(host_go_arch)"
  ver="${GO_VERSION}"
  tarball="${TOOLS_DIR}/go${ver}.linux-${arch}.tar.gz"
  mkdir -p "${TOOLS_DIR}"

  local urls=(
    "https://golang.google.cn/dl/go${ver}.linux-${arch}.tar.gz"
    "https://mirrors.aliyun.com/golang/go${ver}.linux-${arch}.tar.gz"
    "https://go.dev/dl/go${ver}.linux-${arch}.tar.gz"
  )
  local url downloaded=0
  for url in "${urls[@]}"; do
    log "Downloading Go ${ver} from ${url}"
    if curl -fsSL --retry 3 --retry-delay 2 -o "${tarball}" "${url}"; then
      local size
      size="$(stat -c%s "${tarball}" 2>/dev/null || echo 0)"
      if [[ "${size}" -gt 50000000 ]]; then
        downloaded=1
        break
      fi
      log "download too small (${size} bytes), try next mirror"
      rm -f "${tarball}"
    fi
  done
  if [[ "${downloaded}" -ne 1 ]]; then
    log "ERROR: failed to download Go ${ver}"
    exit 1
  fi

  log "Extracting Go to ${TOOLS_DIR}/go"
  rm -rf "${TOOLS_DIR}/go"
  tar -C "${TOOLS_DIR}" -xzf "${tarball}"
  rm -f "${tarball}"
  export PATH="${TOOLS_DIR}/go/bin:${PATH}"
  go version
}

# Makefile.defaults requires yq v4 to parse versions.yaml.
ensure_yq() {
  if command -v yq >/dev/null 2>&1; then
    log "yq: $(command -v yq) ($(yq --version 2>/dev/null || true))"
    return 0
  fi
  local ver="${YQ_VERSION:-v4.35.1}"
  local arch dest url
  arch="$(host_go_arch)"
  mkdir -p "${TOOLS_DIR}"
  dest="${TOOLS_DIR}/yq"
  local urls=(
    "https://github.com/mikefarah/yq/releases/download/${ver}/yq_linux_${arch}"
    "https://mirror.ghproxy.com/https://github.com/mikefarah/yq/releases/download/${ver}/yq_linux_${arch}"
    "https://ghfast.top/https://github.com/mikefarah/yq/releases/download/${ver}/yq_linux_${arch}"
  )
  for url in "${urls[@]}"; do
    log "Installing yq ${ver} from ${url}"
    if curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.tmp" "${url}"; then
      mv -f "${dest}.tmp" "${dest}"
      chmod +x "${dest}"
      export PATH="${TOOLS_DIR}:${PATH}"
      yq --version
      return 0
    fi
    rm -f "${dest}.tmp"
  done

  if command -v go >/dev/null 2>&1; then
    log "Installing yq via go install (${ver})"
    export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
    GOBIN="${TOOLS_DIR}" go install "github.com/mikefarah/yq/v4@${ver}"
    export PATH="${TOOLS_DIR}:${PATH}"
    yq --version
    return 0
  fi

  log "ERROR: failed to install yq ${ver} (curl mirrors and go install all failed)"
  exit 1
}

mkdir -p "${ART}" "$(dirname "${OUT_TGZ}")"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export CGO_ENABLED=0
ensure_yq

# shellcheck source=load-versions.sh
source "${PODVM}/hack/load-versions.sh"
load_versions
ensure_go

# --- Go peerpods binaries ---
if [[ "${SKIP_GO_BUILD}" != "1" ]]; then
  log "Building agent-protocol-forwarder + process-user-data"
  make -C "${CAA}" agent-protocol-forwarder process-user-data
  install -D -m0755 "${CAA}/agent-protocol-forwarder" "${ART}/agent-protocol-forwarder"
  install -D -m0755 "${CAA}/process-user-data" "${ART}/process-user-data"
else
  log "SKIP_GO_BUILD=1"
fi

# --- kata-agent musl ---
if [[ "${SKIP_KATA_BUILD}" != "1" ]]; then
  if [[ ! -d "${KATA_SRC}/.git" ]]; then
    log "Cloning kata-containers ${KATA_REF} from ${KATA_REPO_URL}"
    mkdir -p "$(dirname "${KATA_SRC}")"
    git clone --filter=blob:none "${KATA_REPO_URL}" "${KATA_SRC}"
  fi
  # Prefer fetching the pinned commit; fall back to full fetch if shallow fails
  git -C "${KATA_SRC}" fetch --depth=1 origin "${KATA_REF}" || \
    git -C "${KATA_SRC}" fetch origin "${KATA_REF}" || \
    git -C "${KATA_SRC}" fetch origin
  git -C "${KATA_SRC}" checkout "${KATA_REF}"
  log "Building kata-agent (musl)"
  "${PODVM}/hack/build-kata-agent-musl.sh" "${KATA_SRC}" "${ART}/kata-agent"
else
  log "SKIP_KATA_BUILD=1"
fi

# --- AA / CDH / ASR musl (inclavare) ---
if [[ "${SKIP_AA_BUILD}" != "1" ]]; then
  log "Building AA/CDH/ASR with ATTESTER=${AA_ATTESTER}"
  # Pass through pins from versions.yaml; build script also reloads defaults
  AA_ATTESTER="${AA_ATTESTER}" GC_REPO="${GC_REPO}" GC_REF="${GC_REF}" \
  ALPINE_IMAGE="${ALPINE_IMAGE:-}" RUST_VERSION="${RUST_VERSION:-}" \
  OUT_DIR="${ART}" \
    "${PODVM}/hack/build-aa-cdh-asr-musl.sh"
else
  log "SKIP_AA_BUILD=1"
fi

# --- TDX/TPM runtime libs (alinux3 RPMs from versions.yaml) ---
if [[ "${SKIP_TDX_TPM_RUNTIME}" != "1" ]]; then
  log "Extracting TDX/TPM runtime from alinux3 container"
  OUT_DIR="${ART}/tdx-tpm-runtime" \
  RUNTIME_PKGS="${RUNTIME_PKGS:-}" \
  ALINUX3_IMAGE="${ALINUX3_IMAGE}" \
    "${PODVM}/hack/extract-tdx-tpm-runtime.sh"
else
  log "SKIP_TDX_TPM_RUNTIME=1"
fi

# --- pause_bundle ---
PAUSE_DIR="${ART}/pause_bundle"
if [[ "${SKIP_PAUSE}" != "1" ]]; then
  log "Fetching pause ${PAUSE_REPO}:${PAUSE_VERSION}"
  rm -rf "${ART}/pause-oci" "${PAUSE_DIR}"
  mkdir -p "${ART}/pause-oci"
  if command -v skopeo >/dev/null 2>&1 && command -v umoci >/dev/null 2>&1; then
    skopeo copy "docker://${PAUSE_REPO}:${PAUSE_VERSION}" "oci:${ART}/pause-oci:${PAUSE_VERSION}"
    umoci unpack --rootless --image "${ART}/pause-oci:${PAUSE_VERSION}" "${PAUSE_DIR}"
  else
    # Docker-based fallback: extract pause binary into a minimal OCI-like bundle
    log "skopeo/umoci missing; using docker to materialize pause_bundle"
    cid="$(docker create "${PAUSE_REPO}:${PAUSE_VERSION}")"
    mkdir -p "${PAUSE_DIR}/rootfs"
    docker export "${cid}" | tar -C "${PAUSE_DIR}/rootfs" -xf -
    docker rm "${cid}" >/dev/null
    # Minimal config.json so the tree is recognizable; kata mainly needs rootfs/pause
    cat > "${PAUSE_DIR}/config.json" <<'EOF'
{
  "ociVersion": "1.0.2",
  "process": {
    "user": { "uid": 0, "gid": 0 },
    "args": ["/pause"],
    "cwd": "/"
  },
  "root": { "path": "rootfs" }
}
EOF
  fi
  chmod -R 0777 "${PAUSE_DIR}"
else
  log "SKIP_PAUSE=1"
fi

# --- assemble + validate ---
ART="${ART}" DEST="${DEST}" PAUSE_SRC="${PAUSE_DIR}" \
  "${PODVM}/hack/assemble-podvm-alinux3-tree.sh"

# --- reproducible tarball ---
log "Packing ${OUT_TGZ}"
rm -f "${OUT_TGZ}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${ROOT}" show -s --format=%ct HEAD)}"
tar -C "$(dirname "${DEST}")" \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 --group=0 --numeric-owner \
  -czf "${OUT_TGZ}" "$(basename "${DEST}")"

log "DONE"
ls -lh "${OUT_TGZ}"
log "Tree: ${DEST}"
log "AA attesters: ${AA_ATTESTER}"
