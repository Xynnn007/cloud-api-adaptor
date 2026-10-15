#!/usr/bin/env bash
# Assemble Pod VM overlay directory tree for alinux3 (work/podvm-alinux3-tree layout).
#
# Copies systemd units/configs from podvm/files + binaries from OUT_DIR/ART_DIR,
# enables the private-cloud unit set under multi-user.target.wants, and forces
# pause_bundle/** mode 0777.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../.." && pwd)"
FILES="${FILES:-${ROOT}/src/cloud-api-adaptor/podvm/files}"
ART="${ART:-${ROOT}/work/build-artifacts}"
DEST="${DEST:-${ROOT}/work/podvm-alinux3-tree}"
PAUSE_SRC="${PAUSE_SRC:-}"

log() { printf '[assemble] %s\n' "$*"; }

need() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    log "ERROR: missing artifact: $f"
    exit 1
  fi
}

need "${ART}/agent-protocol-forwarder"
need "${ART}/process-user-data"
need "${ART}/kata-agent"
need "${ART}/attestation-agent"
need "${ART}/confidential-data-hub"
need "${ART}/api-server-rest"

rm -rf "${DEST}"
mkdir -p "${DEST}"

log "Copying files/ overlay"
cp -a "${FILES}/." "${DEST}/"

install -D -m0755 "${ART}/agent-protocol-forwarder" "${DEST}/usr/local/bin/agent-protocol-forwarder"
install -D -m0755 "${ART}/process-user-data" "${DEST}/usr/local/bin/process-user-data"
install -D -m0755 "${ART}/kata-agent" "${DEST}/usr/local/bin/kata-agent"
install -D -m0755 "${ART}/attestation-agent" "${DEST}/usr/local/bin/attestation-agent"
install -D -m0755 "${ART}/confidential-data-hub" "${DEST}/usr/local/bin/confidential-data-hub"
install -D -m0755 "${ART}/api-server-rest" "${DEST}/usr/local/bin/api-server-rest"
ln -sfn api-server-rest "${DEST}/usr/local/bin/trustiflux-api-server"

# pause_bundle: prefer explicit PAUSE_SRC, then ART/pause_bundle, then existing DEST/files
if [[ -n "${PAUSE_SRC}" && -d "${PAUSE_SRC}" ]]; then
  rm -rf "${DEST}/pause_bundle"
  cp -a "${PAUSE_SRC}" "${DEST}/pause_bundle"
  log "Copied pause_bundle from ${PAUSE_SRC}"
elif [[ -d "${ART}/pause_bundle" ]]; then
  rm -rf "${DEST}/pause_bundle"
  cp -a "${ART}/pause_bundle" "${DEST}/pause_bundle"
  log "Copied pause_bundle from ${ART}/pause_bundle"
elif [[ -d "${DEST}/pause_bundle" ]]; then
  log "Using pause_bundle already present under files/"
else
  log "ERROR: pause_bundle missing (set PAUSE_SRC= or place under ${ART}/pause_bundle)"
  exit 1
fi

# Required: entire pause_bundle tree is 0777
chmod -R 0777 "${DEST}/pause_bundle"
log "Set pause_bundle/** mode 0777"

# TDX/TPM runtime libs from alinux3 RPMs (trustiflux.spec Requires):
#   tpm2-tss libtdx-attest tee-primitives
# Produced by hack/extract-tdx-tpm-runtime.sh -> ART/tdx-tpm-runtime/
TDX_TPM_RUNTIME="${TDX_TPM_RUNTIME:-${ART}/tdx-tpm-runtime}"
if [[ -d "${TDX_TPM_RUNTIME}/usr" || -d "${TDX_TPM_RUNTIME}/etc" ]]; then
  log "Merging TDX/TPM runtime from ${TDX_TPM_RUNTIME}"
  if [[ -d "${TDX_TPM_RUNTIME}/usr" ]]; then
    mkdir -p "${DEST}/usr"
    cp -a "${TDX_TPM_RUNTIME}/usr/." "${DEST}/usr/"
  fi
  if [[ -d "${TDX_TPM_RUNTIME}/etc" ]]; then
    mkdir -p "${DEST}/etc"
    cp -a "${TDX_TPM_RUNTIME}/etc/." "${DEST}/etc/"
  fi
  if [[ -d "${TDX_TPM_RUNTIME}/lib64" ]]; then
    mkdir -p "${DEST}/lib64"
    cp -a "${TDX_TPM_RUNTIME}/lib64/." "${DEST}/lib64/"
  fi
else
  log "ERROR: missing TDX/TPM runtime staging dir: ${TDX_TPM_RUNTIME}"
  log "       run: ./hack/extract-tdx-tpm-runtime.sh"
  exit 1
fi

# Guest helper
cp -a "${HERE}/guest-setup.sh" "${DEST}/guest-setup.sh"
chmod 0755 "${DEST}/guest-setup.sh"

# Enable units via multi-user.target.wants.
WANTS="${DEST}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${WANTS}"
# Drop any stale wants from files/
find "${WANTS}" -mindepth 1 -maxdepth 1 -exec rm -f {} +

