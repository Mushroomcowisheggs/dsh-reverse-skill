#requires -Version 5

<#
.SYNOPSIS
    Report the readiness of the agent-browser + Playwright toolchain.

.DESCRIPTION
    This script never installs anything. Installing Node.js, agent-browser, and
    the Playwright browsers is the operator's job, and this package never writes
    into a user profile directory to do it.

    It reports one key=value line per fact and exits non-zero when a required
    piece is missing, so an agent can tell the user what to install instead of
    installing it behind their back.

.PARAMETER SkipBrowserInstall
    Kept for compatibility. No browsers are installed either way; with this
    switch the Playwright browser cache is not inspected.
#>

[CmdletBinding()]
param(
    [switch]$SkipBrowserInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor Cyan
}

$missing = @()

# Step 1: Node.js
Write-Step 'Checking Node.js...'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    $missing += 'node'
    Write-Warning 'Node.js is not on PATH. Install it yourself: https://nodejs.org/'
}
else {
    $nodeVersion = (& $node.Source -v) 2>$null
    Write-Step "Node.js: $nodeVersion"
    "node=$($node.Source)"
}

# Step 2: npm
Write-Step 'Checking npm...'
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
    $missing += 'npm'
    Write-Warning 'npm is not on PATH. Reinstall Node.js (which ships npm): https://nodejs.org/'
}
else {
    "npm=$($npm.Source)"
}

# Step 3: agent-browser (global install or npx)
Write-Step 'Checking agent-browser...'
$agentBrowser = Get-Command agent-browser -ErrorAction SilentlyContinue
$npx = Get-Command npx -ErrorAction SilentlyContinue
if ($agentBrowser) {
    "agent-browser=$($agentBrowser.Source)"
}
elseif ($npx) {
    # agent-browser is resolvable through npx without a global install.
    "agent-browser=npx agent-browser"
}
else {
    $missing += 'agent-browser'
    Write-Warning 'agent-browser is not available. Install it yourself with: npm install -g agent-browser'
}

# Step 4: Playwright browser cache (read-only inspection)
if (-not $SkipBrowserInstall) {
    Write-Step 'Checking the Playwright browser cache...'
    $playwrightPath = $null
    $envBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
    if (-not [string]::IsNullOrWhiteSpace($envBrowsersPath)) {
        $playwrightPath = $envBrowsersPath
    }
    else {
        $defaultPath = Join-Path $env:LOCALAPPDATA 'ms-playwright'
        if (Test-Path -LiteralPath $defaultPath) {
            $playwrightPath = $defaultPath
        }
    }

    if ($playwrightPath -and (Test-Path -LiteralPath $playwrightPath)) {
        "playwright_browsers_path=$playwrightPath"
    }
    else {
        $missing += 'playwright-browsers'
        Write-Warning 'No Playwright browser cache found. Install the browsers yourself with: npx playwright install chromium'
    }
}

# Step 5: Verdict
Write-Step 'Verification:'
if ($missing.Count -eq 0) {
    'status=ready'
}
else {
    'status=manual-required'
    'missing=' + ($missing -join ',')
    throw ("Missing required tooling: {0}. Install it yourself; this package does not install tools." -f ($missing -join ', '))
}
