#!/bin/bash
# customize-alinux3-image.sh - Inject the Pod VM runtime into an alinux3 qcow2.
#
# Usage:
#   customize-alinux3-image.sh <input-qcow2> <output-dir>
#
# Environment variables:
#   OVERLAY_DIR   - directory containing the Pod VM overlay (default /overlay)
#   OUTPUT_NAME   - name of the produced image (default podvm-alinux3.qcow2)
#   GUEST_PKGS    - comma-separated list of packages to install inside the guest

set -euo pipefail

INPUT_QCOW2="${1:-/input/base.qcow2}"
OUTPUT_DIR="${2:-/output}"
OVERLAY_DIR="${OVERLAY_DIR:-/overlay}"
OUTPUT_NAME="${OUTPUT_NAME:-podvm-alinux3.qcow2}"
# Single-dash: GUEST_PKGS= (empty) skips yum inside guest-setup.sh.
GUEST_PKGS="${GUEST_PKGS-iptables,iproute,tpm2-tools,e2fsprogs,cryptsetup,ca-certificates}"

if [ ! -f "$INPUT_QCOW2" ]; then
    echo "ERROR: input qcow2 not found: $INPUT_QCOW2" >&2
    exit 1
fi

if [ ! -d "$OVERLAY_DIR" ]; then
    echo "ERROR: overlay directory not found: $OVERLAY_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

WORK_QCOW2="/tmp/base-work.qcow2"
echo "== Copying base image to working file =="
cp --sparse=always "$INPUT_QCOW2" "$WORK_QCOW2"

# Assemble a temporary rootfs tree that mirrors the guest layout.
ROOTFS="/tmp/rootfs"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "== Staging overlay files =="
cp -a "$OVERLAY_DIR/etc" "$ROOTFS/"
cp -a "$OVERLAY_DIR/usr" "$ROOTFS/"
if [ -d "$OVERLAY_DIR/pause_bundle" ]; then
    cp -a "$OVERLAY_DIR/pause_bundle" "$ROOTFS/"
else
    echo "WARNING: no pause_bundle found in overlay" >&2
fi

# Guest-side setup lives in hack/guest-setup.sh (same script for manual paste-in).
# virt-customize --run does not forward host env, so prepend GUEST_PKGS into a temp copy.
HERE="$(cd "$(dirname "$0")" && pwd)"
GUEST_SCRIPT_SRC="$HERE/guest-setup.sh"
if [ ! -f "$GUEST_SCRIPT_SRC" ]; then
    echo "ERROR: guest setup script not found: $GUEST_SCRIPT_SRC" >&2
    exit 1
fi
GUEST_SCRIPT="/tmp/guest-setup.sh"
{
    echo '#!/bin/sh'
    echo "export GUEST_PKGS=$(printf '%q' "$GUEST_PKGS")"
    # Drop the original shebang; export above must run first.
    tail -n +2 "$GUEST_SCRIPT_SRC"
} > "$GUEST_SCRIPT"
chmod +x "$GUEST_SCRIPT"

# Build the virt-customize command dynamically so we only copy existing trees.
VIRT_CUSTOMIZE_ARGS=(
    -a "$WORK_QCOW2"
    --copy-in "$ROOTFS/etc:/"
    --copy-in "$ROOTFS/usr:/"
)
if [ -d "$ROOTFS/pause_bundle" ]; then
    VIRT_CUSTOMIZE_ARGS+=(--copy-in "$ROOTFS/pause_bundle:/")
fi
VIRT_CUSTOMIZE_ARGS+=(--run "$GUEST_SCRIPT")

echo "== Running virt-customize (this may take a few minutes) =="
virt-customize "${VIRT_CUSTOMIZE_ARGS[@]}"

echo "== Compressing and writing output image =="
qemu-img convert -O qcow2 -c "$WORK_QCOW2" "$OUTPUT_DIR/$OUTPUT_NAME"

echo "Done: $OUTPUT_DIR/$OUTPUT_NAME"
