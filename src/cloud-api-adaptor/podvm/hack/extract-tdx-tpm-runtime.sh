#!/usr/bin/env bash
# Extract alinux3 runtime libs required by trustiflux AA (TDX/TPM) into a staging
# directory that can be merged into the Pod VM overlay tree.
#
# Packages (from trustiflux.spec Requires):
#   https://github.com/inclavare-containers/guest-components/blob/main/trustiflux.spec
#   Requires: tpm2-tss libtdx-attest tee-primitives
#
# Method: start an alinux3 container, yum install the RPMs, copy payload files out.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT}/work/build-artifacts/tdx-tpm-runtime}"

log() { printf '[tdx-tpm-runtime] %s\n' "$*"; }

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

# Prefer values from the environment, otherwise load the unified versions file.
if [[ -z "${RUNTIME_PKGS:-}" || -z "${ALINUX3_IMAGE:-}" ]]; then
  if command -v yq >/dev/null 2>&1; then
    # shellcheck source=load-versions.sh
    source "${HERE}/load-versions.sh"
    load_versions
  fi
fi
: "${RUNTIME_PKGS:?RUNTIME_PKGS is missing from versions.yaml}"
: "${ALINUX3_IMAGE:?ALINUX3_IMAGE is missing from versions.yaml}"
# Allow comma-separated form from older configs
RUNTIME_PKGS="${RUNTIME_PKGS//,/ }"

mkdir -p "$(dirname "${OUT_DIR}")"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

if ! docker image inspect "${ALINUX3_IMAGE}" >/dev/null 2>&1; then
  log "Pulling ${ALINUX3_IMAGE}"
  docker_pull "${ALINUX3_IMAGE}"
fi

INNER="$(mktemp)"
trap 'rm -f "${INNER}"' EXIT
cat > "${INNER}" <<'INNER'
#!/bin/bash
set -euo pipefail

PKGS="${RUNTIME_PKGS}"
echo "== yum install: ${PKGS} =="
yum install -y ca-certificates curl tar gzip yum-utils

# libtdx-attest is not in the alinux3 base repos. It is published in Intel's
# Anolis 8 SGX DCAP repo, which is ABI-compatible with alinux3 (RHEL 8).
# tee-primitives is a license-only stub and is absent from public repos.
base_pkgs=""
dcap_pkgs=""
optional_pkgs=""
for p in ${PKGS}; do
  case "${p}" in
    libtdx-attest|libtdx-attest-devel) dcap_pkgs="${dcap_pkgs} ${p}" ;;
    tee-primitives) optional_pkgs="${optional_pkgs} ${p}" ;;
    *) base_pkgs="${base_pkgs} ${p}" ;;
  esac
done

if [ -n "${base_pkgs}" ]; then
  # shellcheck disable=SC2086
  yum install -y ${base_pkgs}
fi

if [ -n "${dcap_pkgs}" ]; then
  curl -fL --retry 3 --retry-delay 2 \
    -o /tmp/sgx_rpm_local_repo.tgz \
    https://download.01.org/intel-sgx/sgx-dcap/1.21/linux/distro/Anolis86/sgx_rpm_local_repo.tgz
  rm -rf /tmp/sgx_rpm_local_repo
  tar -C /tmp -xzf /tmp/sgx_rpm_local_repo.tgz
  yum-config-manager --add-repo file:///tmp/sgx_rpm_local_repo
  # shellcheck disable=SC2086
  yum install -y --nogpgcheck --setopt=install_weak_deps=False ${dcap_pkgs}
fi

for p in ${optional_pkgs}; do
  if ! yum install -y "${p}"; then
    echo "WARN: optional package ${p} is not in the configured repos; continuing"
  fi
done

LIST=/tmp/runtime-files.txt
: > "${LIST}"
for p in ${PKGS}; do
  if ! rpm -q "$p" >/dev/null 2>&1; then
    echo "WARN: ${p} is not installed; skipping its file list"
    continue
  fi
  rpm -ql "$p" >> "${LIST}"
done

# Payload for overlay: libs, configs, udev rules. Skip docs/devel/build-id.
grep -E '^/(usr/lib64|usr/lib/udev|lib64|lib/udev|etc)' "${LIST}" \
  | grep -Ev '/(\.build-id|man|doc|licenses|include|pkgconfig)/' \
  | grep -Ev '\.(h|pc|a)$' \
  | sort -u > /tmp/copy-list.txt

mkdir -p /out
while IFS= read -r f; do
  [ -e "$f" ] || continue
  if [ -d "$f" ] && [ ! -L "$f" ]; then
    mkdir -p "/out${f}"
    continue
  fi
  mkdir -p "/out$(dirname "$f")"
  cp -a "$f" "/out${f}"
done < /tmp/copy-list.txt

{
  echo "# trustiflux runtime packages extracted from alinux3"
  echo "# Requires: tpm2-tss libtdx-attest tee-primitives"
  echo "# Image packages:"
  for p in ${PKGS}; do
    rpm -q "$p" || echo "WARN: ${p} not installed"
  done
  echo
  echo "## Files"
  cat /tmp/copy-list.txt
} > /out/MANIFEST.txt

echo "== extracted shared objects =="
find /out \( -type f -o -type l \) -name '*.so*' | sort
INNER

log "Installing in container: ${RUNTIME_PKGS}"
log "Image: ${ALINUX3_IMAGE}"

docker run --rm --network=host --entrypoint bash \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  -e no_proxy="${no_proxy:-}" -e NO_PROXY="${NO_PROXY:-}" \
  -e RUNTIME_PKGS="${RUNTIME_PKGS}" \
  -v "${INNER}:/tmp/extract-inner.sh:ro" \
  -v "${OUT_DIR}:/out:rw" \
  "${ALINUX3_IMAGE}" \
  /tmp/extract-inner.sh

if [[ ! -s "${OUT_DIR}/MANIFEST.txt" ]]; then
  log "ERROR: empty extract under ${OUT_DIR}"
  exit 1
fi

# Required libraries
if ! find "${OUT_DIR}" \( -type f -o -type l \) -name 'libtss2*.so*' | grep -q .; then
  log "ERROR: missing libtss2*.so* from tpm2-tss"
  exit 1
fi
if ! find "${OUT_DIR}" \( -type f -o -type l \) -name 'libtdx_attest.so*' | grep -q .; then
  log "ERROR: missing libtdx_attest.so* from libtdx-attest"
  exit 1
fi
# tee-primitives currently ships only a LICENSE stub but is a hard Requires of
# libtdx-attest / trustiflux; we still install the RPM above for completeness.

log "Extracted runtime -> ${OUT_DIR}"
du -sh "${OUT_DIR}"
find "${OUT_DIR}" \( -type f -o -type l \) -name '*.so*' | sort
