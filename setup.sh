#!/usr/bin/env bash
# claude-setup — Universal Claude installer for Mac/Linux
# Gets Claude Code running on any machine with project-specific MCP servers.
# Safe to re-run — skips anything already installed.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.sh | bash
#
# With project config:
#   CLAUDE_SETUP_CONFIG="https://example.com/claude-setup.json" \
#     curl -fsSL https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.sh | bash
#
# Config JSON format:
#   {
#     "projectName": "My Project",
#     "mcpServers": { ... },
#     "claudeDesktop": true
#   }
#
# Failure modes handled:
#   - No Homebrew on Mac (installs it)
#   - Xcode CLI tools missing (installs, handles dialog-behind-window)
#   - Apple Silicon vs Intel (handles both Homebrew paths)
#   - node@22 keg-only (links or adds to PATH)
#   - No Claude Code CLI (official installer + npm fallback)
#   - Claude Desktop installed but no CLI (installs alongside)
#   - Existing config files malformed (backs up and recreates)
#   - No python3 (manual JSON fallback)
#   - Linux without brew (uses apt/dnf/pacman)

set -euo pipefail

# ===================================================================
# CONFIG
# ===================================================================

PROJECT_NAME="Claude Code"
CONFIGURE_MCP=""
CONFIGURE_DESKTOP=false
CONFIG_JSON=""

if [[ -n "${CLAUDE_SETUP_CONFIG:-}" ]]; then
    CONFIG_JSON=$(curl -fsSL "$CLAUDE_SETUP_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$CONFIG_JSON" ]] && command -v python3 &>/dev/null; then
        PROJECT_NAME=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;c=json.load(sys.stdin);print(c.get('projectName','Claude Code'))" 2>/dev/null || echo "Claude Code")
        CONFIGURE_MCP=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;c=json.load(sys.stdin);print('yes' if c.get('mcpServers') else '')" 2>/dev/null || echo "")
        CONFIGURE_DESKTOP=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;c=json.load(sys.stdin);print('true' if c.get('claudeDesktop') else 'false')" 2>/dev/null || echo "false")
    elif [[ -n "$CONFIG_JSON" ]]; then
        # No python3 — try basic parsing
        if echo "$CONFIG_JSON" | grep -q '"mcpServers"'; then CONFIGURE_MCP="yes"; fi
        if echo "$CONFIG_JSON" | grep -q '"claudeDesktop".*true'; then CONFIGURE_DESKTOP=true; fi
    fi
fi

# ===================================================================
# HELPERS
# ===================================================================

STEP=0
TOTAL_STEPS=4
if [[ -n "$CONFIGURE_MCP" ]]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi

IS_MAC=false
IS_LINUX=false
if [[ "$(uname)" == "Darwin" ]]; then IS_MAC=true; else IS_LINUX=true; fi

show_step()   { STEP=$((STEP + 1)); echo ""; echo "  [$STEP/$TOTAL_STEPS] $1"; }
show_ok()     { echo "         ✓ $1"; }
show_action() { echo "         $1"; }
show_warn()   { echo "         ⚠ $1"; }
show_error()  { echo "         ✗ $1"; }

ensure_brew() {
    if command -v brew &>/dev/null; then return 0; fi
    if [[ "$IS_LINUX" == "true" ]]; then return 1; fi  # Don't force brew on Linux

    echo "         Installing Homebrew... (may ask for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Apple Silicon vs Intel
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist
        local shell_rc="$HOME/.zprofile"
        if ! grep -q 'homebrew' "$shell_rc" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$shell_rc"
        fi
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! command -v brew &>/dev/null; then
        show_error "Homebrew installed but not in PATH."
        show_warn "Close this terminal, open a new one, and run the setup command again."
        exit 1
    fi
}

install_node_linux() {
    # Try system package managers
    if command -v apt-get &>/dev/null; then
        # NodeSource setup for modern Node
        show_action "Adding NodeSource repository..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - 2>/dev/null || true
        sudo apt-get install -y nodejs 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y nodejs 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm nodejs npm 2>/dev/null || true
    fi
}

