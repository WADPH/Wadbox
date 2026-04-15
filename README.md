# Wadbox Scripts Documentation

## 1. NetworkChecker

### Description

Script for monitoring network connectivity and sending alerts to Telegram when the connection goes down or is restored.

Works via cron (recommended: every minute).

---

### How it works

* Pings a target IP (`8.8.8.8`)
* If ping fails:

  * Saves state (`DOWN`)
  * Stores timestamp
  * Sends Telegram alert
* If connection is restored:

  * Calculates downtime duration
  * Sends recovery message
  * Cleans up temporary state files

---

### Key Features

* Prevents duplicate alerts (state file logic)
* Tracks downtime duration
* Lightweight and cron-friendly

---

### Configuration

```bash
IP="8.8.8.8"
BOT_TOKEN="<YOUR_TOKEN_HERE>"
CHAT_ID="<TELEGRAM_CHAT_ID>"
```

---

### State Files

```
/tmp/ping_state      # connection state (down)
/tmp/ping_down_time  # timestamp when connection lost
```

---

### Cron Setup

```bash
* * * * * /path/to/NetworkChecker
```

---

### Example Notifications

* On failure:

  ```
  📶 Network is offline
  ```
* On recovery:

  ```
  ✅ Connection restored. Downtime: X min
  ```

---

## 2. TermuxInfo.sh

### Description

Utility script for displaying device status information in Termux (Android).

---

### What it shows

#### Wi-Fi Info

* IP address
* SSID
* Signal strength (RSSI)

#### Battery Info

* Health
* Status (charging/discharging)
* Temperature
* Percentage

---

### Dependencies

Requires Termux API:

```bash
pkg install termux-api
```

---

### Commands Used

* `termux-wifi-connectioninfo`
* `termux-battery-status`

---

### Example Output

```
WiFi Info
IP: 192.168.1.10
SSID: MyNetwork
RSSI: -45

Battery Info
Status: CHARGING
Percentage: 82
Temperature: 32.1
```

---

## 3. proxmox-backup.sh

### Description

Script for backing up critical Proxmox host configuration with full path preservation for fast disaster recovery.

---

### Key Features

* Preserves original filesystem structure
* Easy to extend backup list
* Saves installed packages list
* Includes system metadata
* Automatic retention (keeps last 3 backups)

---

### What is backed up

#### Proxmox & System

```
/etc/pve
/etc/network/interfaces
/etc/fstab
/etc/hosts
/etc/resolv.conf
```

#### Services & Access

```
/etc/nginx
/etc/iptables
/etc/ssh
/root/.ssh
```

#### User & Custom Configs

```
/root/.bashrc
/root/scripts
/root/.config
/var/spool/cron
```

---

### Additional Metadata

```
meta/packages.list   # installed packages
meta/uname.txt      # kernel/system info
meta/lsblk.txt      # disk layout
```

---

### How it works

1. Creates temporary directory
2. Copies all configured paths preserving structure
3. Saves package list and system info
4. Archives everything into `.tar.gz`
5. Cleans up temp files
6. Applies retention policy

---

### Backup Location

```bash
BACKUP_DIR="/backup/path/folder"
```

---

### Output Example

```
/backup/path/folder/proxmox-config-2026-04-15_03-00.tar.gz
```

---

### Retention Policy

Keeps only last 3 backups:

```bash
ls -1t proxmox-config-*.tar.gz | tail -n +4 | xargs rm -f
```

---

### Restore (Quick Guide)

#### 1. Extract archive

```bash
tar -xzf proxmox-config-*.tar.gz -C /
```

#### 2. Restore packages

```bash
dpkg --set-selections < /meta/packages.list
apt-get update
apt-get dselect-upgrade -y
```

#### 3. Restart services

```bash
systemctl restart networking
mount -a
```

---

### Notes

* Designed for recovery on different hardware
* No dependency on disk UUID consistency
* Works alongside VM backups for full disaster recovery

---

# Summary

Wadbox provides:

* Network monitoring with alerting
* Mobile diagnostics (Termux)
* Proxmox disaster recovery backups

Focused on simplicity, portability, and real-world usability
