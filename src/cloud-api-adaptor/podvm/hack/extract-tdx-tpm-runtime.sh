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
  docker pull "${ALINUX3_IMAGE}"
fi

INNER="$(mktemp)"
trap 'rm -f "${INNER}"' EXIT
cat > "${INNER}" <<'INNER'
#!/bin/bash
set -euo pipefail

PKGS="${RUNTIME_PKGS}"
echo "== yum install: ${PKGS} =="
# shellcheck disable=SC2086
yum install -y ${PKGS}

LIST=/tmp/runtime-files.txt
: > "${LIST}"
for p in ${PKGS}; do
  rpm -q "$p"
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
  # shellcheck disable=SC2086
  rpm -q ${PKGS}
  echo
  echo "## Files"
  cat /tmp/copy-list.txt
} > /out/MANIFEST.txt

echo "== extracted shared objects =="
find /out \( -type f -o -type l \) -name '*.so*' | sort
INNER

log "Installing in container: ${RUNTIME_PKGS}"
log "Image: ${ALINUX3_IMAGE}"

docker run --rm --network=host \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e HTTP_PROXY="${HTTP_PROXY:-}" -e HTTPS_PROXY="${HTTPS_PROXY:-}" \
  -e no_proxy="${no_proxy:-}" -e NO_PROXY="${NO_PROXY:-}" \
  -e RUNTIME_PKGS="${RUNTIME_PKGS}" \
  -v "${INNER}:/tmp/extract-inner.sh:ro" \
  -v "${OUT_DIR}:/out:rw" \
  "${ALINUX3_IMAGE}" \
  bash /tmp/extract-inner.sh

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
