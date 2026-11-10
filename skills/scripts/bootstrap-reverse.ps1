#requires -Version 5

<#
.SYNOPSIS
    Report which reverse-engineering capabilities this machine already has.

.DESCRIPTION
    This script does not install anything. Installing tools is the operator's
    job, and this package never writes into a user profile directory to do it.

    For every requested capability one JSON record is emitted:

        ready                 the tool, runtime, or service was detected
        configured-not-ready  a known MCP capability exists but is not
                              registered or not serving on its port
        manual-required       the tool is missing; the operator installs it
        missing-definition    the name is not in bootstrap-manifest.json
        failed                discovery itself failed

    Missing tools are reported with a hint and a docs link so an agent can tell
    the user what to install instead of installing it behind their back.

    Client MCP configuration is written only when -McpHostTarget explicitly
    names a client. The default writes no client config at all.

.PARAMETER Capability
    One or more capability names from bootstrap-manifest.json.

.PARAMETER SkipRefresh
    Skip regenerating skills/tool-index.md after the report.

.PARAMETER StartServices
    Deprecated and ignored. Services are started by the operator; this script
    only reports whether they are already listening.

.PARAMETER McpHostTarget
    Opt-in client whose MCP configuration receives the capabilities that define
    an MCP server. None (the default) writes no client configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Capability,

    [switch]$SkipRefresh,

    [switch]$StartServices,

    [ValidateSet('None', 'Claude', 'Codex', 'Both')]
    [string]$McpHostTarget = 'None'
)

# 临时目录统一入口（$env:TEMP 在 Linux/macOS 上可能未设置）
$tmpBase = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# ToolDiscovery.ps1 owns discovery: it resolves capabilities from PATH and from
# app-data locations the operating system or the vendor chose. Nothing here
# creates directories, downloads files, or mutates PATH.
. (Join-Path $PSScriptRoot 'lib\ToolDiscovery.ps1')

if ($StartServices) {
    Write-Warning 'Deprecated flag: -StartServices is ignored. Start the service yourself; this script only reports whether it is already listening.'
}

$Capability = @(
    foreach ($item in @($Capability)) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        foreach ($name in ($item -split ',')) {
            $trimmed = $name.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $trimmed
            }
        }
    }
) | Select-Object -Unique

function Get-FirstCommandPath {
    param(
        [string[]]$Names,
        [switch]$PreferApplication
    )

    foreach ($name in $Names) {
        $commands = @(Get-Command $name -All -ErrorAction SilentlyContinue)
        if ($PreferApplication) {
            $preferred = $commands | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
            if ($preferred) {
                return $preferred.Source
            }
        }
        $cmd = $commands | Select-Object -First 1
        if ($cmd) {
            return $cmd.Source
        }
    }
    return ''
}

function Get-PreferredPowerShellPath {
    $pwsh = Get-FirstCommandPath -Names @('pwsh.exe', 'pwsh') -PreferApplication
    if (-not [string]::IsNullOrWhiteSpace($pwsh)) {
        return $pwsh
    }
    return Get-FirstCommandPath -Names @('powershell.exe', 'powershell') -PreferApplication
}

function Test-ReverseIsWindows {
    return $env:OS -eq 'Windows_NT'
}

function Get-McpHostTargets {
    switch ($McpHostTarget) {
        'Claude' { return @('Claude') }
        'Codex' { return @('Codex') }
        'Both' { return @('Claude', 'Codex') }
        default { return @() }
    }
}

function Get-ClaudeMcpConfig {
    $path = Get-ClaudeMcpConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ path = $path; json = @{ mcpServers = @{} } }
    }

    $json = Read-ReverseJsonAsHashtable -Path $path
    if ($null -eq $json) {
        $json = @{ mcpServers = @{} }
    }
    if (-not $json.Contains('mcpServers')) {
        $json['mcpServers'] = @{}
    }
    return @{ path = $path; json = $json }
}

function Save-ClaudeMcpConfig {
    param([Parameter(Mandatory = $true)]$Config)

    $parent = Split-Path -Path $Config.path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Config.json | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Config.path -Encoding utf8
}

function ConvertTo-TomlLiteral {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = foreach ($item in $Value) {
            ConvertTo-TomlLiteral -Value $item
        }
        return "[{0}]" -f ($items -join ', ')
    }

    $escaped = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Remove-CodexMcpServerBlocks {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$ServerName
    )

    $targetPattern = '^\[mcp_servers\.{0}(?:\.env)?\]\s*$' -f [regex]::Escape($ServerName)
    $result = New-Object System.Collections.Generic.List[string]
    $skipBlock = $false

    if ($null -eq $Lines) {
        return @()
    }

    foreach ($line in $Lines) {
        if ($line -match '^\[') {
            if ($line -match $targetPattern) {
                $skipBlock = $true
                continue
            }

            if ($skipBlock) {
                $skipBlock = $false
            }
        }

        if (-not $skipBlock) {
            $result.Add($line)
        }
    }

    return @($result)
}

