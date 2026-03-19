# Debian Worktop ISO Builder

A fully automated bash script to generate a high-performance, minimal GNOME Debian Live ISO (Trixie/13) engineered specifically for **Toram** (Run-from-RAM) execution and encrypted overlay persistence.

## 🚀 Features
- **Toram First:** The entire base system loads into RAM on boot, delivering near-instant application load times and drastically reducing disk I/O.
- **Fast Clone Installer:** Includes a built-in interactive fast clone installer (`install-worktop`) to rapidly deploy the Live Base to local NVMe/SSD/HDD drives.
- **Encrypted Persistence:** Fully automated 5-minute background syncs for your persistent changes, shielded behind a LUKS2 encrypted partition.
- **Atomic Base Upgrades:** The `update-worktop` utility lets you confidently bake active updates and app installations on the live system directly into a brand new immutable Base System on disk—featuring atomic swap protection so you can never brick your system on power loss.

## 📋 Prerequisites
To build the ISO, your host system must run Debian/Ubuntu (as `root`) and have the following packages installed:
```bash
sudo apt-get install mmdebstrap xorriso squashfs-tools mtools grub-efi-amd64-bin grub-pc-bin dosfstools
```

## 🛠️ Building the ISO
1. Open the script `Debian-toram.sh`.
2. Edit the `LIVE_USER="your_username"` configuration variable at the top.
3. Run the builder as root:
```bash
sudo ./Debian-toram.sh
```
The resulting bootable image will be compiled in the `./worktop-build/` directory as `debian-worktop-13-live.iso`.

## 💻 Installation & Usage

### 1. Boot the Live USB
Flash the freshly built ISO to a USB drive using `dd` or Rufus. Boot your machine from the USB. The system will copy itself to RAM (`toram`) during the splash screen, leaving your USB drive completely idle afterward.

### 2. Fast Clone to Local Disk
If you want to install this system onto your local hard drive natively:
1. Open Terminal.
2. Run the installer:
   ```bash
   sudo install-worktop
   ```
3. Follow the prompts to select your target disk, confirm the wipe, set up your root partition size, and establish your LUKS encryption password for persistence.

### 3. Using Persistent Storage
The system intelligently separates the **Immutable Base System** (mounted read-only) from your **Personal Overlay** (mounted read-write in RAM). 

In the background, a `systemd` service (`worktop-sync-engine`) reliably synchronizes your modifications down to the `WORKTOP_PERSIST` partition every 5 minutes. No manual intervention is required. 

### 4. Updating the Base OS
Should you perform major `apt upgrade` updates or install new system-level software that you want to keep permanently fused to the read-only layer:
1. Make your changes or installations on the running system.
2. Execute the base updater:
   ```bash
   sudo update-worktop
   ```
This command seamlessly repacks your live system down to the GRUB boot partition and intelligently schedules the persistent overlay to physically wipe itself on your next shutdown. Reboot, and you are running entirely off the newly optimized base!
