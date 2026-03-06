#!/usr/bin/env bash
set -u

# Universal Control Auto-Reconnect for macOS
#
# Monitors UniversalControl's TCP connections to detect when the peer
# link has dropped, and only restarts UC when needed. When connected,
# UC maintains ESTABLISHED TCP connections to the peer — we use lsof
# to check for these.
#
# Usage:
#   ./uc-autoreconnect.sh
#   UC_CHECK_INTERVAL=10 ./uc-autoreconnect.sh

CHECK_INTERVAL="${UC_CHECK_INTERVAL:-10}"    # how often to check (seconds)
GRACE_PERIOD="${UC_GRACE_PERIOD:-30}"        # seconds after restart before checking again
STARTUP_GRACE="${UC_STARTUP_GRACE:-60}"      # seconds to wait on first launch before monitoring
LOG_FILE="${UC_LOG_FILE:-/tmp/uc-autoreconnect.log}"

emit() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  if [[ -t 1 ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

ensure_settings() {
  local changed=0

  local tcpka
  tcpka="$(pmset -g custom 2>/dev/null | awk '/tcpkeepalive/{val=$2} END{print val+0}')"
  if [[ "$tcpka" -eq 0 ]]; then
    emit "Fixing: tcpkeepalive is OFF, turning ON"
    sudo pmset -a tcpkeepalive 1 2>/dev/null && changed=1 \
      || emit "  (needs sudo — run: sudo pmset -a tcpkeepalive 1)"
  fi

  local uc_reconnect
  uc_reconnect="$(defaults read com.apple.universalcontrol ShouldAutoReconnect 2>/dev/null || echo "0")"
  if [[ "$uc_reconnect" != "1" ]]; then
    emit "Fixing: ShouldAutoReconnect -> ON"
    defaults write com.apple.universalcontrol ShouldAutoReconnect -bool true
    changed=1
  fi

  local uc_enabled
  uc_enabled="$(defaults read com.apple.universalcontrol Enabled 2>/dev/null || echo "1")"
  if [[ "$uc_enabled" == "0" ]]; then
    emit "Fixing: Universal Control -> enabled"
    defaults write com.apple.universalcontrol Enabled -bool true
    changed=1
  fi

  local uc_push
  uc_push="$(defaults read com.apple.universalcontrol AllowPushThrough 2>/dev/null || echo "0")"
  if [[ "$uc_push" != "1" ]]; then
    emit "Fixing: AllowPushThrough -> ON"
    defaults write com.apple.universalcontrol AllowPushThrough -bool true
    changed=1
  fi

  if [[ "$changed" -eq 1 ]]; then
    emit "Settings updated"
  else
    emit "All settings OK"
  fi
}

uc_is_connected() {
  local pid
  pid="$(pgrep UniversalControl | head -1)"
  [[ -z "$pid" ]] && return 1

  # Check for ESTABLISHED TCP connections to a peer
  lsof -a -i -p "$pid" 2>/dev/null | grep -q "ESTABLISHED"
}

restart_uc() {
  # Try SIGTERM first, give it a chance to clean up
  killall UniversalControl 2>/dev/null || true
  sleep 2

  # If still running, force kill
  if pgrep -q "UniversalControl"; then
    killall -9 UniversalControl 2>/dev/null || true
    sleep 2
  fi

  local retries=0
  while ! pgrep -q "UniversalControl" && [[ "$retries" -lt 5 ]]; do
    sleep 1
    retries=$((retries + 1))
  done

  if pgrep -q "UniversalControl"; then
    emit "UC restarted (PID $(pgrep UniversalControl | head -1))"
  else
    emit "WARNING: UC did not relaunch"
  fi
}

main() {
  emit "========================================="
  emit "UC Auto-Reconnect (PID $$)"
  emit "Check interval: ${CHECK_INTERVAL}s"
  emit "Grace period: ${GRACE_PERIOD}s"
  emit "========================================="

  ensure_settings

  emit "Startup grace: waiting ${STARTUP_GRACE}s for UC to establish connections"
  sleep "$STARTUP_GRACE"

  local consecutive_disconnected=0

  while true; do
    sleep "$CHECK_INTERVAL"

    if ! pgrep -q "UniversalControl"; then
      emit "UC not running — waiting for macOS to launch it"
      consecutive_disconnected=0
      continue
    fi

    if uc_is_connected; then
      if [[ "$consecutive_disconnected" -gt 0 ]]; then
        emit "Connection restored"
      fi
      consecutive_disconnected=0
      continue
    fi

    consecutive_disconnected=$((consecutive_disconnected + 1))

    # Require 3 consecutive failed checks (~30s) before restarting
    # to avoid reacting to brief transient blips
    if [[ "$consecutive_disconnected" -lt 3 ]]; then
      emit "No peer connection detected (check $consecutive_disconnected/3)"
      continue
    fi

    emit "Peer disconnected for ${consecutive_disconnected} checks — restarting UC"
    restart_uc
    consecutive_disconnected=0

    # Grace period after restart to let UC re-establish
    emit "Waiting ${GRACE_PERIOD}s grace period"
    sleep "$GRACE_PERIOD"
  done
}

trap 'emit "Stopped (PID $$)"; exit 0' SIGINT SIGTERM

# Top-level retry loop: if main exits unexpectedly, log and restart it
while true; do
  main "$@" || emit "ERROR: main exited unexpectedly (exit $?), restarting in 10s"
  sleep 10
done

# --- launchd agent ---
#
#   launchctl load ~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
#   launchctl unload ~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