function Set-CodexMcpServer {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][hashtable]$ServerDefinition
    )

    $path = Get-CodexConfigPath
    $parent = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $lines = @()
    $writeUtf8Bom = $false
    $newline = [Environment]::NewLine
    if (Test-Path -LiteralPath $path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $writeUtf8Bom = $true
            $offset = 3
        }

        # TOML is UTF-8. Decode strictly so an unexpected legacy encoding stops
        # the update instead of being silently converted into mojibake.
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
        $newlineMatch = [regex]::Match($text, "\r\n|\n|\r")
        if ($newlineMatch.Success) {
            $newline = $newlineMatch.Value
        }

        $rawLines = if ([string]::IsNullOrEmpty($text)) {
            @()
        }
        else {
            @([regex]::Split($text, "\r\n|\n|\r"))
        }
        if ($rawLines.Count -eq 1 -and [string]::IsNullOrEmpty($rawLines[0])) {
            $lines = @()
        }
        else {
            $lines = $rawLines
        }
    }
    $lines = @(Remove-CodexMcpServerBlocks -Lines $lines -ServerName $ServerName)

    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
        $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
    }
    if ($lines.Count -gt 0) {
        $lines += ''
    }

    $lines += "[mcp_servers.$ServerName]"
    foreach ($key in @('type', 'url', 'command', 'args', 'bearer_token_env_var')) {
        if ($ServerDefinition.Contains($key)) {
            $lines += "$key = $(ConvertTo-TomlLiteral -Value $ServerDefinition[$key])"
        }
    }
    foreach ($key in ($ServerDefinition.Keys | Where-Object { $_ -notin @('type', 'url', 'command', 'args', 'bearer_token_env_var', 'env') } | Sort-Object)) {
        $lines += "$key = $(ConvertTo-TomlLiteral -Value $ServerDefinition[$key])"
    }

    if ($ServerDefinition.Contains('env') -and $ServerDefinition['env'] -is [System.Collections.IDictionary] -and $ServerDefinition['env'].Count -gt 0) {
        $lines += ''
        $lines += "[mcp_servers.$ServerName.env]"
        foreach ($envKey in ($ServerDefinition['env'].Keys | Sort-Object)) {
            $lines += "$envKey = $(ConvertTo-TomlLiteral -Value $ServerDefinition['env'][$envKey])"
        }
    }

    $content = $lines -join $newline
    if ($lines.Count -gt 0) {
        $content += $newline
    }
    $utf8 = [System.Text.UTF8Encoding]::new($writeUtf8Bom)
    [System.IO.File]::WriteAllText($path, $content, $utf8)
}

function Ensure-McpServer {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][hashtable]$ServerDefinition
    )

    foreach ($target in Get-McpHostTargets) {
        switch ($target) {
            'Claude' {
                $config = Get-ClaudeMcpConfig
                $claudeDefinition = @{}
                foreach ($key in $ServerDefinition.Keys) {
                    if ($key -ne 'bearer_token_env_var') {
                        $claudeDefinition[$key] = $ServerDefinition[$key]
                    }
                }
                $config.json.mcpServers[$ServerName] = $claudeDefinition
                Save-ClaudeMcpConfig -Config $config
            }
            'Codex' {
                $codexDefinition = @{}
                foreach ($key in $ServerDefinition.Keys) {
                    if ($key -ne 'headers') {
                        $codexDefinition[$key] = $ServerDefinition[$key]
                    }
                }
                Set-CodexMcpServer -ServerName $ServerName -ServerDefinition $codexDefinition
            }
        }
    }
}

function Get-McpCommandServerDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Env = @{}
    )

    if ((Test-ReverseIsWindows) -and $Command -in @('npx', 'pnpm', 'npm')) {
        return @{
            type = 'stdio'
            command = 'cmd'
            args = @('/c', $Command) + @($Arguments)
            env = $Env
        }
    }

    return @{
        type = 'stdio'
        command = $Command
        args = @($Arguments)
        env = $Env
    }
}

function Get-CapabilityProperty {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = ''
    )

    if ($Definition.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Definition.$Name)) {
        return $Definition.$Name
    }
    return $Default
}

function Get-CapabilityInstallHint {
    param([Parameter(Mandatory = $true)]$Definition)

    $manual = Get-CapabilityProperty -Definition $Definition -Name 'manualInstallHint'
    if (-not [string]::IsNullOrWhiteSpace([string]$manual)) {
        return [string]$manual
    }

    $name = [string]$Definition.name
    $command = [string](Get-CapabilityProperty -Definition $Definition -Name 'verifyCommand' -Default $name)
    $docs = [string](Get-CapabilityProperty -Definition $Definition -Name 'docsUrl')
    $hint = "Install $name yourself and make '$command' resolvable on PATH. This package does not install tools."
    if (-not [string]::IsNullOrWhiteSpace($docs)) {
        $hint = $hint + " Docs: $docs"
    }
    return $hint
}

