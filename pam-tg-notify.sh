#!/bin/bash
# =============================================================================
# Login notifier for Telegram: SSH + Cockpit (single-file version)
#
# Usage:
#   ./pam-tg-notify.sh install    - register this script in PAM (sshd + cockpit if present)
#   ./pam-tg-notify.sh uninstall  - remove this script from PAM
#   ./pam-tg-notify.sh test       - send a test message to Telegram
#
# When called by pam_exec (no arguments), sends a notification
# every time a new SSH or Cockpit session is opened.
# =============================================================================

# ---- Settings ---------------------------------------------------------------
BOT_TOKEN="<TOKEN>"  # Telegram bot token (from BotFather)
CHAT_ID="<CHAT_ID>"  # Telegram chat ID (your user ID or group ID)

# IPs that should NOT trigger notifications (space-separated), e.g. "10.0.0.5 192.168.1.10"
IGNORE_IPS=""

# Server name shown in notifications; defaults to the system hostname
SERVER_NAME="$(hostname)"
# -----------------------------------------------------------------------------

SCRIPT_PATH="$(readlink -f "$0")"
PAM_LINE="session optional pam_exec.so ${SCRIPT_PATH}"

# PAM services to hook into; missing ones are silently skipped
PAM_SERVICES="sshd cockpit"

# Send a message via Telegram Bot API
send_message() {
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode text="$1"
}

case "$1" in
    install)
        [ "$EUID" -eq 0 ] || { echo "Error: run as root"; exit 1; }
        command -v curl > /dev/null || { echo "Installing curl..."; apt-get install -y curl; }

        # Script contains the token, so only root may read it
        chmod 700 "$SCRIPT_PATH"

        for svc in $PAM_SERVICES; do
            pam_file="/etc/pam.d/${svc}"

            if [ ! -f "$pam_file" ]; then
                echo "[${svc}] not found, skipped"
                continue
            fi

            if grep -qF "pam_exec.so ${SCRIPT_PATH}" "$pam_file"; then
                echo "[${svc}] already installed"
            else
                cp "$pam_file" "${pam_file}.bak"
                echo "$PAM_LINE" >> "$pam_file"
                echo "[${svc}] installed (backup: ${pam_file}.bak)"
            fi
        done

        grep -qiE '^\s*UsePAM\s+yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            || echo "Warning: make sure 'UsePAM yes' is set in sshd_config"
        exit 0
        ;;

    uninstall)
        [ "$EUID" -eq 0 ] || { echo "Error: run as root"; exit 1; }

        for svc in $PAM_SERVICES; do
            pam_file="/etc/pam.d/${svc}"
            [ -f "$pam_file" ] || continue
            sed -i "\|pam_exec.so ${SCRIPT_PATH}|d" "$pam_file"
            echo "[${svc}] removed"
        done
        exit 0
        ;;

    test)
        send_message "✅ Test message from ${SERVER_NAME}"
        echo
        exit 0
        ;;
esac

# ---- PAM mode ---------------------------------------------------------------

# React only to session opening (ignore close_session)
[ "$PAM_TYPE" = "open_session" ] || exit 0

# Skip trusted IPs
for ip in $IGNORE_IPS; do
    [ "$PAM_RHOST" = "$ip" ] && exit 0
done

# Human-readable source of the login
case "$PAM_SERVICE" in
    sshd)    SOURCE="SSH" ;;
    cockpit) SOURCE="Cockpit (web)" ;;
    *)       SOURCE="${PAM_SERVICE:-unknown}" ;;
esac

TEXT="🔐 Login on ${SERVER_NAME} via ${SOURCE}
User: ${PAM_USER}
From: ${PAM_RHOST:-unknown}
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# Send in background so login is never delayed
send_message "$TEXT" > /dev/null 2>&1 &

exit 0