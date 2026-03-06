# UC Auto-Reconnect

Smart auto-reconnect for **macOS Universal Control**. Instead of blindly restarting UniversalControl on a timer (which causes drops), this script monitors the actual TCP connections to the peer device and only restarts when the link has genuinely dropped.

## The Problem

Universal Control uses Bluetooth/AWDL which can silently drop even when the peer is reachable over IP. Apple's built-in auto-reconnect doesn't always kick in reliably. Naive timer-based restart scripts make things worse by killing healthy connections.

## How It Works

1. Checks every 10s whether UniversalControl has `ESTABLISHED` TCP connections to a peer device (via `lsof`)
2. If no connections are found for **3 consecutive checks** (~30s), it restarts UniversalControl
3. After restarting, waits a **30s grace period** before resuming checks
4. On startup, waits **60s** before monitoring (gives UC time to establish connections after login)

When UC is healthy, the script does nothing.

## Install

```bash
# Clone the repo
git clone https://github.com/shailshah9/uc-autoreconnect.git
cd uc-autoreconnect

# Copy the script
cp uc-autoreconnect.sh ~/Scripts/
chmod +x ~/Scripts/uc-autoreconnect.sh

# Update the plist with your script path
sed -i '' "s|/Users/sshah31/Projects/tools-prompts-misc/scripts|$HOME/Scripts|" com.user.uc-autoreconnect.plist

# Install the LaunchAgent (runs on login, auto-restarts)
cp com.user.uc-autoreconnect.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
```

## Configuration

Environment variables (set in the plist or export before running):

| Variable | Default | Description |
|---|---|---|
| `UC_CHECK_INTERVAL` | `10` | Seconds between connection checks |
| `UC_GRACE_PERIOD` | `30` | Seconds to wait after a restart before checking again |
| `UC_STARTUP_GRACE` | `60` | Seconds to wait on first launch before monitoring |
| `UC_LOG_FILE` | `/tmp/uc-autoreconnect.log` | Log file path |

## Shell Helper

Add this function to your `~/.zshrc` for easy management from the terminal:

```bash
uc() {
  local plist=~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
  local log=/tmp/uc-autoreconnect.log
  case "${1:-}" in
    status)
      echo "--- Script ---"
      ps aux | grep uc-autoreconnect | grep -v grep || echo "Not running"
      echo ""
      echo "--- UniversalControl ---"
      local pid=$(pgrep UniversalControl | head -1)
      if [[ -n "$pid" ]]; then
        echo "Running (PID $pid)"
        echo ""
        echo "--- Peer connections ---"
        lsof -a -i -p "$pid" 2>/dev/null | grep ESTABLISHED || echo "No peer connected"
      else
        echo "Not running"
      fi
      ;;
    logs)
      tail -${2:-30} "$log"
      ;;
    follow)
      tail -f "$log"
      ;;
    restart)
      launchctl unload "$plist" 2>/dev/null
      launchctl load "$plist"
      echo "Reloaded uc-autoreconnect agent"
      ;;
    stop)
      launchctl unload "$plist" 2>/dev/null
      echo "Stopped uc-autoreconnect agent"
      ;;
    start)
      launchctl load "$plist" 2>/dev/null
      echo "Started uc-autoreconnect agent"
      ;;
    kick)
      echo "Force-restarting UniversalControl..."
      killall UniversalControl 2>/dev/null
      echo "Killed UC — it should relaunch automatically"
      ;;
    *)
      echo "Usage: uc <command>"
      echo ""
      echo "  status   Show script + UC process + peer connections"
      echo "  logs [n] Show last n log lines (default 30)"
      echo "  follow   Tail logs in real-time"
      echo "  restart  Reload the launchd agent"
      echo "  stop     Stop the autoreconnect agent"
      echo "  start    Start it back up"
      echo "  kick     Force-restart UniversalControl now"
      ;;
  esac
}
```

### Commands

| Command | Description |
|---|---|
| `uc status` | Show script process, UC process, and peer connections |
| `uc logs [n]` | Show last n log lines (default 30) |
| `uc follow` | Tail logs in real-time |
| `uc restart` | Reload the launchd agent |
| `uc stop` | Stop the autoreconnect agent |
| `uc start` | Start it back up |
| `uc kick` | Force-restart UniversalControl immediately |

## How Detection Works

When Universal Control is connected to a peer (e.g. an iPad or another Mac), it maintains TCP connections over the local network:

```
UniversalControl 38409 user 5u IPv6 ... TCP [fe80::...]:56545->peer.local:56904 (ESTABLISHED)
UniversalControl 38409 user 6u IPv6 ... TCP [fe80::...]:56546->peer.local:56905 (ESTABLISHED)
```

The script checks for these `ESTABLISHED` connections. When they disappear, the peer link has dropped and UC needs a restart.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
rm ~/Library/LaunchAgents/com.user.uc-autoreconnect.plist
# Remove the uc() function from ~/.zshrc
```

## License

MIT
