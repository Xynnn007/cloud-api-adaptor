#!/usr/bin/env bash
# Load Pod VM private-cloud build pins from src/cloud-api-adaptor/versions.yaml into the
# caller's environment. Requires yq v4 on PATH.
#
# Usage (from another script that already has set -euo pipefail):
#   # shellcheck source=load-versions.sh
#   source "$(dirname "$0")/load-versions.sh"
#   load_versions   # optional: VERSIONS_YAML=/path/to/versions.yaml
#
# Only sets a variable when it is currently unset/empty, so callers can override
# with env (e.g. KATA_REPO_URL=...).

load_versions() {
  local here versions name path cur val registry tag
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  versions="${VERSIONS_YAML:-${here}/../../versions.yaml}"

  if [[ ! -f "${versions}" ]]; then
    echo "[load-versions] ERROR: versions.yaml not found: ${versions}" >&2
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "[load-versions] ERROR: yq not found on PATH" >&2
    return 1
  fi

  _lv_get() {
    yq -e ".$1 // \"\"" "${versions}" 2>/dev/null | sed '/^null$/d'
  }

  _lv_set() {
    name="$1"
    path="$2"
    eval "cur=\${${name}-}"
    if [[ -n "${cur}" ]]; then
      return 0
    fi
    val="$(_lv_get "${path}")"
    if [[ -z "${val}" ]]; then
      echo "[load-versions] ERROR: missing versions.yaml key: ${path}" >&2
      return 1
    fi
    printf -v "${name}" '%s' "${val}"
    export "${name?}"
  }

  _lv_set GO_VERSION tools.golang
  _lv_set RUST_VERSION tools.rust
  _lv_set KATA_REPO_URL git.kata-containers.url
  _lv_set KATA_REF git.kata-containers.reference
  _lv_set GC_REPO git.inclavare-guest-components.url
  _lv_set GC_REF git.inclavare-guest-components.reference
  _lv_set AA_ATTESTER git.inclavare-guest-components.aa_attester
  _lv_set RUNTIME_PKGS git.inclavare-guest-components.runtime_rpms
  _lv_set PAUSE_REPO oci.pause.registry
  _lv_set PAUSE_VERSION oci.pause.tag

  if [[ -z "${ALINUX3_IMAGE:-}" ]]; then
    registry="$(_lv_get oci.alinux3.registry)"
    tag="$(_lv_get oci.alinux3.tag)"
    ALINUX3_IMAGE="${registry}:${tag}"
    export ALINUX3_IMAGE
  fi
  if [[ -z "${ALPINE_IMAGE:-}" ]]; then
    registry="$(_lv_get oci.alpine.registry)"
    tag="$(_lv_get oci.alpine.tag)"
    ALPINE_IMAGE="${registry}:${tag}"
    export ALPINE_IMAGE
  fi

  echo "[load-versions] ${versions}"
  echo "[load-versions] GO_VERSION=${GO_VERSION}"
  echo "[load-versions] KATA_REPO_URL=${KATA_REPO_URL}"
  echo "[load-versions] KATA_REF=${KATA_REF}"
  echo "[load-versions] GC_REPO=${GC_REPO}"
  echo "[load-versions] GC_REF=${GC_REF}"
  echo "[load-versions] AA_ATTESTER=${AA_ATTESTER}"
  echo "[load-versions] ALINUX3_IMAGE=${ALINUX3_IMAGE}"
  echo "[load-versions] ALPINE_IMAGE=${ALPINE_IMAGE}"
  echo "[load-versions] PAUSE=${PAUSE_REPO}:${PAUSE_VERSION}"
  echo "[load-versions] RUNTIME_PKGS=${RUNTIME_PKGS}"
  return 0
}