enable_link() {
  local unit="$1"
  ln -sfn "../${unit}" "${WANTS}/${unit}"
}

enable_link "process-user-data.service"
enable_link "setup-nat-for-imds.service"
enable_link "scratch-storage.service"
enable_link "agent-protocol-forwarder.service"
enable_link "attestation-agent.path"
enable_link "confidential-data-hub.path"
enable_link "kata-agent.path"
enable_link "api-server-rest.path"
ln -sfn '../run-kata\x2dcontainers.mount' "${WANTS}/run-kata\\x2dcontainers.mount"

# --- validate systemd + ASR config entrypoint ---
UNIT_DIR="${DEST}/etc/systemd/system"
REQUIRED_UNITS=(
  process-user-data.service
  setup-nat-for-imds.service
  scratch-storage.service
  agent-protocol-forwarder.service
  attestation-agent.path
  attestation-agent.service
  confidential-data-hub.path
  confidential-data-hub.service
  kata-agent.path
  kata-agent.service
  api-server-rest.path
  api-server-rest.service
  netns@.service
)
for u in "${REQUIRED_UNITS[@]}"; do
  [[ -f "${UNIT_DIR}/${u}" ]] || { log "ERROR: missing unit ${u}"; exit 1; }
done
# escaped mount unit
[[ -e "${UNIT_DIR}/run-kata\\x2dcontainers.mount" ]] || \
  [[ -e "${UNIT_DIR}/run-kata\x2dcontainers.mount" ]] || {
  log "ERROR: missing run-kata\\x2dcontainers.mount"; exit 1;
}

# wants must resolve to real unit files
REQUIRED_WANTS=(
  process-user-data.service
  setup-nat-for-imds.service
  scratch-storage.service
  agent-protocol-forwarder.service
  attestation-agent.path
  confidential-data-hub.path
  kata-agent.path
  api-server-rest.path
)
for w in "${REQUIRED_WANTS[@]}"; do
  [[ -L "${WANTS}/${w}" ]] || { log "ERROR: missing wants link ${w}"; exit 1; }
  [[ -e "${UNIT_DIR}/${w}" ]] || { log "ERROR: wants target missing for ${w}"; exit 1; }
done
MOUNT_WANT="${WANTS}/run-kata\\x2dcontainers.mount"
[[ -L "${MOUNT_WANT}" ]] || { log "ERROR: missing wants link run-kata\\x2dcontainers.mount"; exit 1; }

ASR_UNIT="${UNIT_DIR}/api-server-rest.service"
if ! grep -q -- '--config /etc/trustiflux/trustiflux-api-server.toml' "${ASR_UNIT}"; then
  log "ERROR: api-server-rest.service must use --config /etc/trustiflux/trustiflux-api-server.toml"
  exit 1
fi
[[ -f "${DEST}/etc/trustiflux/trustiflux-api-server.toml" ]] || {
  log "ERROR: missing ASR config etc/trustiflux/trustiflux-api-server.toml"
  exit 1
}

# pause mode check
bad_mode="$(find "${DEST}/pause_bundle" ! -perm 0777 -printf '%m %p\n' | head -5 || true)"
if [[ -n "${bad_mode}" ]]; then
  log "ERROR: pause_bundle entries not 0777:"
  printf '%s\n' "${bad_mode}"
  exit 1
fi

# TDX/TPM runtime presence
[[ -e "${DEST}/usr/lib64/libtdx_attest.so" || -e "${DEST}/usr/lib64/libtdx_attest.so.1" ]] || {
  log "ERROR: missing usr/lib64/libtdx_attest.so*"
  exit 1
}
[[ -e "${DEST}/usr/lib64/libtss2-esys.so.0" || -e "${DEST}/usr/lib64/libtss2-esys.so.0.0.0" ]] || {
  log "ERROR: missing usr/lib64/libtss2-esys.so*"
  exit 1
}

{
  echo "# Pod VM alinux3 overlay tree"
  echo "# Generated: $(date -Is)"
  echo "# AA_ATTESTER=${AA_ATTESTER:-unknown}"
  echo "# TDX/TPM runtime: ${RUNTIME_PKGS:-unknown} (alinux3 RPMs)"
  echo
  echo "## Binaries"
  for b in agent-protocol-forwarder process-user-data kata-agent attestation-agent confidential-data-hub api-server-rest; do
    f="${DEST}/usr/local/bin/${b}"
    printf '%s\t%s\t' "$b" "$(file -b "$f" 2>/dev/null || echo '?')"
    ls -lh "$f" | awk '{print $5}'
  done
  echo
  echo "## systemd wants"
  ls -1 "${WANTS}"
  echo
  echo "## TDX/TPM runtime libs"
  find "${DEST}/usr/lib64" \( -name 'libtdx_attest.so*' -o -name 'libtss2*.so*' \) | sort
  echo
  echo "## pause_bundle modes (sample)"
  find "${DEST}/pause_bundle" -printf '%m %p\n' | head -20
} > "${DEST}/MANIFEST.txt"

log "Assembled -> ${DEST}"
du -sh "${DEST}" "${DEST}"/* 2>/dev/null || true
