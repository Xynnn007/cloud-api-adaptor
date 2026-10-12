#!/bin/sh
# guest-setup.sh - Post-copy steps for turning an alinux3 base OS into a Pod VM.
#
# Run as root INSIDE the guest (or chroot) AFTER overlay files have been
# copied onto /. Also invoked by virt-customize via customize-alinux3-image.sh.
#
# Usage:
#   ./guest-setup.sh                 # install default GUEST_PKGS via yum
#   ./guest-setup.sh --skip-yum      # never touch yum (recommended offline)
#   env GUEST_PKGS= ./guest-setup.sh # same as --skip-yum (must keep env; sudo drops it)
#
# Optional environment:
#   GUEST_PKGS  comma-separated yum packages. Unset => default list below.
#               Set to empty => skip package install.
#   Note: plain `sudo` clears env; use `./guest-setup.sh --skip-yum` or
#         `sudo env GUEST_PKGS= ./guest-setup.sh`.
#   Log: /var/log/podvm-customize.log (follow with: tail -f that file)

set -eu

SKIP_YUM=0
for arg in "$@"; do
    case "$arg" in
        --skip-yum) SKIP_YUM=1 ;;
        -h|--help)
            echo "Usage: $0 [--skip-yum]"
            exit 0
            ;;
    esac
done

DEFAULT_GUEST_PKGS="iptables,iproute,tpm2-tools,e2fsprogs,cryptsetup,ca-certificates"
if [ "$SKIP_YUM" -eq 1 ]; then
    GUEST_PKGS=
elif [ -z "${GUEST_PKGS+set}" ]; then
    # Unset only — empty GUEST_PKGS= must still mean skip.
    GUEST_PKGS="$DEFAULT_GUEST_PKGS"
fi

LOG="/var/log/podvm-customize.log"
mkdir -p "$(dirname "$LOG")"
# Show intent on the terminal before redirecting everything to the log.
echo "Logging to $LOG — follow with: tail -f $LOG"
if [ -z "$GUEST_PKGS" ]; then
    echo "Package install: SKIPPED (GUEST_PKGS empty or --skip-yum)"
else
    echo "Package install: $GUEST_PKGS"
fi
exec >> "$LOG" 2>&1

echo "== $(date -Is) Starting Pod VM guest setup =="
echo "GUEST_PKGS='${GUEST_PKGS}' SKIP_YUM=$SKIP_YUM"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# Disable SELinux permanently (Pod VM cmdline also disables it)
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
fi

# Runtime packages (best-effort if repos are reachable).
# Empty GUEST_PKGS skips yum entirely (avoids repo hangs in offline guests).
if [ -n "$GUEST_PKGS" ] && command -v yum >/dev/null 2>&1; then
    echo "== Installing runtime packages: $GUEST_PKGS =="
    OLD_IFS=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $GUEST_PKGS
    IFS=$OLD_IFS
    yum --setopt=timeout=30 --setopt=retries=2 \
        --setopt=skip_if_unavailable=1 install -y "$@" || \
        echo "WARNING: package install failed or was partial; continuing"
else
    echo "== Skipping package install (GUEST_PKGS empty or yum missing) =="
fi

# Fresh machine-id for clones
echo -n > /etc/machine-id

# peerpod user (SFTP / user-data paths)
if ! id peerpod >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin -d /home/peerpod peerpod
fi
mkdir -p /home/peerpod
chown peerpod:peerpod /home/peerpod || true
passwd -l peerpod 2>/dev/null || true

# Pick up new systemd units
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

# Pod VM kernel cmdline
GRUB_DEFAULT=/etc/default/grub
PODVM_CMDLINE='console=ttyS0 systemd.firstboot=off systemd.volatile=state selinux=0 enforcing=0 audit=0 initcall_blacklist=vmgenid_platform_driver_init cgroup_disable=ioasids'
if [ -f "$GRUB_DEFAULT" ]; then
    echo "== Updating GRUB cmdline =="
    if grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT"; then
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$PODVM_CMDLINE\"|" "$GRUB_DEFAULT"
    else
        echo "GRUB_CMDLINE_LINUX=\"$PODVM_CMDLINE\"" >> "$GRUB_DEFAULT"
    fi
fi

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

echo "== Regenerating initramfs =="
if command -v dracut >/dev/null 2>&1; then
    dracut -f || true
elif command -v mkinitrd >/dev/null 2>&1; then
    mkinitrd -f || true
fi

echo "== $(date -Is) Pod VM guest setup complete =="
echo "Log: $LOG"
