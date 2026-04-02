#Requires -Version 5.1
# claude-setup — Universal Claude installer for Windows
# Gets Claude Code running on any Windows machine with project-specific MCP servers.
# Safe to re-run — skips anything already installed.
#
# Usage:
#   irm https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.ps1 | iex
#
# With project config:
#   $env:CLAUDE_SETUP_CONFIG = "https://raw.githubusercontent.com/org/project/main/claude-setup.json"
#   irm https://raw.githubusercontent.com/karl-kahn/claude-setup/main/setup.ps1 | iex
#
# Config JSON format:
#   {
#     "projectName": "My Project",
#     "mcpServers": { ... },
#     "claudeDesktop": true
#   }
#
# Failure modes handled:
#   - No winget (falls back to direct downloads)
#   - No Git / Git without bash.exe (exhaustive search, install, WSL exclusion)
#   - Claude Code can't find bash.exe (writes to settings.json, env vars, and PATH)
#   - Claude Desktop installed but no CLI (installs CLI alongside)
#   - Existing config files malformed (backs up and recreates)
#   - PowerShell execution policy (handled by irm|iex pattern)
#   - HOME not set (sets it)
#   - UTF-8 BOM issues (writes without BOM)
#   - Spaces in paths (quoted everywhere)
#   - PATH not updated after install (refreshes from registry)

$ErrorActionPreference = "Stop"

# ===================================================================
# CONFIG
# ===================================================================

$ProjectConfig = $null
$ProjectName = "Claude Code"
$ConfigureMcpServers = $null
$ConfigureDesktop = $false

# Load project config if provided
if ($env:CLAUDE_SETUP_CONFIG) {
    try {
        $configJson = (Invoke-WebRequest -Uri $env:CLAUDE_SETUP_CONFIG -UseBasicParsing).Content
        $ProjectConfig = $configJson | ConvertFrom-Json
        if ($ProjectConfig.projectName) { $ProjectName = $ProjectConfig.projectName }
        if ($ProjectConfig.mcpServers) { $ConfigureMcpServers = $ProjectConfig.mcpServers }
        if ($ProjectConfig.claudeDesktop) { $ConfigureDesktop = $true }
    } catch {
        Write-Host "  Warning: Could not load config from $env:CLAUDE_SETUP_CONFIG" -ForegroundColor Yellow
        Write-Host "  Continuing with default setup..." -ForegroundColor Yellow
    }
}

# ===================================================================
# HELPERS
# ===================================================================

$Step = 0
$TotalSteps = 5
if ($ConfigureMcpServers) { $TotalSteps++ }

function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$userPath;$machinePath"
}

function Show-Step {
    param([string]$Label)
    $script:Step++
    Write-Host ""
    Write-Host "  [$Step/$TotalSteps] $Label" -ForegroundColor Cyan
    Start-Sleep -Milliseconds 300
}

function Show-OK    { param([string]$M) Write-Host "         $M" -ForegroundColor Green }
function Show-Action{ param([string]$M) Write-Host "         $M" -ForegroundColor White }
function Show-Warn  { param([string]$M) Write-Host "         $M" -ForegroundColor Yellow }
function Show-Error { param([string]$M) Write-Host "         $M" -ForegroundColor Red }

function Find-GitBash {
    # Exhaustive search for bash.exe from Git for Windows.
    # Explicitly excludes WSL bash (System32, WindowsApps).
    # Returns full path or $null.

    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "$env:USERPROFILE\scoop\apps\git\current\bin\bash.exe",
        "$env:ProgramData\chocolatey\lib\git\tools\cmd\..\bin\bash.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $resolved = (Resolve-Path $c).Path
            if ($resolved -notlike "*System32*" -and $resolved -notlike "*WindowsApps*") {
                return $resolved
            }
        }
    }

    # GitHub Desktop bundles Git — check with version glob
    $ghDesktopGlob = "$env:LOCALAPPDATA\GitHubDesktop\app-*\resources\app\git\bin\bash.exe"
    $ghDesktopMatches = Resolve-Path $ghDesktopGlob -ErrorAction SilentlyContinue
    if ($ghDesktopMatches) {
        foreach ($m in $ghDesktopMatches) {
            if (Test-Path $m) { return $m.Path }
        }
    }

    # Derive from git.exe on PATH
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd -and $gitCmd.Source) {
        $gitExe = $gitCmd.Source
        # Exclude WSL/System32 git
        if ($gitExe -notlike "*System32*" -and $gitExe -notlike "*WindowsApps*") {
            # git.exe in Git\cmd -> bash.exe in Git\bin
            $gitRoot = Split-Path (Split-Path $gitExe)
            $derived = Join-Path $gitRoot "bin\bash.exe"
            if (Test-Path $derived) { return $derived }
            # git.exe in Git\bin (some installs)
            $sibling = Join-Path (Split-Path $gitExe) "bash.exe"
            if (Test-Path $sibling) { return $sibling }
        }
    }

    # Last resort: recursive search in Program Files
    foreach ($root in @("$env:ProgramFiles", "${env:ProgramFiles(x86)}")) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter "bash.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*Git*" -and $_.FullName -notlike "*System32*" } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Write-JsonFile {
    param([string]$Path, [object]$Object)
    $json = $Object | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return Get-Content $Path -Raw | ConvertFrom-Json
    } catch {
        Copy-Item $Path "$Path.bak"
        Show-Warn "$(Split-Path $Path -Leaf) was malformed -- backed up."
        return $null
    }
}

