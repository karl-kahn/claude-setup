# claude-setup

One-command installer for [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) on Windows, Mac, and Linux.

Handles dependency installation (Node.js, Git Bash on Windows), Claude Code CLI setup, and optional project-specific MCP server configuration. Designed for non-technical users on machines in unknown states.

## Quick start

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.ps1 | iex
```

### Mac / Linux (Terminal)

```bash
curl -fsSL https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.sh | bash
```

## With project config

Pass a URL to a JSON config file to auto-configure MCP servers:

### Windows

```powershell
$env:CLAUDE_SETUP_CONFIG = "https://raw.githubusercontent.com/your-org/your-project/main/claude-setup.json"
irm https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.ps1 | iex
```

### Mac / Linux

```bash
CLAUDE_SETUP_CONFIG="https://raw.githubusercontent.com/your-org/your-project/main/claude-setup.json" \
  curl -fsSL https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.sh | bash
```

## Config format

```json
{
  "projectName": "My Project Search",
  "mcpServers": {
    "my-server": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": {
        "Authorization": "Bearer token-here"
      }
    }
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `projectName` | No | Shown in the setup banner (default: "Claude Code") |
| `mcpServers` | No | MCP server configs to write to `.claude.json` |

## What it installs

| Dependency | Windows | Mac | Linux |
|-----------|---------|-----|-------|
| **Node.js 18+** | winget → MSI download | Homebrew | apt/dnf/pacman → NodeSource |
| **Git Bash** | winget → direct download | n/a | n/a |
| **Claude Code CLI** | winget → npm | official installer → npm | official installer → npm |

## What it configures

- **`~/.claude/settings.json`** — `CLAUDE_CODE_GIT_BASH_PATH` (Windows only, most reliable method)
- **`CLAUDE_CODE_GIT_BASH_PATH`** env var — set in User scope + current session (Windows only)
- **`~/.claude.json`** — MCP server entries (if config provided)
- **`HOME`** env var — set if missing (Windows only)

## Windows Git Bash handling

Claude Code on Windows requires Git Bash (`bash.exe`). This is the #1 failure point in the wild. The installer:

1. Searches 6+ locations (Program Files, scoop, chocolatey, GitHub Desktop, user installs)
2. Falls back to finding `git.exe` on PATH and deriving `bash.exe` from it
3. Last resort: recursive search of Program Files
4. Explicitly excludes WSL's `bash.exe` (System32/WindowsApps)
5. Writes the path to `settings.json` (Claude Code reads this on startup — bypasses env var propagation issues)
6. Also sets the env var and adds Git\bin to PATH (belt and suspenders)

## Re-running

Safe to run multiple times. Skips anything already installed. Backs up config files before modifying if they're malformed.

## Troubleshooting

If setup completes but `claude` still doesn't work:

1. **Close the terminal and open a new one** — env var and PATH changes require a new session
2. **Run the setup command again** — it will verify and fix anything that's off
3. **Send a screenshot** — the verification step at the end shows exactly what's working and what's not