function Register-CapabilityMcpServer {
    param([Parameter(Mandatory = $true)]$Definition)

    if (@(Get-McpHostTargets).Count -eq 0) {
        return $false
    }
    if (-not $Definition.PSObject.Properties['mcpNames']) {
        return $false
    }
    $names = @($Definition.mcpNames)
    if ($names.Count -eq 0) {
        return $false
    }

    $serverName = [string]$names[0]
    $serverDefinition = $null
    switch ([string]$Definition.bootstrapKind) {
        'npm-mcp' {
            $command = [string](Get-CapabilityProperty -Definition $Definition -Name 'mcpCommand')
            if ([string]::IsNullOrWhiteSpace($command)) {
                return $false
            }
            $arguments = @()
            if ($Definition.PSObject.Properties['mcpArgs']) {
                $arguments = @($Definition.mcpArgs)
            }
            $envMap = @{}
            if ($Definition.PSObject.Properties['mcpEnv'] -and $null -ne $Definition.mcpEnv) {
                foreach ($property in $Definition.mcpEnv.PSObject.Properties) {
                    $envMap[$property.Name] = $property.Value
                }
            }
            $serverDefinition = Get-McpCommandServerDefinition -Command $command -Arguments $arguments -Env $envMap
        }
        'remote-http-mcp' {
            $url = [string](Get-CapabilityProperty -Definition $Definition -Name 'mcpUrl')
            if ([string]::IsNullOrWhiteSpace($url)) {
                return $false
            }
            $serverDefinition = @{ url = $url }
        }
        'local-http-mcp' {
            $url = [string](Get-CapabilityProperty -Definition $Definition -Name 'mcpUrl')
            if ([string]::IsNullOrWhiteSpace($url)) {
                return $false
            }
            $serverDefinition = @{ url = $url }
        }
        default {
            return $false
        }
    }

    Ensure-McpServer -ServerName $serverName -ServerDefinition $serverDefinition
    return $true
}

function Expand-CapabilityDependencies {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Capability {
        param([string]$CapabilityName)

        if ($seen.ContainsKey($CapabilityName)) {
            return
        }
        $seen[$CapabilityName] = $true

        $definition = Get-ReverseBootstrapDefinition -Name $CapabilityName
        if ($null -ne $definition -and $definition.PSObject.Properties['dependsOn']) {
            foreach ($dependency in @($definition.dependsOn)) {
                Add-Capability -CapabilityName $dependency
            }
        }

        $ordered.Add($CapabilityName)
    }

    foreach ($name in $Names) {
        Add-Capability -CapabilityName $name
    }

    return $ordered
}

function Test-BootstrapResultsSucceeded {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    return (@($Results | Where-Object { $_.status -eq 'failed' }).Count -eq 0)
}

$expandedCapabilities = Expand-CapabilityDependencies -Names $Capability
$results = @()

foreach ($name in $expandedCapabilities) {
    $definition = Get-ReverseBootstrapDefinition -Name $name
    if ($null -eq $definition) {
        $results += [pscustomobject]@{ name = $name; status = 'missing-definition' }
        continue
    }

    try {
        # Explicitly requested client registration happens before the report, so
        # a registration the user opted into is reflected in the same output.
        [void](Register-CapabilityMcpServer -Definition $definition)

        $state = Get-ReverseCapabilityState -Name $name
        $ready = if ($state) { [bool]$state.Ready } else { $false }
        $docsUrl = [string](Get-CapabilityProperty -Definition $definition -Name 'docsUrl')
        $hasMcp = $definition.PSObject.Properties['mcpNames'] -and @($definition.mcpNames).Count -gt 0

        if ($ready) {
            $results += [pscustomobject]@{
                name = $name
                status = 'ready'
                ready = $true
                registered = if ($state) { $state.Registered } else { $null }
                service_online = if ($state) { $state.ServiceOnline } else { $null }
            }
            continue
        }

        if ($hasMcp) {
            $results += [pscustomobject]@{
                name = $name
                status = 'configured-not-ready'
                ready = $false
                registered = if ($state) { $state.Registered } else { $false }
                service_online = if ($state) { $state.ServiceOnline } else { $false }
                hint = Get-CapabilityInstallHint -Definition $definition
                docs_url = $docsUrl
            }
            continue
        }

        $results += [pscustomobject]@{
            name = $name
            status = 'manual-required'
            ready = $false
            hint = Get-CapabilityInstallHint -Definition $definition
            docs_url = $docsUrl
        }
    }
    catch {
        $results += [pscustomobject]@{
            name = $name
            status = 'failed'
            error = $_.Exception.Message
        }
    }
}

if (-not $SkipRefresh) {
    $shell = Get-PreferredPowerShellPath
    if (-not [string]::IsNullOrWhiteSpace($shell)) {
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'refresh-tool-index.ps1') | Out-Null
    }
}

$results | ConvertTo-Json -Depth 5
if (-not (Test-BootstrapResultsSucceeded -Results $results)) {
    exit 1
}
