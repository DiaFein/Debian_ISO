#!/bin/bash
# Debian Worktop ISO Builder (Trixie/13) - V5
# Creates a minimal GNOME Live ISO with:
#   - Toram mode: squashfs loaded into RAM at boot
#   - Native live-boot encrypted persistence (LUKS2 + persistence.conf)
#   - Fast clone installer (install-worktop)
#   - Live system updater (update-worktop)

set -euo pipefail

# --- Configuration ---
WORK_DIR="$(pwd)/worktop-build"
CHROOT_DIR="${WORK_DIR}/chroot"
IMAGE_DIR="${WORK_DIR}/image"
ISO_NAME="debian-worktop-13-live.iso"
DEBIAN_CODENAME="trixie"
MIRROR="http://deb.debian.org/debian/"
LIVE_USER="ebram"

# --- Cleanup Trap ---
cleanup() {
    echo "Cleaning up mounts..."
    sync
    umount -lf "$CHROOT_DIR/dev" 2>/dev/null || true
    umount -lf "$CHROOT_DIR/proc" 2>/dev/null || true
    umount -lf "$CHROOT_DIR/sys" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Check HOST dependencies
DEPENDENCIES=(mmdebstrap xorriso mksquashfs mtools grub-mkstandalone mkfs.vfat truncate)
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required on your host system."
        exit 1
    fi
done

[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

echo "=== Starting Debian Worktop ISO Build (V5) ==="
mkdir -p "$WORK_DIR" "$IMAGE_DIR/live" "$IMAGE_DIR/isolinux" "$IMAGE_DIR/boot/grub"

# =============================================================================
# 1. Bootstrap Debian Trixie
# =============================================================================
if [ ! -d "$CHROOT_DIR" ]; then
    echo "--> Bootstrapping Debian $DEBIAN_CODENAME..."
    PACKAGES=(
        live-boot live-config live-config-systemd
        systemd-sysv network-manager gnome-core gnome-terminal
        firefox-esr parted cryptsetup cryptsetup-initramfs rsync curl wget vim sudo
        grub-efi-amd64-bin grub-pc-bin
        dosfstools mtools squashfs-tools bc file isolinux syslinux-common
    )
    mmdebstrap --include="$(IFS=,; echo "${PACKAGES[*]}")" \
        "$DEBIAN_CODENAME" "$CHROOT_DIR" "$MIRROR"
fi

# =============================================================================
# 2. Configure Chroot & Install Backports Kernel
# =============================================================================
echo "--> Configuring Chroot & Kernel..."
mount --bind /dev "$CHROOT_DIR/dev"
mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys "$CHROOT_DIR/sys"

chroot "$CHROOT_DIR" /bin/bash <<EOF
export DEBIAN_FRONTEND=noninteractive
echo "debian-worktop" > /etc/hostname
echo "deb $MIRROR ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware" \
    > /etc/apt/sources.list.d/backports.list || true
apt-get update
apt-get install -y -t ${DEBIAN_CODENAME}-backports linux-image-amd64 \
    || apt-get install -y linux-image-amd64
apt-get install -y locales
update-initramfs -u
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
echo "root:worktop" | chpasswd
if ! id "$LIVE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$LIVE_USER"
    echo "${LIVE_USER}:worktop" | chpasswd
    usermod -aG sudo "$LIVE_USER"
fi
mkdir -p /etc/initramfs-tools/conf.d
echo "FORCE_LOAD_MODULES=yes" > /etc/initramfs-tools/conf.d/modules
EOF

# =============================================================================
# 3. Inject Custom Scripts
# =============================================================================

# --- A. update-worktop ---
# Rebuilds the squashfs from the running system (live or installed).
# If running in live mode, it captures the current state (squashfs + persistence)
# and then clears the persistence partition.
cat > "$CHROOT_DIR/usr/local/bin/update-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

# Environment Detection
IS_LIVE=0
if grep -q "boot=live" /proc/cmdline 2>/dev/null; then
    IS_LIVE=1
    echo "--> Environment: Live Mode (boot=live detected)"
else
    echo "--> Environment: Installed Mode"
fi

# Find and mount WORKTOP_BOOT if not already mounted at /boot
if ! mountpoint -q /boot; then
    echo "--> Mounting /boot (WORKTOP_BOOT)..."
    BOOT_PART=$(blkid -L WORKTOP_BOOT -o device | head -n 1)
    [[ -z "$BOOT_PART" ]] && { echo "ERROR: Cannot find WORKTOP_BOOT partition."; exit 1; }
    mount "$BOOT_PART" /boot
fi

LIVE_DIR="/boot/live"
KERNELS_DIR="$LIVE_DIR/kernels"
mkdir -p "$KERNELS_DIR"

# --- Step 1: Rebuild squashfs from current root ---
echo "--> Rebuilding SquashFS from / (excluding ephemeral paths)..."
mksquashfs / "$LIVE_DIR/filesystem.squashfs.tmp" \
    -comp zstd -Xcompression-level 3 -b 1M -noappend -processors "$(nproc)" \
    -e dev proc sys run tmp mnt media boot/live lib/live/mount \
       var/cache/apt/archives var/tmp lost+found \
    || { echo "ERROR: mksquashfs failed."; exit 1; }

mv -f "$LIVE_DIR/filesystem.squashfs.tmp" "$LIVE_DIR/filesystem.squashfs"
echo "--> Squashfs rebuilt: $(du -sh "$LIVE_DIR/filesystem.squashfs" | cut -f1)"

# --- Step 2: Clear persistence partition (if in Live mode) ---
if [[ $IS_LIVE -eq 1 ]]; then
    echo "--> Clearing persistence partition (changes now baked into squashfs)..."
    # Find persistence mount point by label (live-boot uses 'persistence' label)
    PERSIST_MNT=$(findmnt -n -o TARGET -L persistence 2>/dev/null || echo "")
    if [[ -n "$PERSIST_MNT" ]]; then
        # Wipe content, preserve persistence.conf
        find "$PERSIST_MNT" -mindepth 1 ! -name "persistence.conf" -delete
        echo "/ union" > "$PERSIST_MNT/persistence.conf"
        sync
        echo "    Persistence cleared at $PERSIST_MNT"
    else
        echo "    WARNING: Persistence partition not found/mounted — skipping clear."
    fi
fi

# --- Step 3: Sync kernels and update GRUB ---
echo "--> Syncing kernels and updating GRUB snippets..."
rm -rf "${KERNELS_DIR:?}"/*
KERNEL_FOUND=0
TMP_GRUB=$(mktemp)

for kernel in /boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    version=$(basename "$kernel" | sed 's/vmlinuz-//')
    initrd="/boot/initrd.img-$version"
    [[ -f "$initrd" ]] || continue
    echo "    Adding kernel: $version"
    mkdir -p "$KERNELS_DIR/$version"
    cp "$kernel"  "$KERNELS_DIR/$version/vmlinuz"
    cp "$initrd"  "$KERNELS_DIR/$version/initrd.img"
    cat >> "$TMP_GRUB" << GRUB_ENTRY
    menuentry "Toram Live - Kernel $version" {
        search --no-floppy --file --set=root /live/kernels/$version/vmlinuz
        linux  /live/kernels/$version/vmlinuz \
               boot=live toram live-media-path=/live ignore_uuid \
               persistence persistence-encryption=luks \
               quiet splash
        initrd /live/kernels/$version/initrd.img
    }
GRUB_ENTRY
    KERNEL_FOUND=1
done

[[ $KERNEL_FOUND -eq 0 ]] && { echo "ERROR: No kernels found in /boot."; exit 1; }

# Write /etc/grub.d/41_worktop
cat > /etc/grub.d/41_worktop << 'GRUB_HEADER'
#!/bin/sh
exec tail -n +3 $0
GRUB_HEADER
echo "submenu 'Debian Worktop (TORAM LIVE)' --class debian {" >> /etc/grub.d/41_worktop
cat "$TMP_GRUB" >> /etc/grub.d/41_worktop
echo "}" >> /etc/grub.d/41_worktop
chmod +x /etc/grub.d/41_worktop
rm -f "$TMP_GRUB"

if command -v update-grub &>/dev/null; then
    update-grub || echo "Warning: update-grub failed."
fi

echo ""
echo "=== update-worktop complete ==="
echo "    New squashfs baked with current system state."
[[ $IS_LIVE -eq 1 ]] && echo "    Persistence partition cleared."
echo "    Reboot via 'Debian Worktop (TORAM LIVE)' in GRUB to use the new image."
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/update-worktop"

# --- B. install-worktop ---
# Sets up native live-boot persistence:
#   - LUKS2-encrypted partition with inner fs labeled "persistence"
#   - persistence.conf containing "/ union"
#   - No crypttab entry needed — live-boot handles LUKS unlock via boot params
cat > "$CHROOT_DIR/usr/local/bin/install-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Debian Worktop Fast Clone Installer ==="
lsblk
read -r -p "Enter target disk (e.g., /dev/sda): " DISK
[[ ! -b "$DISK" ]] && { echo "Invalid disk."; exit 1; }
read -r -p "Type 'YES' to confirm (ERASES ALL DATA on $DISK): " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }

# Find squashfs on live medium
SQUASHFS_SRC="/run/live/medium/live/filesystem.squashfs"
[[ ! -f "$SQUASHFS_SRC" ]] && \
    SQUASHFS_SRC=$(find /run/live -name "filesystem.squashfs" 2>/dev/null | head -n 1)
[[ -z "$SQUASHFS_SRC" ]] && { echo "ERROR: Cannot find filesystem.squashfs on live media."; exit 1; }

read -r -p "Root partition size in GB (default: 20): " ROOT_SIZE_GB
ROOT_SIZE_GB=${ROOT_SIZE_GB:-20}
ROOT_END=$((4609 + (ROOT_SIZE_GB * 1024)))

# --- Partition ---
echo "--> Partitioning $DISK..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP         fat32  1MiB       513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart WORKTOP_BOOT ext4  513MiB     4609MiB
parted -s "$DISK" mkpart WORKTOP_ROOT ext4  4609MiB    "${ROOT_END}MiB"
parted -s "$DISK" mkpart PERSIST      ext4  "${ROOT_END}MiB" 100%
partprobe "$DISK"; sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    EFI_PART="${DISK}p1"; BOOT_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"; PERSIST_PART="${DISK}p4"
else
    EFI_PART="${DISK}1"; BOOT_PART="${DISK}2"
    ROOT_PART="${DISK}3"; PERSIST_PART="${DISK}4"
fi

# --- Format system partitions ---
echo "--> Formatting system partitions..."
mkfs.vfat -F32 -n EFI          "$EFI_PART"
mkfs.ext4 -L WORKTOP_BOOT      "$BOOT_PART"
mkfs.ext4 -L WORKTOP_ROOT      "$ROOT_PART"

# --- Set up encrypted persistence partition ---
# live-boot requires:
#   1. A LUKS container on the raw partition
#   2. The inner filesystem labeled exactly "persistence"
#   3. A file /persistence.conf containing "/ union"
echo ""
echo "--> Setting up encrypted persistence partition..."
echo "    You will be asked to set the LUKS passphrase twice."
cryptsetup luksFormat --type luks2 "$PERSIST_PART"
cryptsetup luksOpen   "$PERSIST_PART" worktop-persist-setup

# Inner filesystem label MUST be "persistence" — live-boot checks this label
mkfs.ext4 -L persistence /dev/mapper/worktop-persist-setup

PERSIST_TMP=$(mktemp -d)
mount /dev/mapper/worktop-persist-setup "$PERSIST_TMP"

# persistence.conf: "/ union" tells live-boot to union-mount the whole root
echo "/ union" > "$PERSIST_TMP/persistence.conf"
echo "    persistence.conf written: $(cat "$PERSIST_TMP/persistence.conf")"

sync
umount "$PERSIST_TMP"
rm -rf "$PERSIST_TMP"
cryptsetup luksClose worktop-persist-setup
echo "--> Persistence partition ready."

# --- Mount and clone system ---
echo "--> Mounting target partitions..."
mount "$ROOT_PART"  /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART"  /mnt/boot
mkdir -p /mnt/boot/efi          # create AFTER mounting boot, not before
mount "$EFI_PART"   /mnt/boot/efi

echo "--> Cloning base system from squashfs..."
unsquashfs -dest /mnt -force -processors "$(nproc)" "$SQUASHFS_SRC"

# Copy live boot files to /boot/live (for update-worktop)
echo "--> Copying live boot files..."
mkdir -p /mnt/boot/live
cp "$SQUASHFS_SRC" /mnt/boot/live/filesystem.squashfs
cp /run/live/medium/live/vmlinuz  /mnt/boot/live/vmlinuz  2>/dev/null \
    || cp /live/vmlinuz            /mnt/boot/live/vmlinuz
cp /run/live/medium/live/initrd.img /mnt/boot/live/initrd.img 2>/dev/null \
    || cp /live/initrd.img           /mnt/boot/live/initrd.img

# --- fstab (no entry for persistence — live-boot manages it) ---
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EFI_UUID=$(blkid -s UUID -o value  "$EFI_PART")
cat > /mnt/etc/fstab << FSTAB
UUID=$ROOT_UUID  /         ext4  errors=remount-ro  0 1
UUID=$BOOT_UUID  /boot     ext4  defaults           0 2
UUID=$EFI_UUID   /boot/efi vfat  umask=0077         0 1
FSTAB

# --- Bind mounts for chroot ---
mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /run  /mnt/run

ENV="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Install GRUB ---
if [[ -d /sys/firmware/efi ]]; then
    echo "--> Installing UEFI GRUB..."
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    chroot /mnt /usr/bin/env "$ENV" apt-get install -y grub-efi-amd64
    chroot /mnt /usr/bin/env "$ENV" grub-install \
        --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian
else
    echo "--> Installing Legacy BIOS GRUB..."
    chroot /mnt /usr/bin/env "$ENV" apt-get install -y grub-pc
    chroot /mnt /usr/bin/env "$ENV" grub-install "$DISK"
fi

# --- Generate initial GRUB config with persistence params ---
# Write the worktop GRUB snippet directly so update-grub picks it up
cat > /mnt/etc/grub.d/41_worktop << 'GRUB_HEADER'
#!/bin/sh
exec tail -n +3 $0
GRUB_HEADER

KERNEL_FOUND=0
for kernel in /mnt/boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    version=$(basename "$kernel" | sed 's/vmlinuz-//')
    initrd="/mnt/boot/initrd.img-$version"
    [[ -f "$initrd" ]] || continue
    mkdir -p "/mnt/boot/live/kernels/$version"
    cp "$kernel"  "/mnt/boot/live/kernels/$version/vmlinuz"
    cp "$initrd"  "/mnt/boot/live/kernels/$version/initrd.img"
    cat >> /mnt/etc/grub.d/41_worktop << GRUB_ENTRY
    menuentry "Toram Live - Kernel $version" {
        search --no-floppy --file --set=root /live/kernels/$version/vmlinuz
        linux  /live/kernels/$version/vmlinuz \
               boot=live toram live-media-path=/live ignore_uuid \
               persistence persistence-encryption=luks \
               quiet splash
        initrd /live/kernels/$version/initrd.img
    }
GRUB_ENTRY
    KERNEL_FOUND=1
done

if [[ $KERNEL_FOUND -eq 1 ]]; then
    # Wrap in submenu — prepend the submenu line after the header
    {
        head -n 2 /mnt/etc/grub.d/41_worktop
        echo "submenu 'Debian Worktop (TORAM LIVE)' --class debian {"
        tail -n +3 /mnt/etc/grub.d/41_worktop
        echo "}"
    } > /mnt/etc/grub.d/41_worktop.tmp
    mv /mnt/etc/grub.d/41_worktop.tmp /mnt/etc/grub.d/41_worktop
fi
chmod +x /mnt/etc/grub.d/41_worktop
chroot /mnt /usr/bin/env "$ENV" update-grub

# --- Cleanup ---
echo "--> Cleaning up..."
umount -R /mnt
echo ""
echo "=== Installation Complete! ==="
echo ""
echo "  Boot via 'Debian Worktop (TORAM LIVE)' in GRUB."
echo "  live-boot will prompt for your LUKS passphrase to unlock persistence."
echo "  Settings and data are saved automatically to the encrypted partition."
echo "  Run 'sudo update-worktop' to bake current state into a new squashfs."
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/install-worktop"

# =============================================================================
# 4. Build ISO Image
# =============================================================================
cleanup
echo "--> Building SquashFS (ISO)..."
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 1 -b 1M -processors "$(nproc)" -noappend \
    -e boot/live var/cache/apt/archives

echo "--> Copying Kernel & Initrd to ISO..."
NEWEST_KERNEL=$(ls -v "$CHROOT_DIR/boot/vmlinuz-"* 2>/dev/null | tail -n 1 || true)
NEWEST_INITRD=$(ls -v "$CHROOT_DIR/boot/initrd.img-"* 2>/dev/null | tail -n 1 || true)
[[ -z "$NEWEST_KERNEL" || ! -f "$NEWEST_KERNEL" ]] && { echo "FATAL: No kernel found in chroot!"; exit 1; }
cp "$NEWEST_KERNEL" "$IMAGE_DIR/live/vmlinuz"
cp "$NEWEST_INITRD" "$IMAGE_DIR/live/initrd.img"

echo "--> Preparing Bootloaders..."
cp /usr/lib/ISOLINUX/isolinux.bin "$IMAGE_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/* "$IMAGE_DIR/isolinux/" 2>/dev/null \
    || cp /usr/lib/syslinux/bios/* "$IMAGE_DIR/isolinux/"

# isolinux.cfg — persistence params included so USB boot also activates persistence
cat > "$IMAGE_DIR/isolinux/isolinux.cfg" << 'EOF'
default live
label live
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live components live-media-path=/live ignore_uuid \
         toram persistence persistence-encryption=luks \
         bootdelay=5 quiet splash
EOF

# GRUB early config for EFI boot from ISO
cat > "$WORK_DIR/grub-early.cfg" << 'EOF'
insmod iso9660
insmod linux
insmod search_fs_file
if search --no-floppy --file --set=root /live/vmlinuz; then
    set prefix=($root)/boot/grub
    linux  ($root)/live/vmlinuz \
           boot=live components live-media-path=/live ignore_uuid \
           toram persistence persistence-encryption=luks \
           bootdelay=5 quiet splash
    initrd ($root)/live/initrd.img
    boot
fi
EOF

mkdir -p "$IMAGE_DIR/EFI/BOOT"
GRUB_MODULES="part_gpt part_msdos fat iso9660 search search_fs_file search_label \
              search_fs_uuid echo normal configfile all_video sleep linux ext2"
grub-mkstandalone -O x86_64-efi \
    --modules="$GRUB_MODULES" \
    -o "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$WORK_DIR/grub-early.cfg"

truncate -s 32M "$WORK_DIR/efiboot.img"
mkfs.vfat "$WORK_DIR/efiboot.img"
mmd   -i "$WORK_DIR/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK_DIR/efiboot.img" "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$WORK_DIR/efiboot.img" "$IMAGE_DIR/efiboot.img"

ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
[[ ! -f "$ISOHDPFX" ]] && ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"

xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames \
    -volid "WORKTOP_LIVE" \
    -eltorito-boot    isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr "$ISOHDPFX" \
    -eltorito-alt-boot -e efiboot.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$WORK_DIR/efiboot.img" \
    -output "$WORK_DIR/$ISO_NAME" \
    "$IMAGE_DIR"

echo ""
echo "=== Build Complete: $WORK_DIR/$ISO_NAME ==="
