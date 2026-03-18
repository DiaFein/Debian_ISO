# Debian_ISO-AG

The build-debian-worktop-iso.sh script is ready. It creates a custom Debian 13 (Trixie) ISO containing your specialized installer and runtime environment.

Key Features

High-Performance Toram Mode: The system boots entirely into RAM.
Encrypted Persistence: A custom "Sync Engine" runs every 5 minutes (and on shutdown) to copy changes from the RAM overlay to your LUKS-encrypted partition.
Hybrid Boot: The installer sets up GRUB with two modes:
Debian Base: Standard persistent installation on /dev/sdX3.
Debian Toram: RAM-based mode booting from /dev/sdX2.
Auto-Updates: The update-toram script (installed to /usr/local/bin/update-toram) regenerates the live image from your Base system and adds entries for all installed kernels to the GRUB menu.
Instructions

Install Build Dependencies: You need a Debian/Ubuntu host to build the ISO.
1 sudo apt update 2 sudo apt install mmdebstrap xorriso squashfs-tools parted cryptsetup mtools grub-common dosfstools

Build the ISO: Run the script as root. 1 sudo ./build-debian-worktop-iso.sh This will produce worktop-build/debian-worktop-13-live.iso.

Install on Hardware:

Flash the ISO to a USB stick.
Boot the USB.
Login as root (password: worktop) or ebram (password: worktop).
Run the installer: 1 sudo debian-worktop-installer
Follow the prompts to partition your disk (you can customize sizes) and set your LUKS password.
Maintenance:

Boot into "Debian Base" to install updates or new kernels.
Run sudo update-toram to apply those changes to the Live system.
Reboot into "Debian Toram" to use the updated, high-performance environment.
