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

# 2. Add current user to the docker group so they can run docker without sudo
sudo usermod -aG docker "$USER"

# 3. Ensure all scripts are executable
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$REPO_DIR/launch-interactive.sh" \
         "$REPO_DIR/launch-scripted.sh" \
         "$REPO_DIR/launch-architect.sh" \
         "$REPO_DIR/launch-qa.sh" \
         "$REPO_DIR/launch-refactor.sh" \
         "$REPO_DIR/setup-auth.sh" \
         "$REPO_DIR/entrypoint.sh" \
         "$REPO_DIR/tests/run_tests.sh" \
         "$REPO_DIR/tests"/test_*.sh

# 4. Build the sandbox image
echo "📦 Building the Claude Code Docker sandbox image..."
docker build -t claude-sandbox -f "$REPO_DIR/Dockerfile.claude" "$REPO_DIR"

# 5. Register shell aliases in ~/.bashrc (idempotent)
echo "🔗 Registering shell aliases in ~/.bashrc..."

if ! grep -q "alias claude-box=" ~/.bashrc; then
    echo "alias claude-box='$REPO_DIR/launch-interactive.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-yolo=" ~/.bashrc; then
    echo "alias claude-yolo='$REPO_DIR/launch-scripted.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-box-auth=" ~/.bashrc; then
    echo "alias claude-box-auth='$REPO_DIR/setup-auth.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-architect=" ~/.bashrc; then
    echo "alias claude-architect='$REPO_DIR/launch-architect.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-qa=" ~/.bashrc; then
    echo "alias claude-qa='$REPO_DIR/launch-qa.sh'" >> ~/.bashrc
fi

if ! grep -q "alias claude-refactor=" ~/.bashrc; then
    echo "alias claude-refactor='$REPO_DIR/launch-refactor.sh'" >> ~/.bashrc
fi

echo ""
echo "=========================================================="
echo "🎉 Installation complete!"
echo ""
echo "Next steps:"
echo ""
echo "  1. Reload your shell:"
echo "       Chromebook: right-click Terminal → 'Shut down Linux', then reopen"
echo "       Debian:     source ~/.bashrc  (or open a new terminal)"
echo ""
echo "  2. Make sure you are logged into Claude Code on this machine:"
echo "       claude auth login --claudeai"
echo ""
echo "  3. Bootstrap the sandbox credentials (once):"
echo "       claude-box-auth"
echo ""
echo "  4. Launch a session from any project directory:"
echo "       claude-box              # interactive"
echo "       claude-yolo \"task\"      # autonomous (single-stage)"
echo "       claude-architect \"task\" # multi-stage: brainstorm → evaluate → implement"
echo "       claude-qa \"scope\"       # multi-stage: test generation + adversarial audit"
echo "       claude-refactor \"task\"  # multi-stage: diagnose → plan → implement"
echo "=========================================================="
