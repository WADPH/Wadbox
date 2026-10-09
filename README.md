# Wadbox Scripts Documentation

A collection of small Bash scripts for a homelab: network monitoring, login alerts, config backups and Termux diagnostics.

| Script | Purpose |
|---|---|
| [NetworkChecker](#1-networkchecker) | Telegram alert when the internet connection goes down / comes back |
| [pam-tg-notify.sh](#2-pam-tg-notifysh) | Telegram alert on every SSH / Cockpit login (via PAM) |
| [homelab-backup.sh](#3-homelab-backupsh) | Config/data archive with retention, rclone off-site upload and BackUpTrace reporting |
| [TermuxInfo.sh](#4-termuxinfosh) | Wi-Fi and battery info on Android (Termux) |

> **Secrets:** all tokens in this repo are placeholders (`<YOUR_TOKEN_HERE>`, `<TOKEN>`, `CHANGE_ME`). Fill them in on the target machine only — never commit real values.

---

## 1. NetworkChecker

### Description

Monitors network connectivity and sends Telegram alerts when the connection goes down or is restored. Designed to run from cron every minute.

### How it works

* Pings a target IP (`8.8.8.8`, 3 packets, 2 s timeout)
* If ping fails and the state is not already `DOWN`:
  * saves the state and the timestamp
  * sends a Telegram alert
* If the connection is back and the previous state was `DOWN`:
  * calculates downtime in minutes
  * sends a recovery message
  * removes the state files

Only one alert is sent per outage thanks to the state file.

### Use case: home internet monitoring over a VPN tunnel

The script can watch a **remote** network, not only the local one. Run it on an external server (VPS / VPN server) and point `IP` at the home side of a VPN tunnel (WireGuard, OpenVPN, etc.):

```
VPS (NetworkChecker, cron) ──VPN tunnel──> home router / home server (e.g. 10.8.0.2)
```

* The home router or server keeps the tunnel up through the home internet connection
* If home internet goes down, the tunnel drops and the ping fails → **"home has no internet"** alert
* When the internet comes back, the tunnel reconnects → recovery message with the downtime

Because the alert is sent from the VPS, it arrives even while the home network is offline.

```bash
IP="10.8.0.2"   # VPN address of the home router/server
```

> A failed ping can also mean the home router/server itself is down or the VPN service has stopped, so treat the alert as "home is unreachable".

### Configuration

```bash
IP="8.8.8.8"
BOT_TOKEN="<YOUR_TOKEN_HERE>"
CHAT_ID="<TELEGRAM_CHAT_ID>"
```

### State files

```
/tmp/ping_state      # present while the connection is down
/tmp/ping_down_time  # Unix timestamp of when it went down
```

### Cron setup

```bash
* * * * * /path/to/NetworkChecker
```

### Example notifications

```
📶 Network is offline
✅ Connection restored. Downtime: X min
```

---

## 2. pam-tg-notify.sh

### Description

Single-file login notifier. Hooks into PAM via `pam_exec` and sends a Telegram message every time a new **SSH** or **Cockpit** session is opened.

### Commands

```bash
sudo ./pam-tg-notify.sh install    # register the script in /etc/pam.d/sshd and /etc/pam.d/cockpit
sudo ./pam-tg-notify.sh uninstall  # remove it from PAM
./pam-tg-notify.sh test            # send a test message to Telegram
```

When called by PAM (no arguments) it sends the login notification.

### Configuration

```bash
BOT_TOKEN="<TOKEN>"     # Telegram bot token (from BotFather)
CHAT_ID="<CHAT_ID>"     # your user ID or group ID
IGNORE_IPS=""           # space-separated IPs that should not trigger alerts, e.g. "10.0.0.5 192.168.1.10"
SERVER_NAME="$(hostname)"  # name shown in notifications, e.g. "BAM Server"
```

### What `install` does

* Requires root; installs `curl` via `apt-get` if missing
* Sets the script to `chmod 700` (it contains the bot token)
* For each PAM service (`sshd`, `cockpit`) that exists:
  * makes a backup `/etc/pam.d/<service>.bak`
  * appends `session optional pam_exec.so /full/path/to/script`
  * skips services that are missing or already configured
* Warns if `UsePAM yes` is not found in `sshd_config`

> Install the script in its final location first — PAM stores the absolute path. If you move it, run `uninstall` and `install` again.

### Behaviour

* Reacts only to `open_session` (session close is ignored)
* Skips logins from `IGNORE_IPS`
* Sends the message in the background, so login is never delayed
* `optional` PAM entry: a failure of the script never blocks a login

### Example notification

```
🔐 Login on pve via SSH
User: root
From: 192.168.1.50
Time: 2026-10-09 14:32:10 CEST
```

---

## 3. homelab-backup.sh

### Description

Generic config/data backup for a single server (replaces the old `proxmox-backup.sh`). Creates a `.tar.gz` archive with the original filesystem paths preserved, keeps the last N archives, and can optionally:

* upload backups off-site with **rclone** (Google Drive, S3, B2, SFTP, …)
* report the result of every job to a **BackUpTrace**-compatible HTTP endpoint

### Requirements

* Required: `bash 4+`, `tar`, `gzip`
* Optional: `dpkg` (package list), `rsync` (faster, excluded paths are never read), `rclone`, `curl`

### Quick start

```bash
# 1. Edit the CONFIGURATION section (or create homelab-backup.conf next to the script)
# 2. Run once by hand
sudo ./homelab-backup.sh
# 3. Schedule it in root's crontab
0 3 * * * /opt/homelab-backup/homelab-backup.sh >> /var/log/homelab-backup.log 2>&1
```

### Configuration

#### Backup

| Variable | Default | Description |
|---|---|---|
| `BACKUP_NAME` | `my-server` | Archive base name → `<BACKUP_NAME>-<YYYY-MM-DD_HH-MM>.tar.gz`. Letters, digits, `.`, `_`, `-` only |
| `BACKUP_DIR` | `/mnt/backups/daily` | Where local archives are stored |
| `RETENTION_COUNT` | `3` | How many archives of this `BACKUP_NAME` to keep. `0` disables retention |
| `MIN_EXPECTED_SIZE` | `0` | Mark the backup as `warning` if the archive is smaller (bytes). `0` disables |
| `BACKUP_ITEMS` | array | Absolute paths of files/directories to back up |
| `EXCLUDED_ITEMS` | array | Absolute paths that must never be archived (no wildcards) |

`EXCLUDED_ITEMS` rules:

* exact match or parent of a `BACKUP_ITEMS` entry → the whole entry is skipped
* path inside a `BACKUP_ITEMS` directory → only that sub-path is dropped
* rules that match nothing are reported in the log (likely typos)

#### rclone (off-site copy)

| Variable | Default | Description |
|---|---|---|
| `RCLONE_ENABLED` | `false` | Upload `BACKUP_DIR` after the archive is created |
| `RCLONE_BIN` | `/usr/bin/rclone` | Path to rclone |
| `RCLONE_DEST` | `myremote:backups/my-server/` | `<remote>:<path>` of a configured rclone remote |
| `RCLONE_MODE` | `sync` | `sync` mirrors `BACKUP_DIR` (deletes on remote), `copy` only uploads |
| `RCLONE_FLAGS` | `(--checksum)` | Extra flags for rclone |

#### BackUpTrace (optional monitoring)

| Variable | Default | Description |
|---|---|---|
| `BACKUPTRACE_ENABLED` | `false` | Send a JSON event per job |
| `BACKUPTRACE_URL` | `http://backuptrace.example.lan/api/v1/backup-events` | Endpoint |
| `BACKUPTRACE_API_KEY` | `CHANGE_ME` | Sent as `X-API-Key`. Set it in the `.conf` file, not in the script |
| `BACKUPTRACE_SOURCE_NAME` | `my-server` | Source name on the dashboard |
| `BACKUPTRACE_ARCHIVE_JOB` | `local-archive` | Job name for the archive step |
| `BACKUPTRACE_SYNC_JOB` | `offsite-sync` | Job name for the rclone step |
| `STALE_AFTER_DAYS` | `2` | When the dashboard should treat the job as stale (sent as `stale_after_hours`, fractions allowed) |

#### External config file

If `homelab-backup.conf` exists next to the script (or the path in the `CONFIG_FILE` env var), it is sourced **after** the defaults, so any variable — arrays included — can be overridden there. Keep API keys in this file and **out of git**.

```bash
# homelab-backup.conf
BACKUP_NAME="pve"
BACKUP_DIR="/mnt/backups/pve"
BACKUP_ITEMS=( "/etc/pve" "/etc/network/interfaces" "/etc/ssh" "/root/scripts" )
RCLONE_ENABLED=true
RCLONE_DEST="gdrive:Backups/pve/"
```

### How it works

1. Validates the configuration (fails fast on bad values)
2. Copies every `BACKUP_ITEMS` entry into a temp dir, preserving the full path (`rsync --relative`, or `cp -a` fallback), applying exclusions
3. Saves system metadata into `meta/`
4. Creates the `.tar.gz` archive (a half-written archive is removed on failure)
5. Applies retention — only archives of the same `BACKUP_NAME` with a strict date pattern are touched
6. Uploads via rclone (skipped if the archive step failed)
7. Reports each step to BackUpTrace (a failed report never fails the backup)

The temp dir is always cleaned up, even if the script dies.

### Metadata in the archive

```
meta/packages.list   # dpkg --get-selections (if dpkg is available)
meta/uname.txt       # kernel/system info
meta/lsblk.txt       # disk layout
```

### Job statuses and exit code

| Status | When |
|---|---|
| `success` | Archive created without errors |
| `warning` | Some items failed to copy, or archive is smaller than `MIN_EXPECTED_SIZE` |
| `failed` | `tar` failed, or rclone failed |

Exit code: `0` on success/warning, `1` if the archive or the upload failed.

### Output example

```
/mnt/backups/daily/my-server-2026-10-09_03-00.tar.gz
```

### Restore (quick guide)

```bash
# 1. Inspect, then extract to the original paths
tar -tzf my-server-*.tar.gz | less
tar -xzf my-server-*.tar.gz -C /

# 2. Restore packages (Debian/Ubuntu)
dpkg --set-selections < /meta/packages.list
apt-get update
apt-get dselect-upgrade -y

# 3. Restart services
systemctl restart networking
mount -a
```

---

## 4. TermuxInfo.sh

### Description

Displays device status in Termux (Android).

### What it shows

* **Wi-Fi:** IP address, SSID, signal strength (RSSI)
* **Battery:** health, status (charging/discharging), temperature, percentage

### Dependencies

Install the Termux:API app and package:

```bash
pkg install termux-api
```

Commands used: `termux-wifi-connectioninfo`, `termux-battery-status`.

### Example output

```
WiFi Info
"ip": "192.168.1.10",
"ssid": "MyNetwork",
"rssi": -45,

Battery Info
"health": "GOOD",
"percentage": 82,
"status": "CHARGING",
"temperature": 32.1
```

---

# Summary

Wadbox provides:

* Network monitoring with Telegram alerts
* SSH / Cockpit login alerts via PAM
* Server config backups with retention, off-site upload and monitoring
* Mobile diagnostics (Termux)

Focused on simplicity, portability, and real-world usability.
