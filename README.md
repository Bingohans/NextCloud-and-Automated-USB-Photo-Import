# Raspberry Pi Nextcloud with Automated USB Photo Import

This project sets up a self-hosted Nextcloud instance using Docker Compose on a Raspberry Pi, with a key feature: a fully automated script that imports photos from any connected USB stick into a user's Nextcloud account.

The primary goal is to create a private photo backup solution where user data is stored on a dedicated external drive, while the Nextcloud application itself runs on the Pi's main SD card.

## Features

* **Docker Compose Setup**: Runs Nextcloud with a MariaDB database, Redis for caching, and a dedicated Cron container for background jobs.
* **External Data Storage**: User files are stored on an external USB drive, keeping the Pi's SD card free.
* **Automated Photo Import**: A udev-triggered script automatically detects any newly inserted USB stick.
* **Smart Photo Organization**: The script reads EXIF data from photos and sorts them into `YYYY-MM` dated folders within Nextcloud.
* **System Integration**: Uses systemd to run the import script in the background, ensuring long-running copy processes are not killed by udev.

## Setup Instructions

### 1. Prepare the Host (Raspberry Pi)

**Mount External Drive**
Ensure your primary external drive (for Nextcloud data) is permanently mounted via `/etc/fstab` using its UUID. The `nofail` option is crucial to prevent boot issues if the drive is disconnected.

Example `fstab` entry for an ext4 drive:
```
UUID=YOUR_DISK_UUID   /mnt/usb1   ext4   defaults,auto,users,rw,nofail   0   2
```

**Create Directories**
```bash
# Project directory for Docker Compose files
mkdir ~/nextcloud
cd ~/nextcloud

# Nextcloud data directory on the external drive
sudo mkdir -p /mnt/usb1/nextcloud/data
```

**Set Permissions**
The Nextcloud container user (`www-data`, UID 33) needs ownership of the data directory.
```bash
sudo chown -R 33:33 /mnt/usb1/nextcloud/data
```

**Prepare .env file**
Create a `.env` file in `~/nextcloud` for your database credentials to keep them separate from the main compose file.

### 2. Launch Nextcloud

Use the provided `docker-compose.yml` file and launch the services:
```bash
docker-compose up -d
```
Follow the initial Nextcloud setup in your browser and remember to add your local domain (e.g., `nextcloud.local`) and IP to the `trusted_domains` in your `config.php`.

## The Automation Script (`photo_import.sh`)

This script is the brain of the operation. It's triggered by udev and receives the device name (e.g., `sdc1`) as an argument.

**Key logic:**
* Creates a temporary mount point.
* Mounts the detected USB device.
* Uses `find` to locate all image files (`.jpg`, `.jpeg`, `.png`).
* Uses `exiftool` to read the photo's creation date from its metadata.
* Uses `rsync --ignore-existing` to copy the file to the correct `YYYY-MM` folder in the Nextcloud data directory. This prevents duplicates.
* Runs `sudo chown -R 33:33` to fix permissions on the newly imported files.
* Runs `docker-compose exec ... occ files:scan` to make Nextcloud aware of the new files without a manual scan.
* Automatically unmounts and cleans up the temporary directory upon exit, even if errors occur.

## Automation Trigger (udev + systemd)

This system is event-driven and consists of two parts to reliably handle long-running tasks:

* **systemd Service** (`/etc/systemd/system/usb-photo-import@.service`): A template service that runs the `photo_import.sh` script in the background. It's designed to handle long-running processes without being terminated by udev.
* **udev Rule** (`/etc/udev/rules.d/99-usb-photo-import.rules`): A rule that watches for new USB storage devices with a filesystem. When detected, it triggers the systemd service, passing the device's kernel name (e.g., `sdb1`) as an argument.

## Troubleshooting Journey & Key Learnings

Setting this up involved solving several complex issues, particularly related to the external USB drive on the Raspberry Pi.

### The Mystery of the Silently Failing Mount

The primary challenge was an external 1.8TB Seagate Expansion HDD that would not mount reliably after a reboot, despite being visible with `lsblk`.

* **Symptoms**: The `mount` command would run without any error message, but the drive would not appear in `df -h` or `/proc/mounts`. This "silent failure" was the most confusing part of the diagnosis.
* **Initial Suspects**: `fstab` errors, mount namespaces (due to Docker), and filesystem corruption were all investigated and ruled out. The drive was successfully mounted manually, but failed on boot and with `mount -a`.
* **Root Cause**: Insufficient power from the Raspberry Pi's USB ports. The Pi could provide enough power for the drive's controller to be detected by the kernel (appearing in `lsblk` and `dmesg`), but not enough for the mechanical motor to reliably spin up and complete the mount operation. This caused the mount process to fail silently.
* **Solution**: A software tweak was implemented by adding `max_usb_current=1` to `/boot/firmware/config.txt`. This boosts the USB current limit from the default 600mA to 1.2A. For this to work, a high-quality, official Raspberry Pi power supply (5V, 3A+) is essential. This confirmed that the problem was hardware/power-related, not a software configuration issue. For drives that are even more power-hungry, the ultimate solution would be a powered USB hub or a USB Y-cable.
