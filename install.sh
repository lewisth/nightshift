#!/usr/bin/env bash
set -euo pipefail

REPO="lewisth/nightshift"
BRANCH="main"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/nightshift"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

PROMPTS="antipatterns architecture bugs dependencies documentation maintainability observability performance security solidprinciples techdebt tests"

echo "Installing nightshift..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$SHARE_DIR/prompts"

echo "  Downloading nightshift script..."
curl -fsSL "$BASE_URL/nightshift" -o "$INSTALL_DIR/nightshift"
chmod +x "$INSTALL_DIR/nightshift"

echo "  Downloading agent prompts..."
for prompt in $PROMPTS; do
    curl -fsSL "$BASE_URL/prompts/${prompt}.md" -o "$SHARE_DIR/prompts/${prompt}.md"
done

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "Warning: $INSTALL_DIR is not in your PATH."
    echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

echo ""
echo "nightshift installed to $INSTALL_DIR/nightshift"
echo "Prompts installed to $SHARE_DIR/prompts/"
echo ""

repos_root=""
read -r -p "Repos root directory [~/Developer]: " repos_root || true
repos_root="${repos_root:-~/Developer}"
repos_root_expanded="${repos_root/#\~/$HOME}"

if [[ ! -d "$repos_root_expanded" ]]; then
    echo "Error: Directory not found: $repos_root_expanded"
    echo "Run 'nightshift init' after fixing the path."
    exit 1
fi

if NS_CHECK_ROOT="$repos_root_expanded" NIGHTSHIFT_SKIP_MAIN=1 bash -c "source \"$INSTALL_DIR/nightshift\"; init_root_has_ado_repos \"\$NS_CHECK_ROOT\""; then
    echo ""
    echo "Azure DevOps repositories detected under $repos_root_expanded."
    echo "Continuing with nightshift setup (same as 'nightshift init')..."
    echo ""
    NIGHTSHIFT_INIT_REPOS_ROOT="$repos_root_expanded" "$INSTALL_DIR/nightshift" init
else
    echo ""
    echo "Run 'nightshift init' to get started."
fi