function Merge-McpServers {
    # Merges MCP server config into a JSON config file (.claude.json or Desktop config).
    param(
        [string]$ConfigPath,
        [object]$Servers
    )
    $config = Read-JsonFile $ConfigPath
    if (-not $config) { $config = [PSCustomObject]@{} }

    if (-not $config.PSObject.Properties['mcpServers']) {
        $config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
    }

    # $Servers is a PSCustomObject — iterate its properties
    foreach ($prop in $Servers.PSObject.Properties) {
        $config.mcpServers | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }

    Write-JsonFile -Path $ConfigPath -Object $config
}

# ===================================================================
# BANNER
# ===================================================================

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  $ProjectName - Setup" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This will install and configure everything" -ForegroundColor White
Write-Host "  you need. Takes about 5 minutes." -ForegroundColor White
Start-Sleep -Milliseconds 500

# ===================================================================
# STEP 1: Node.js
# ===================================================================
Show-Step "Node.js"
Refresh-Path
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue

if ($nodeCmd) {
    $nodeVersion = (node --version 2>$null) -replace '^v',''
    $nodeMajor = [int]($nodeVersion -split '\.')[0]
    if ($nodeMajor -ge 18) {
        Show-OK "Ready (v$nodeVersion)."
    } else {
        Show-Action "Found v$nodeVersion but need v18+. Upgrading..."
        $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
        if ($hasWinget) {
            winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements 2>$null
            Refresh-Path
        }
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
            Show-Error "Could not upgrade Node.js."
            Show-Warn "Please install from https://nodejs.org (LTS) and run this script again."
            exit 1
        }
        Show-OK "Upgraded to $(node --version)."
    }
} else {
    Show-Action "Installing Node.js..."
    $installed = $false

    # Try winget
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if ($hasWinget) {
        winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements 2>$null
        Refresh-Path
        if (Get-Command node -ErrorAction SilentlyContinue) { $installed = $true }
    }

    # Direct download fallback
    if (-not $installed) {
        Show-Action "Trying direct download..."
        $nodeInstaller = "$env:TEMP\node-setup.msi"
        try {
            Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.15.0/node-v22.15.0-x64.msi" `
                -OutFile $nodeInstaller -UseBasicParsing
            Start-Process msiexec.exe -ArgumentList "/i `"$nodeInstaller`" /qn" -Wait -NoNewWindow
            Remove-Item $nodeInstaller -ErrorAction SilentlyContinue
            Refresh-Path
            if (Get-Command node -ErrorAction SilentlyContinue) { $installed = $true }
        } catch { }
    }

    if (-not $installed) {
        Show-Error "Could not install Node.js."
        Show-Warn "Please install from https://nodejs.org (LTS) and run this script again."
        exit 1
    }
    Show-OK "Installed ($(node --version))."
}

# ===================================================================
# STEP 2: Git + Git Bash
# ===================================================================
Show-Step "Git Bash"
$gitBashPath = Find-GitBash

if (-not $gitBashPath) {
    Show-Action "Git Bash not found. Installing Git for Windows..."
    $installed = $false

    # Try winget
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if ($hasWinget) {
        winget install Git.Git --accept-source-agreements --accept-package-agreements 2>$null
        Refresh-Path
        $gitBashPath = Find-GitBash
        if ($gitBashPath) { $installed = $true }
    }

    # Direct download fallback
    if (-not $installed) {
        Show-Action "Trying direct download..."
        $gitInstaller = "$env:TEMP\git-setup.exe"
        try {
            Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/latest/download/Git-2.49.0-64-bit.exe" `
                -OutFile $gitInstaller -UseBasicParsing
            # /COMPONENTS=bash ensures Git Bash is included
            Start-Process $gitInstaller -ArgumentList "/VERYSILENT /NORESTART /COMPONENTS=gitlfs,assoc,assoc_sh,bash" `
                -Wait -NoNewWindow
            Remove-Item $gitInstaller -ErrorAction SilentlyContinue
            Refresh-Path
            $gitBashPath = Find-GitBash
            if ($gitBashPath) { $installed = $true }
        } catch { }
    }

    if (-not $gitBashPath) {
        Show-Error "Could not install Git Bash automatically."
        Write-Host ""
        Show-Warn "Please install Git manually:"
        Show-Warn "  1. Go to https://git-scm.com/downloads/win"
        Show-Warn "  2. Download and run the installer"
        Show-Warn "  3. IMPORTANT: Keep 'Git Bash' checked (on by default)"
        Show-Warn "  4. Finish the install, then run this script again"
        exit 1
    }
    Show-OK "Installed."
} else {
    Show-OK "Found: $gitBashPath"
}

# Verify it's not WSL bash
if ($gitBashPath -like "*System32*" -or $gitBashPath -like "*WindowsApps*") {
    Show-Error "Found bash.exe but it's WSL, not Git Bash."
    Show-Warn "Please install Git for Windows from https://git-scm.com/downloads/win"
    Show-Warn "then run this script again."
    exit 1
}

# ===================================================================
# STEP 3: Claude Code CLI
# ===================================================================
Show-Step "Claude Code"
Refresh-Path

# Detect Claude Desktop
$claudeDesktop = $false
$desktopPaths = @(
    "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
    "$env:ProgramFiles\Claude\Claude.exe"
)
foreach ($dp in $desktopPaths) {
    if (Test-Path $dp) { $claudeDesktop = $true; break }
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Show-OK "Ready."
    if ($claudeDesktop) { Show-OK "Claude Desktop also detected -- both work fine together." }
} else {
    if ($claudeDesktop) {
        Show-Action "Claude Desktop detected but CLI not installed."
        Show-Action "Installing Claude Code CLI alongside Desktop..."
    } else {
        Show-Action "Installing Claude Code CLI..."
    }
    $installed = $false

    # Try winget
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if ($hasWinget) {
        winget install Anthropic.ClaudeCode --accept-source-agreements --accept-package-agreements 2>$null
        Refresh-Path
        if (Get-Command claude -ErrorAction SilentlyContinue) { $installed = $true }
    }

    # Fallback: npm global
    if (-not $installed) {
        Show-Action "Trying npm install..."
        npm install -g @anthropic-ai/claude-code 2>$null
        Refresh-Path
        if (Get-Command claude -ErrorAction SilentlyContinue) { $installed = $true }
    }

    if (-not $installed) {
        Show-Error "Could not install Claude Code."
        Show-Warn "Please try in a NEW PowerShell window:"
        Show-Warn "  npm install -g @anthropic-ai/claude-code"
        Show-Warn "then run this script again."
        exit 1
    }
    Show-OK "Installed."
}

# ===================================================================
# STEP 4: Configure Claude Code
# ===================================================================
Show-Step "Configure Claude Code"

# --- HOME ---
if (-not $env:HOME) {
    $env:HOME = $env:USERPROFILE
    [System.Environment]::SetEnvironmentVariable("HOME", $env:USERPROFILE, "User")
}

# --- Git Bash path → settings.json (most reliable method) ---
$claudeDir = "$env:USERPROFILE\.claude"
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

$settingsPath = "$claudeDir\settings.json"
$settings = Read-JsonFile $settingsPath
if (-not $settings) { $settings = [PSCustomObject]@{} }
if (-not $settings.PSObject.Properties['env']) {
    $settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([PSCustomObject]@{})
}
$settings.env | Add-Member -NotePropertyName 'CLAUDE_CODE_GIT_BASH_PATH' -NotePropertyValue $gitBashPath -Force
Write-JsonFile -Path $settingsPath -Object $settings
Show-OK "Git Bash path -> settings.json"

# --- Git Bash path → env var (belt and suspenders) ---
$env:CLAUDE_CODE_GIT_BASH_PATH = $gitBashPath
[System.Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $gitBashPath, "User")

# --- Git Bash path → PATH (triple redundancy) ---
$gitBinDir = Split-Path $gitBashPath
if ($env:PATH -notlike "*$gitBinDir*") {
    $env:PATH = "$gitBinDir;$env:PATH"
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$gitBinDir*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$gitBinDir;$userPath", "User")
    }
    Show-OK "Git\bin added to PATH"
}

# --- MCP servers (if project config provided) ---
if ($ConfigureMcpServers) {
    $script:Step-- # This is a sub-step, not its own step
    $script:TotalSteps--

    # Claude Code CLI config
    $cliConfigPath = "$env:USERPROFILE\.claude.json"
    Merge-McpServers -ConfigPath $cliConfigPath -Servers $ConfigureMcpServers
    Show-OK "MCP servers -> .claude.json (CLI)"

    # Claude Desktop config (if Desktop is installed or requested)
    if ($claudeDesktop -or $ConfigureDesktop) {
        $desktopConfigPath = "$env:APPDATA\Claude\claude_desktop_config.json"
        $desktopConfigDir = Split-Path $desktopConfigPath
        if (-not (Test-Path $desktopConfigDir)) {
            New-Item -ItemType Directory -Path $desktopConfigDir -Force | Out-Null
        }
        Merge-McpServers -ConfigPath $desktopConfigPath -Servers $ConfigureMcpServers
        Show-OK "MCP servers -> claude_desktop_config.json (Desktop)"
    }
}

Show-OK "Configuration complete."

# ===================================================================
# STEP 5: Verify
# ===================================================================
Show-Step "Verification"
$allGood = $true
$details = @()

# Node.js
$v = node --version 2>$null
if ($v) {
    Show-OK "Node.js $v"
} else {
    Show-Error "Node.js: NOT FOUND"
    $allGood = $false
    $details += "Node.js not in PATH"
}

# Git Bash
if (Test-Path $gitBashPath) {
    Show-OK "Git Bash: $gitBashPath"
} else {
    Show-Error "Git Bash: file not found at $gitBashPath"
    $allGood = $false
    $details += "bash.exe missing"
}

# settings.json
try {
    $checkSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $checkBash = $checkSettings.env.CLAUDE_CODE_GIT_BASH_PATH
    if ($checkBash -and (Test-Path $checkBash)) {
        Show-OK "settings.json: Git Bash path verified"
    } else {
        Show-Error "settings.json: Git Bash path missing or invalid"
        $allGood = $false
        $details += "settings.json not configured"
    }
} catch {
    Show-Error "settings.json: could not read"
    $allGood = $false
    $details += "settings.json unreadable"
}

# Claude Code
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Show-OK "Claude Code: installed"
} else {
    Show-Error "Claude Code: NOT FOUND"
    $allGood = $false
    $details += "claude command not in PATH"
}

# MCP servers
if ($ConfigureMcpServers) {
    $cliConfigPath = "$env:USERPROFILE\.claude.json"
    try {
        $checkConfig = Get-Content $cliConfigPath -Raw | ConvertFrom-Json
        $serverNames = @($ConfigureMcpServers.PSObject.Properties.Name)
        $allServersOK = $true
        foreach ($name in $serverNames) {
            if ($checkConfig.mcpServers.PSObject.Properties[$name]) {
                Show-OK "MCP server '$name': configured"
            } else {
                Show-Error "MCP server '$name': missing from .claude.json"
                $allServersOK = $false
            }
        }
        if (-not $allServersOK) { $allGood = $false; $details += "MCP server config incomplete" }
    } catch {
        Show-Error "MCP config: could not read .claude.json"
        $allGood = $false
        $details += ".claude.json unreadable"
    }
}

# ===================================================================
# RESULT
# ===================================================================
Write-Host ""
if ($allGood) {
    Write-Host "  ========================================" -ForegroundColor Green
    Write-Host "  Setup complete! Everything looks good." -ForegroundColor Green
    Write-Host "  ========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  To start, type:" -ForegroundColor White
    Write-Host ""
    Write-Host "    claude" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  It will ask you to log in on first launch." -ForegroundColor White
    Write-Host "  Sign in with your Anthropic account in the" -ForegroundColor White
    Write-Host "  browser, then come back to the terminal." -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "  ========================================" -ForegroundColor Red
    Write-Host "  Setup had issues:" -ForegroundColor Red
    Write-Host "  ========================================" -ForegroundColor Red
    foreach ($d in $details) {
        Show-Error $d
    }
    Write-Host ""
    Show-Warn "Try: close this window, open a new PowerShell,"
    Show-Warn "and run the setup command again."
    Show-Warn ""
    Show-Warn "If it still fails, send a screenshot to your contact."
    Write-Host ""
}
