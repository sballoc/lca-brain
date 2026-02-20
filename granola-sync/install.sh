#!/bin/bash
set -e

# ─────────────────────────────────────────────────
# LCA Granola Sync — Installer
#
# Paste this in your terminal. It will:
# 1. Download the sync script
# 2. Set up an hourly auto-sync via LaunchAgent
# 3. Run the first sync immediately
#
# Prerequisites:
# - Granola installed and logged in
# - Google Drive for Desktop installed
# - The "loblaw digital" shared folder accessible in your Drive
# ─────────────────────────────────────────────────

INSTALL_DIR="$HOME/.lca-granola-sync"
SCRIPT_URL="https://raw.githubusercontent.com/sballoc/lca-brain/main/granola-sync/sync.js"
PLIST_NAME="com.lca.granola-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG_DIR="$INSTALL_DIR/logs"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     LCA Granola Sync — Installer     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Check prerequisites ──────────────────────────
echo "Checking prerequisites..."

# Check Node.js
if ! command -v node &> /dev/null; then
  echo "❌ Node.js not found. Install it: https://nodejs.org"
  exit 1
fi
echo "  ✓ Node.js $(node -v)"

# Check Granola credentials
CREDS="$HOME/Library/Application Support/Granola/supabase.json"
if [ ! -f "$CREDS" ]; then
  echo "❌ Granola credentials not found."
  echo "   Open Granola and make sure you're logged in, then re-run."
  exit 1
fi
echo "  ✓ Granola credentials found"

# Check Google Drive
GDRIVE_DIR="$HOME/Library/CloudStorage"
if [ ! -d "$GDRIVE_DIR" ] || ! ls "$GDRIVE_DIR" | grep -q "GoogleDrive-"; then
  echo "❌ Google Drive for Desktop not found."
  echo "   Install it: https://www.google.com/drive/download/"
  echo "   Then re-run this script."
  exit 1
fi
GDRIVE_MOUNT=$(ls "$GDRIVE_DIR" | grep "GoogleDrive-" | head -1)
echo "  ✓ Google Drive found ($GDRIVE_MOUNT)"

# ── Find "loblaw digital" folder ─────────────────
# The folder can live in different places depending on how it was shared:
#   1. My Drive/client context/loblaw digital  (parent folder shared)
#   2. Shared drives/.../loblaw digital        (shared drive)
#   3. My Drive/loblaw digital                 (folder shared directly at root)
#   4. Anywhere under the mount (search)       (shortcuts, nested shares)
find_loblaw_folder() {
  local CLOUD="$GDRIVE_DIR"

  for mount in "$CLOUD"/GoogleDrive-*; do
    [ -d "$mount" ] || continue

    # 1. My Drive/client context/loblaw digital
    if [ -d "$mount/My Drive/client context/loblaw digital" ]; then
      echo "$mount/My Drive/client context/loblaw digital"
      return 0
    fi

    # 2. Shared drives — check any shared drive
    if [ -d "$mount/Shared drives" ]; then
      for shared in "$mount/Shared drives"/*/; do
        if [ -d "${shared}client context/loblaw digital" ]; then
          echo "${shared}client context/loblaw digital"
          return 0
        fi
        if [ -d "${shared}loblaw digital" ]; then
          echo "${shared}loblaw digital"
          return 0
        fi
      done
    fi

    # 3. My Drive/loblaw digital (at root)
    if [ -d "$mount/My Drive/loblaw digital" ]; then
      echo "$mount/My Drive/loblaw digital"
      return 0
    fi

    # 4. Search the entire mount (max depth 4 to avoid slow scans)
    if [ -d "$mount/My Drive" ]; then
      local found
      found=$(find "$mount/My Drive" -maxdepth 4 -type d -iname "loblaw digital" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        echo "$found"
        return 0
      fi
    fi
  done

  return 1
}

SHARED_FOLDER=$(find_loblaw_folder)
if [ -z "$SHARED_FOLDER" ]; then
  echo ""
  echo "⚠️  Can't find a 'loblaw digital' folder in your Google Drive."
  echo ""
  echo "   This can happen if the folder hasn't been shared with you yet,"
  echo "   or if Google Drive hasn't finished syncing."
  echo ""
  echo "   Ask Ed or Kio to share the 'loblaw digital' folder with you."
  echo "   Once it appears in your Google Drive, re-run this script."
  exit 1
fi
echo "  ✓ Shared folder found: $SHARED_FOLDER"

# Save the detected path so sync.js can use it
mkdir -p "$INSTALL_DIR"
echo "$SHARED_FOLDER" > "$INSTALL_DIR/.gdrive-path"

# ── Ask for name ─────────────────────────────────
echo ""
echo "What's your first name? (used to tag your transcripts)"
read -r SYNC_USER_NAME
if [ -z "$SYNC_USER_NAME" ]; then
  echo "❌ Name required."
  exit 1
fi
echo "  ✓ Got it, $SYNC_USER_NAME"

# ── Install ──────────────────────────────────────
echo ""
echo "Installing..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

# Download the sync script from GitHub
curl -fsSL "$SCRIPT_URL" -o "$INSTALL_DIR/sync.js"

# Save the user's name for the sync script
echo "$SYNC_USER_NAME" > "$INSTALL_DIR/.sync-user"
echo "  ✓ Sync script installed"

# ── Create LaunchAgent ───────────────────────────
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which node)</string>
        <string>${INSTALL_DIR}/sync.js</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/sync.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/sync-error.log</string>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLIST

# Load the agent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "  ✓ Hourly sync scheduled"

# ── Run first sync ───────────────────────────────
echo ""
echo "Running first sync now..."
echo ""
node "$INSTALL_DIR/sync.js"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           Setup complete! ✓          ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Your Loblaw meeting notes will sync to Google Drive every hour."
echo "Logs: $LOG_DIR/sync.log"
echo ""
echo "One thing to remember:"
echo "  → Save all Loblaws meetings to a folder called 'Loblaw' in Granola."
echo "    The script watches that folder."
echo ""