merge_mcp_config() {
    # Merges MCP servers from CONFIG_JSON into a target config file.
    local target_path="$1"

    if ! command -v python3 &>/dev/null; then
        # No python3 — write config directly (loses existing entries)
        if [[ -f "$target_path" ]]; then
            cp "$target_path" "${target_path}.bak"
        fi
        echo "$CONFIG_JSON" | python3 -c "
import sys, json
config_json = json.load(sys.stdin)
mcp_servers = config_json.get('mcpServers', {})
print(json.dumps({'mcpServers': mcp_servers}, indent=2))
" > "$target_path" 2>/dev/null || echo "$CONFIG_JSON" > "$target_path"
        return
    fi

    python3 << PYEOF
import json, os, sys, shutil

target = "$target_path"
config_input = '''$CONFIG_JSON'''

try:
    new_config = json.loads(config_input)
    new_servers = new_config.get("mcpServers", {})
except (json.JSONDecodeError, ValueError):
    print("         ⚠ Could not parse project config", file=sys.stderr)
    sys.exit(0)

if not new_servers:
    sys.exit(0)

# Read existing
try:
    with open(target) as f:
        existing = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    if os.path.exists(target):
        shutil.copy2(target, target + ".bak")
        print("         ⚠ Backed up malformed config", file=sys.stderr)
    existing = {}

existing.setdefault("mcpServers", {})
existing["mcpServers"].update(new_servers)

os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
}

# ===================================================================
# BANNER
# ===================================================================

echo ""
echo "  ========================================"
echo "  $PROJECT_NAME - Setup"
echo "  ========================================"
echo ""
echo "  This will install and configure everything"
echo "  you need. Takes about 5 minutes."

# ===================================================================
# STEP 1: Xcode CLI tools (Mac only) + Node.js
# ===================================================================
show_step "Node.js"

# Mac: ensure Xcode CLI tools (provides git, needed by brew)
if [[ "$IS_MAC" == "true" ]] && ! xcode-select -p &>/dev/null; then
    show_action "Installing Xcode command line tools..."
    xcode-select --install 2>/dev/null || true
    echo ""
    show_warn "A dialog box may have appeared (check BEHIND this window)."
    show_warn "Click 'Install' and wait for it to finish."
    show_warn "Then run the setup command again."
    exit 0
fi

