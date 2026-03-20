#!/data/data/com.termux/files/usr/bin/bash

# Set Backup DIRECTORY
BACKUP_DIR="/data/data/com.termux/files/home/storage/downloads/backups"
DATE=$(date +%F_%H-%M)
TMPDIR=$(mktemp -d)

# What you need to backup (Can add or remove)
BACKUP_ITEMS=(
# Wadboard
    "/data/data/com.termux/files/home/Wadboard"
# Usefull scripts (info.sh; battery_guard.sh)
    "/data/data/com.termux/files/home/scripts"
# Backup scrips (This file; ManualUpload file)
    "/data/data/com.termux/files/home/backup_scripts"
# Nginx
    "/data/data/com.termux/files/usr/etc/nginx"
# Cron
    "/data/data/com.termux/files/usr/var/spool/cron/u0_a150"
# Bashrc
    "/data/data/com.termux/files/home/.bashrc"
# Termux autorun
    "/data/data/com.termux/files/home/.termux/boot/"
# Termux config
    "/data/data/com.termux/files/home/.config"
# Websites
    "/data/data/com.termux/files/home/storage/downloads/www"
)

mkdir -p "$BACKUP_DIR"

for ITEM in "${BACKUP_ITEMS[@]}"; do
    if [ -e "$ITEM" ]; then
        SAFE_NAME=$(echo "$ITEM" | sed 's|/|_|g' | sed 's/^_//')
        DEST="$TMPDIR/$SAFE_NAME"
        mkdir -p "$(dirname "$DEST")"
        cp -a "$ITEM" "$DEST"
    else
        echo "Skipped: $ITEM (not found)"
    fi
done

ARCHIVE="$BACKUP_DIR/termux-config-$DATE.tar.gz"
tar -czf "$ARCHIVE" -C "$TMPDIR" .

echo "DONE: $ARCHIVE"

rm -rf "$TMPDIR"

# retention

cd /data/data/com.termux/files/home/storage/downloads/backups
ls -1t termux-config-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
echo "Retention complete. Only 3 latest backups kept."
