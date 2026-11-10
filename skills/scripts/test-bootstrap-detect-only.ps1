#Requires -Version 5.1
<#
.SYNOPSIS
    Regression test for the detect-only bootstrap contract on Windows.

.DESCRIPTION
    The PowerShell side detects capabilities and reports what is missing; it
    never installs tools and never writes into a user profile directory. This
    test pins that contract down three ways:

      1. no PowerShell entry point contains an installation primitive
         (GetTool download, archive extraction, package-manager install, clone)
         or a %USERPROFILE% write target;
      2. bootstrap-manifest.json carries no install destination and marks every
         capability as not auto-installable;
      3. running the bootstrap for a missing capability exits 0 with
         manual-required and creates nothing, verified against a relocated home
         directory so the real profile is never touched.

.PARAMETER ScratchDir
    Directory used for the relocated home. Defaults to a fresh temp directory.
#>
param(
    [string]$ScratchDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$bootstrap = Join-Path $scriptDir 'bootstrap-reverse.ps1'
$manifestPath = Join-Path $scriptDir 'bootstrap-manifest.json'

if ([string]::IsNullOrWhiteSpace($ScratchDir)) {
    $ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ('reverse-detect-only-' + [guid]::NewGuid().ToString('N'))
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Get-ReversePowerShellScripts {
    $roots = @(
        (Join-Path $packageRoot 'skills'),
        (Join-Path $packageRoot 'kali')
    )
    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    }
    # This test names the forbidden primitives, so it is not scanned itself.
    return @($found | Where-Object { $_.Name -notlike 'test-*' })
}

# --- 1) no installation primitives, no profile write targets -----------------
$forbiddenTokens = @(
    'Invoke-WebRequest',
    'Start-BitsTransfer',
    'Expand-Archive',
    '%USERPROFILE%',
    '$env:USERPROFILE'
)
$forbiddenInvocation = '&\s*[\w\\/.\-]*\b(npm|pnpm|pip|pipx|winget|go|choco|scoop|npx)\b[^\r\n]*\b(install|add)\b'
$offenders = @()
foreach ($file in (Get-ReversePowerShellScripts)) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach ($token in $forbiddenTokens) {
        if ($text.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $offenders += ('{0} -> {1}' -f $token, $file.Name)
        }
    }
    if ($text -match $forbiddenInvocation) {
        $offenders += ('package-manager install -> {0}' -f $file.Name)
    }
}
Assert-True ($offenders.Count -eq 0) ("no install primitive or profile target in PowerShell scripts: " + ($offenders -join '; '))

# --- 2) the manifest declares no install destination ------------------------
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$withInstallDir = @($manifest.capabilities | Where-Object { $_.PSObject.Properties['installDir'] })
Assert-True ($withInstallDir.Count -eq 0) 'bootstrap-manifest.json carries no installDir'
$autoInstallable = @($manifest.capabilities | Where-Object { $_.canAutoInstall -eq $true })
Assert-True ($autoInstallable.Count -eq 0) 'every capability is marked canAutoInstall=false'

# --- 3) a missing capability is reported, not installed ---------------------
if (-not (Test-Path -LiteralPath $ScratchDir)) {
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
}
$relocatedHome = Join-Path $ScratchDir 'home'
New-Item -ItemType Directory -Path $relocatedHome -Force | Out-Null

$savedEnvironment = @{}
foreach ($name in @('USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:USERPROFILE = $relocatedHome
    $env:HOME = $relocatedHome
    $env:LOCALAPPDATA = Join-Path $relocatedHome 'AppData\Local'
    $env:APPDATA = Join-Path $relocatedHome 'AppData\Roaming'

    $powerShellHost = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Join-Path $PSHOME 'powershell.exe'
    } else {
        Join-Path $PSHOME 'pwsh'
    }

    # seclists is a plain clone-kind capability with no verifyCommand: it can
    # never be reported ready by discovery alone.
    $childOutput = @(& $powerShellHost -NoProfile -ExecutionPolicy Bypass -File $bootstrap -Capability seclists -SkipRefresh)
    $childExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $report = ($childOutput -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop

    Assert-True ($childExitCode -eq 0) ("missing capability exits 0 (got {0})" -f $childExitCode)
    Assert-True ($report.status -eq 'manual-required') ("missing capability reports manual-required (got '{0}')" -f $report.status)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$report.hint)) 'missing capability reports an install hint'

    # PowerShell itself writes its startup-profile data under AppData, so only
    # entries outside that tree count as the bootstrap creating something.
    $appDataRoot = Join-Path $relocatedHome 'AppData'
    $appDataPrefix = $appDataRoot + '\'
    $created = @(
        Get-ChildItem -LiteralPath $relocatedHome -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $candidate = $_.FullName
                -not ($candidate.Equals($appDataRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $candidate.StartsWith($appDataPrefix, [System.StringComparison]::OrdinalIgnoreCase))
            }
    )
    Assert-True ($created.Count -eq 0) ("bootstrap created nothing outside PowerShell's own AppData (found {0}: {1})" -f $created.Count, (($created | ForEach-Object { $_.FullName }) -join ', '))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $relocatedHome 'Tools'))) 'no Tools directory was created in the relocated home'

    Write-Host 'detect-only PowerShell bootstrap regression passed'
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath $ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