if command -v node &>/dev/null; then
    NODE_VERSION=$(node --version | sed 's/^v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    if [[ "$NODE_MAJOR" -ge 18 ]]; then
        show_ok "Ready (v$NODE_VERSION)."
    else
        show_action "Found v$NODE_VERSION but need v18+. Upgrading..."
        if [[ "$IS_MAC" == "true" ]]; then
            ensure_brew
            brew install node@22 2>/dev/null || brew upgrade node 2>/dev/null || true
        else
            install_node_linux
        fi
        if command -v node &>/dev/null; then
            show_ok "Upgraded to $(node --version)."
        else
            show_error "Could not upgrade Node.js."
            show_warn "Please install from https://nodejs.org (LTS) and run this script again."
            exit 1
        fi
    fi
else
    show_action "Installing Node.js..."
    if [[ "$IS_MAC" == "true" ]]; then
        ensure_brew
        brew install node@22 2>/dev/null || brew install node 2>/dev/null || true
        # node@22 is keg-only — may need linking
        if ! command -v node &>/dev/null; then
            brew link --overwrite node@22 2>/dev/null || true
            NODE_BREW_PATH="$(brew --prefix)/opt/node@22/bin"
            if [[ -d "$NODE_BREW_PATH" ]]; then
                export PATH="$NODE_BREW_PATH:$PATH"
                # Persist
                local_rc="$HOME/.zprofile"
                if ! grep -q 'node@22' "$local_rc" 2>/dev/null; then
                    echo "export PATH=\"$NODE_BREW_PATH:\$PATH\"" >> "$local_rc"
                fi
            fi
        fi
    else
        install_node_linux
    fi

    if ! command -v node &>/dev/null; then
        show_error "Could not install Node.js."
        show_warn "Please install from https://nodejs.org (LTS) and run this script again."
        exit 1
    fi
    show_ok "Installed ($(node --version))."
fi

# ===================================================================
# STEP 2: Claude Code CLI
# ===================================================================
show_step "Claude Code"

# Detect Claude Desktop
CLAUDE_DESKTOP=false
if [[ "$IS_MAC" == "true" ]]; then
    if [[ -d "/Applications/Claude.app" ]] || [[ -d "$HOME/Applications/Claude.app" ]]; then
        CLAUDE_DESKTOP=true
    fi
else
    # Linux — check common locations
    if command -v claude-desktop &>/dev/null || [[ -f /usr/bin/claude-desktop ]]; then
        CLAUDE_DESKTOP=true
    fi
fi

if command -v claude &>/dev/null; then
    show_ok "Ready."
    if [[ "$CLAUDE_DESKTOP" == "true" ]]; then
        show_ok "Claude Desktop also detected — both work fine together."
    fi
else
    if [[ "$CLAUDE_DESKTOP" == "true" ]]; then
        show_action "Claude Desktop detected but CLI not installed."
        show_action "Installing Claude Code CLI alongside Desktop..."
    else
        show_action "Installing Claude Code CLI..."
    fi

    installed=false

    # Primary: official installer
    if curl -fsSL https://claude.ai/install.sh 2>/dev/null | sh 2>/dev/null; then true; fi
    export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.claude:$PATH"
    if command -v claude &>/dev/null; then installed=true; fi

    # Fallback: npm global (may need sudo on Linux)
    if [[ "$installed" == "false" ]]; then
        show_action "Trying npm install..."
        if [[ "$IS_LINUX" == "true" ]] && [[ "$(id -u)" -ne 0 ]]; then
            sudo npm install -g @anthropic-ai/claude-code 2>/dev/null || true
        else
            npm install -g @anthropic-ai/claude-code 2>/dev/null || true
        fi
        # npm global bin might not be in PATH
        NPM_BIN=$(npm config get prefix 2>/dev/null)/bin
        export PATH="$NPM_BIN:$PATH"
        if command -v claude &>/dev/null; then installed=true; fi
    fi

    if [[ "$installed" == "false" ]]; then
        show_error "Could not install Claude Code."
        show_warn "Please try: npm install -g @anthropic-ai/claude-code"
        show_warn "then run this script again."
        exit 1
    fi
    show_ok "Installed."
fi

# ===================================================================
# STEP 3: Configure MCP servers (if project config provided)
# ===================================================================
if [[ -n "$CONFIGURE_MCP" ]]; then
    show_step "MCP servers"

    # Claude Code CLI config
    merge_mcp_config "$HOME/.claude.json"
    show_ok "MCP servers -> .claude.json (CLI)"

    # Claude Desktop config (if installed or requested)
    if [[ "$CLAUDE_DESKTOP" == "true" ]] || [[ "$CONFIGURE_DESKTOP" == "true" ]]; then
        if [[ "$IS_MAC" == "true" ]]; then
            desktop_config="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
        else
            desktop_config="$HOME/.config/Claude/claude_desktop_config.json"
        fi
        merge_mcp_config "$desktop_config"
        show_ok "MCP servers -> Desktop config"
    fi
fi

# ===================================================================
# STEP 4: Verify
# ===================================================================
show_step "Verification"
all_good=true

# Node.js
v=$(node --version 2>/dev/null || echo "")
if [[ -n "$v" ]]; then
    show_ok "Node.js $v"
else
    show_error "Node.js: NOT FOUND"
    all_good=false
fi

# Claude Code
if command -v claude &>/dev/null; then
    show_ok "Claude Code: installed"
else
    show_error "Claude Code: NOT FOUND"
    all_good=false
fi

# MCP config
if [[ -n "$CONFIGURE_MCP" ]] && command -v python3 &>/dev/null; then
    config_path="$HOME/.claude.json"
    if [[ -f "$config_path" ]]; then
        mcp_check=$(python3 -c "
import json, sys
try:
    c = json.load(open('$config_path'))
    servers = list(c.get('mcpServers', {}).keys())
    if servers:
        for s in servers: print(f'         ✓ MCP server: {s}')
    else:
        print('FAIL')
except:
    print('FAIL')
" 2>/dev/null)
        if [[ "$mcp_check" == "FAIL" ]]; then
            show_error "MCP servers: not configured"
            all_good=false
        else
            echo "$mcp_check"
        fi
    else
        show_error "MCP config: .claude.json not found"
        all_good=false
    fi
fi

# ===================================================================
# RESULT
# ===================================================================
echo ""
if [[ "$all_good" == "true" ]]; then
    echo "  ========================================"
    echo "  ✓ Setup complete! Everything looks good."
    echo "  ========================================"
    echo ""
    echo "  To start, type:"
    echo ""
    echo "    claude"
    echo ""
    echo "  It will ask you to log in on first launch."
    echo "  Sign in with your Anthropic account in the"
    echo "  browser, then come back to the terminal."
    echo ""
else
    echo "  ========================================"
    echo "  ✗ Setup had issues (see above)."
    echo "  ========================================"
    echo ""
    show_warn "Try: close this terminal, open a new one,"
    show_warn "and run the setup command again."
    show_warn ""
    show_warn "If it still fails, send a screenshot to your contact."
    echo ""
fi
