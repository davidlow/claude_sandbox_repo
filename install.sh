#!/bin/bash
set -e

echo "⚙️  Detecting system and installing Docker..."

# 1. Install Docker using the official cross-platform script
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
else
    echo "✅ Docker is already installed."
fi

# 2. Configure user groups
sudo usermod -aG docker $USER

# 3. Build the core sandbox image
echo "📦 Building the Claude Code Docker sandbox image..."
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build -t claude-sandbox -f "$REPO_DIR/Dockerfile.claude" "$REPO_DIR"

# 4. Inject global aliases into ~/.bashrc if they don't exist
echo "🔗 Registering global CLI wrappers in ~/.bashrc..."

if ! grep -q "alias claude-box=" ~/.bashrc; then
    echo "alias claude-box='$REPO_DIR/launch-interactive.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-yolo=" ~/.bashrc; then
    echo "alias claude-yolo='$REPO_DIR/launch-scripted.sh'" >> ~/.bashrc
fi

echo "=========================================================="
echo "🎉 Setup Complete!"
echo "👉 CRITICAL: If you are on a Chromebook, right-click the Terminal"
echo "   app icon and select 'Shut down Linux', then reopen it."
echo "👉 On native Debian, run: source ~/.bashrc (or open a new window)."
echo "=========================================================="
