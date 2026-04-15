#!/bin/bash
# proxmox-backup.sh

set -e

BACKUP_DIR="/backup/path/folder"  # Set backup location
DATE=$(date +%F_%H-%M)
TMPDIR=$(mktemp -d)

# Items to backup (easy to extend)
BACKUP_ITEMS=(
    "/etc/pve"
    "/etc/network/interfaces"
    "/etc/fstab"
    "/etc/hosts"
    "/etc/resolv.conf"
    "/etc/iptables"
    "/etc/nginx"
    "/etc/ssh"
    "/root/.ssh"
    "/root/.bashrc"
    "/root/scripts"
    "/root/.config"
    "/var/spool/cron"
)

mkdir -p "$BACKUP_DIR"

echo "Starting backup..."

# Preserve full path structure
for ITEM in "${BACKUP_ITEMS[@]}"; do
    if [ -e "$ITEM" ]; then
        echo "Backing up $ITEM"
        DEST="$TMPDIR$ITEM"
        mkdir -p "$(dirname "$DEST")"
        cp -a "$ITEM" "$DEST"
    else
        echo "Skipped: $ITEM (not found)"
    fi
done

# Save installed packages list
echo "Saving package list..."
mkdir -p "$TMPDIR/meta"
dpkg --get-selections > "$TMPDIR/meta/packages.list"

# Save kernel + system info (useful for debugging)
uname -a > "$TMPDIR/meta/uname.txt"
lsblk > "$TMPDIR/meta/lsblk.txt"

# Create archive
ARCHIVE="$BACKUP_DIR/proxmox-config-$DATE.tar.gz"
tar -czf "$ARCHIVE" -C "$TMPDIR" .

echo "Backup completed: $ARCHIVE"

rm -rf "$TMPDIR"

# Retention (keep last 3)
cd "$BACKUP_DIR"
ls -1t proxmox-config-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

echo "Retention complete (kept last 3 backups)"
