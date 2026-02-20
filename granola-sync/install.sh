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
# - The "client context" shared folder in your Drive
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

# Check shared folder exists
SHARED_FOLDER="$GDRIVE_DIR/$GDRIVE_MOUNT/My Drive/client context/loblaw digital"
if [ ! -d "$SHARED_FOLDER" ]; then
  echo ""
  echo "⚠️  The shared folder 'client context/loblaw digital' isn't in your Drive yet."
  echo "   Ask Ed to share the 'client context' folder with you."
  echo "   Once it appears in your Google Drive, re-run this script."
  exit 1
fi
echo "  ✓ Shared folder found"

# ── Install ──────────────────────────────────────
echo ""
echo "Installing..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

# Download the sync script from GitHub
curl -fsSL "$SCRIPT_URL" -o "$INSTALL_DIR/sync.js"
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
