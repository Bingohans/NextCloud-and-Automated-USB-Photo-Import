#!/bin/bash

# === KILL SWITCH ===
# If a file named 'photo_import.disabled' exists in the same directory as this script,
# exit immediately without doing anything.
SCRIPT_DIR=$(dirname "$0")
if [ -f "${SCRIPT_DIR}/photo_import.disabled" ]; then
    exit 0
fi

# This script expects the device name as an argument (e.g., "sdc1")
if [ -z "$1" ]; then
    echo "Error: No device name provided."
    exit 1
fi

# === CONFIGURATION ===
# Replace these placeholders with your actual paths and username

# The path to the 'files' directory of the target Nextcloud user.
# The script will create a 'Photos' subdirectory here if it doesn't exist.
NEXTCLOUD_DATA_PATH="/path/to/nextcloud/data/YOUR_NEXTCLOUD_USERNAME/files/Photos"

# The full path to the docker-compose.yml file for your Nextcloud instance.
COMPOSE_FILE_PATH="/path/to/your/nextcloud-project/docker-compose.yml"

# The full path to the log file for this script.
LOG_FILE="/path/to/your/scripts/photo_import.log"
# === END CONFIGURATION ===


DEVICE_NODE="/dev/$1"
# Create a unique, temporary directory to use as a mount point.
USB_MOUNT_PATH=$(mktemp -d)

# Ensure cleanup (unmount and remove temp directory) happens automatically when the script exits,
# even if it fails.
cleanup() {
    log "Running cleanup..."
    # Use 'umount -l' for a more robust (lazy) unmount.
    umount -l "$USB_MOUNT_PATH" &>/dev/null
    rmdir "$USB_MOUNT_PATH"
    log "Unmounted and removed temporary directory: $USB_MOUNT_PATH"
}
trap cleanup EXIT

# Function to write messages to the log file with a timestamp.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> ${LOG_FILE}
}

log "=== New import started for device: $DEVICE_NODE ==="

# Mount the device to the temporary directory.
mount "$DEVICE_NODE" "$USB_MOUNT_PATH"
if [ $? -ne 0 ]; then
    log "Error: Could not mount $DEVICE_NODE to $USB_MOUNT_PATH"
    exit 1
fi
log "Device mounted successfully to $USB_MOUNT_PATH"

# Find and copy all image files.
# Using -print0 and read -d is a safe way to handle filenames with spaces or special characters.
find "$USB_MOUNT_PATH" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 | while read -d $'\0' file; do
    
    # Read the creation date from EXIF data. Format: YYYY-MM
    # If no EXIF date is found, fall back to using the file's modification date.
    IMG_DATE=$(exiftool -d "%Y-%m" -S -s -DateTimeOriginal "$file" || date -r "$file" "+%Y-%m")

    # Define the destination directory inside Nextcloud.
    DEST_DIR="$NEXTCLOUD_DATA_PATH/$IMG_DATE"

    # Create the directory if it doesn't already exist.
    mkdir -p "$DEST_DIR"

    # Copy the file using rsync. --ignore-existing prevents creating duplicates.
    rsync -av --ignore-existing "$file" "$DEST_DIR/"
    
    log "Copied $file to $DEST_DIR"
done

log "Copying finished. Correcting file permissions..."

# --- POST-PROCESSING (VERY IMPORTANT!) ---

# 1. Set the correct ownership so the Nextcloud container can see the files.
# The entire directory must be owned by www-data (user ID 33).
sudo chown -R 33:33 "$NEXTCLOUD_DATA_PATH"

log "Permissions set. Scanning files in Nextcloud..."

# 2. Tell Nextcloud to scan for new files so they appear in the web interface.
# We use -T to avoid an error when the cron job runs without an interactive terminal.
docker-compose -f "$COMPOSE_FILE_PATH" exec -T -u www-data app php occ files:scan --all

log "Import finished successfully!"
echo "---" >> ${LOG_FILE}

# Cleanup happens automatically via the 'trap' when the script exits.
