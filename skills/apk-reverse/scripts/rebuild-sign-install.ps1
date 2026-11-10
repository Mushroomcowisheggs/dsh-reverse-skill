#requires -Version 5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [string]$OutDir,

    [string]$BaseName,

    [string]$KeystorePath,

    [string]$KeyAlias = 'androiddebugkey',

    [string]$StorePass = 'android',

    [string]$KeyPass = 'android',

    [string]$DeviceSerial,

    [switch]$Install,

    [switch]$Reinstall,

    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $KeystorePath = Join-Path (Join-Path $homePath '.android') 'debug.keystore'
}

function Get-ToolPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    $buildTools = @()
    if (Test-Path -LiteralPath (Join-Path $sdkRoot 'build-tools')) {
        $buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending
    }

    $fallbacks = @{
        # apktool is resolved from PATH only: this package never installs tools
        # and never looks for them inside a user profile directory.
        'apktool' = @()
        'zipalign' = @($buildTools | ForEach-Object { Join-Path $_.FullName 'zipalign.exe' })
        'apksigner' = @($buildTools | ForEach-Object { Join-Path $_.FullName 'apksigner.bat' })
        'keytool' = @()
        'adb' = @(
            (Join-Path $sdkRoot 'platform-tools\adb.exe')
        )
    }

    if ($fallbacks.Contains($Name)) {
        foreach ($candidate in $fallbacks[$Name]) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                return $candidate
            }
        }
    }

    # Tools are resolved from PATH and from OS-provided SDK locations only. There
    # is deliberately no install step here: installing tools belongs to the
    # operator, and this package never writes into a user profile directory.

    # Clear error message for tools that cannot be resolved
    $manualHint = switch ($Name) {
        'zipalign'  { 'Install Android Build-Tools via Android SDK Manager (sdkmanager "build-tools;35.0.0")' }
        'apksigner' { 'Install Android Build-Tools via Android SDK Manager (sdkmanager "build-tools;35.0.0")' }
        default     { "Install $Name manually" }
    }
    throw "Missing required CLI tool: $Name — $manualHint"
}

function Ensure-DebugKeystore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Keytool,
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$StorePassword,
        [Parameter(Mandatory = $true)][string]$KeyPassword
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    & $Keytool -genkeypair -v -keystore $Path -storepass $StorePassword -keypass $KeyPassword -alias $Alias -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=ReverseSkill,C=CN'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to generate debug keystore.'
    }
}

if (-not (Test-Path -LiteralPath $ProjectDir)) {
    throw "Project directory not found: $ProjectDir"
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $projectParent = Split-Path -Path $ProjectDir -Parent
    if ([string]::IsNullOrWhiteSpace($projectParent)) {
        $projectParent = [System.IO.Directory]::GetCurrentDirectory()
    }
    $OutDir = $projectParent
}

$apktool = Get-ToolPath -Name 'apktool'
$zipalign = Get-ToolPath -Name 'zipalign'
$apksigner = Get-ToolPath -Name 'apksigner'
$keytool = Get-ToolPath -Name 'keytool'
$adb = Get-ToolPath -Name 'adb'

Ensure-DebugKeystore -Path $KeystorePath -Keytool $keytool -Alias $KeyAlias -StorePassword $StorePass -KeyPassword $KeyPass

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$name = if ($BaseName) { $BaseName } else { Split-Path -Path $ProjectDir -Leaf }
$unsignedApk = Join-Path $OutDir ($name + '-unsigned.apk')
$alignedApk = Join-Path $OutDir ($name + '-aligned.apk')
$signedApk = Join-Path $OutDir ($name + '-signed.apk')

if ($Clean) {
    foreach ($path in @($unsignedApk, $alignedApk, $signedApk)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

& $apktool b $ProjectDir -o $unsignedApk
if ($LASTEXITCODE -ne 0) {
    throw 'apktool build failed.'
}

& $zipalign -f -p 4 $unsignedApk $alignedApk
if ($LASTEXITCODE -ne 0) {
    throw 'zipalign failed.'
}

Copy-Item -LiteralPath $alignedApk -Destination $signedApk -Force
& $apksigner sign --ks $KeystorePath --ks-key-alias $KeyAlias --ks-pass "pass:$StorePass" --key-pass "pass:$KeyPass" --out $signedApk $alignedApk
if ($LASTEXITCODE -ne 0) {
    throw 'apksigner sign failed.'
}

& $apksigner verify --print-certs $signedApk
if ($LASTEXITCODE -ne 0) {
    throw 'apksigner verify failed.'
}

"unsigned_apk=$unsignedApk"
"aligned_apk=$alignedApk"
"signed_apk=$signedApk"
"keystore=$KeystorePath"

if ($Install) {
    $installArgs = @()
    if ($DeviceSerial) {
        $installArgs += '-s'
        $installArgs += $DeviceSerial
    }
    $installArgs += 'install'
    if ($Reinstall) {
        $installArgs += '-r'
    }
    $installArgs += $signedApk

    & $adb @installArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'adb install failed.'
    }

    "install_device=$DeviceSerial"
}
