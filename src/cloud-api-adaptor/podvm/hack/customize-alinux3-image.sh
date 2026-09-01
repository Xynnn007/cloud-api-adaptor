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
GUEST_PKGS="${GUEST_PKGS:-iptables,iproute,tpm2-tools,e2fsprogs,cryptsetup,ca-certificates}"

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

# Guest-side setup script. It runs inside the guest rootfs via virt-customize.
GUEST_SCRIPT="/tmp/guest-setup.sh"
cat > "$GUEST_SCRIPT" <<'EOF'
#!/bin/sh
set -eu

LOG="/var/log/podvm-customize.log"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

echo "== Starting alinux3 Pod VM customization =="

# Disable SELinux permanently (Pod VM cmdline also disables it)
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
fi

# Try to install runtime packages, but do not fail the build if the guest
# cannot reach its yum repos. In the private-cloud environment the internal repos may
# be reachable; otherwise the base image is expected to contain these.
if command -v yum >/dev/null 2>&1; then
    echo "== Attempting to install runtime packages =="
    yum --setopt=timeout=5 --setopt=retries=2 \
        --setopt=skip_if_unavailable=1 install -y @GUEST_PKGS@ || \
        echo "WARNING: package install failed or was partial; continuing"
fi

# Ensure machine-id is empty so clones get a fresh ID/DHCP lease.
echo -n > /etc/machine-id

# Create/update the peerpod user used by SFTP / some user-data paths.
if ! id peerpod >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin -d /home/peerpod peerpod
fi
mkdir -p /home/peerpod
chown peerpod:peerpod /home/peerpod || true
passwd -l peerpod || true

# Reload systemd so the newly copied units are known.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

# Update GRUB kernel command line for Pod VM boot.
GRUB_DEFAULT=/etc/default/grub
if [ -f "$GRUB_DEFAULT" ]; then
    echo "== Updating GRUB cmdline =="
    PODVM_CMDLINE='console=ttyS0 systemd.firstboot=off systemd.volatile=state selinux=0 enforcing=0 audit=0 initcall_blacklist=vmgenid_platform_driver_init'
    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT"; then
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$PODVM_CMDLINE\"|" "$GRUB_DEFAULT"
    else
        echo "GRUB_CMDLINE_LINUX=\"$PODVM_CMDLINE\"" >> "$GRUB_DEFAULT"
    fi
fi

# Regenerate GRUB config for both BIOS and common UEFI paths.
echo "== Regenerating GRUB configuration =="
if command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
    for efi_cfg in /boot/efi/EFI/alinux/grub.cfg \
                   /boot/efi/EFI/centos/grub.cfg \
                   /boot/efi/EFI/redhat/grub.cfg \
                   /boot/efi/EFI/boot/grub.cfg; do
        if [ -f "$efi_cfg" ]; then
            grub2-mkconfig -o "$efi_cfg" || true
        fi
    done
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# Regenerate initramfs so any new modules/units are picked up.
echo "== Regenerating initramfs =="
if command -v dracut >/dev/null 2>&1; then
    dracut -f || true
elif command -v mkinitrd >/dev/null 2>&1; then
    mkinitrd -f || true
fi

echo "== alinux3 Pod VM customization complete =="
EOF

# Substitute the package list into the guest-side script.
sed -i "s|@GUEST_PKGS@|$GUEST_PKGS|g" "$GUEST_SCRIPT"

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
