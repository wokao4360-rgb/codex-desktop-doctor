@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "CDD_SELF=%~f0"
set "CDD_TEMP=%TEMP%\CodexDesktopDoctor-%RANDOM%-%RANDOM%.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $self=$env:CDD_SELF; $out=$env:CDD_TEMP; $lines=Get-Content -LiteralPath $self; $marker='###CODEX_DESKTOP_DOCTOR_PS1###'; $idx=[Array]::IndexOf($lines,$marker); if($idx -lt 0){ throw 'payload marker not found' }; $payload=$lines[($idx+1)..($lines.Count-1)]; Set-Content -LiteralPath $out -Value $payload -Encoding UTF8"
if errorlevel 1 (
  echo Failed to extract embedded PowerShell script.
  pause
  exit /b 1
)

if "%~1"=="" (
  echo Codex Desktop Doctor one-click mode: RepairPluginUi
  echo Tip: close Codex Desktop first, run this file, then reopen Codex Desktop.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CDD_TEMP%" -Action RepairPluginUi
  set "CDD_EXIT=!ERRORLEVEL!"
  del "%CDD_TEMP%" >nul 2>nul
  echo.
  echo If plugins are still grey and the output says auth_mode: apikey, log out in Codex Desktop and sign in with ChatGPT/OAuth, then keep your local provider selected.
  echo Done. Press any key to close this window.
  pause >nul
  exit /b !CDD_EXIT!
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CDD_TEMP%" %*
  set "CDD_EXIT=!ERRORLEVEL!"
  del "%CDD_TEMP%" >nul 2>nul
  exit /b !CDD_EXIT!
)

exit /b 0
###CODEX_DESKTOP_DOCTOR_PS1###
[CmdletBinding()]
param(
  [ValidateSet('Diagnose','RepairPluginUi','RepairCloudflareMcp','RepairSessionVisibility','RepairAll')]
  [string]$Action = 'Diagnose',

  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$ProviderName = '',
  [string]$ProviderBaseUrl = '',
  [string]$LocalTokenEnvVar = '',
  [string]$ProviderWireApi = '',
  [string]$ThreadId = '',
  [ValidateSet('Auto','Normal','Extended')]
  [string]$ThreadPathStyle = 'Auto',

  [switch]$FixEnv,
  [switch]$ForceEnvMigration,
  [switch]$CloudflareOAuth,
  [ValidateSet('Minimal','Broad')]
  [string]$CloudflareScopePreset = 'Minimal',
  [string[]]$CloudflareScopes,
  [int]$CloudflareCallbackTimeoutSec = 300,
  [string]$CloudflareUserAgent = 'curl/8.15.0',
  [switch]$NoBrowser,

  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Stamp {
  return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Write-Step([string]$Message) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Mask-Secret([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }
  if ($Value.Length -le 8) { return '<secret>' }
  return ('{0}...{1}' -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4))
}

function Get-ObjectPropertyValue($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  return $prop.Value
}

function ConvertTo-RedactedObject($Value) {
  if ($null -eq $Value) { return $null }

  if ($Value -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $Value.Keys) {
      if ([string]$key -match '(?i)(access_token|refresh_token|id_token|client_secret|api[_-]?key|authorization|password|secret|token)$') {
        $result[$key] = '<redacted>'
      } else {
        $result[$key] = ConvertTo-RedactedObject $Value[$key]
      }
    }
    return $result
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) { $items += ConvertTo-RedactedObject $item }
    return $items
  }

  if ($Value -is [pscustomobject]) {
    $result = [ordered]@{}
    foreach ($prop in $Value.PSObject.Properties) {
      if ($prop.Name -match '(?i)(access_token|refresh_token|id_token|client_secret|api[_-]?key|authorization|password|secret|token)$') {
        $result[$prop.Name] = '<redacted>'
      } else {
        $result[$prop.Name] = ConvertTo-RedactedObject $prop.Value
      }
    }
    return $result
  }

  return $Value
}

function ConvertTo-TomlString([string]$Value) {
  if ($null -eq $Value) { $Value = '' }
  $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
  return '"' + $escaped + '"'
}

function Assert-TomlBareKeyPath([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "$Name contains characters that cannot be safely written as a TOML bare key path: $Value"
  }
}

function Assert-EnvVarName([string]$Value, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw "$Name is not a safe environment variable name: $Value"
  }
}

function Assert-NoControlChars([string]$Value, [string]$Name) {
  if ($null -ne $Value -and $Value -match "[`r`n]") {
    throw "$Name must not contain newlines."
  }
}

function Get-Paths {
  $codexRoot = [IO.Path]::GetFullPath($CodexHome)
  return [ordered]@{
    Home = $codexRoot
    Config = Join-Path $codexRoot 'config.toml'
    Auth = Join-Path $codexRoot 'auth.json'
    Credentials = Join-Path $codexRoot '.credentials.json'
    State = Join-Path $codexRoot 'state_5.sqlite'
    Sessions = Join-Path $codexRoot 'sessions'
    ArchivedSessions = Join-Path $codexRoot 'archived_sessions'
    BackupRoot = Join-Path $codexRoot 'doctor-backups'
  }
}

function New-BackupSet([hashtable]$Paths, [string]$Reason) {
  $dir = Join-Path $Paths.BackupRoot ("{0}-{1}" -f (Get-Stamp), $Reason)
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  return $dir
}

function Backup-File([string]$Path, [string]$BackupSet, [switch]$RedactSecrets) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $dest = Join-Path $BackupSet (Split-Path -Leaf $Path)
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $BackupSet | Out-Null
    if ($RedactSecrets) {
      $obj = Get-JsonObject $Path
      if ($null -ne $obj) {
        $redacted = ConvertTo-RedactedObject $obj
        Set-Content -LiteralPath $dest -Value ($redacted | ConvertTo-Json -Depth 80) -Encoding UTF8
      } else {
        Set-Content -LiteralPath $dest -Value '<redacted: source was not valid JSON>' -Encoding UTF8
      }
    } else {
      Copy-Item -LiteralPath $Path -Destination $dest -Force
    }
  }
  if ($RedactSecrets) {
    Write-Step "Redacted backup: $Path -> $dest"
  } else {
    Write-Step "Backup: $Path -> $dest"
  }
  return $dest
}

function Read-TextFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Write-TextFile([string]$Path, [string]$Content) {
  if ($DryRun) {
    Write-Step "DryRun: would write $Path"
    return
  }
  Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Get-TopTomlString([string]$Content, [string]$Key) {
  $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
  $m = [regex]::Match($Content, $pattern)
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-TomlBodyString([string]$Body, [string]$Key) {
  $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
  $m = [regex]::Match($Body, $pattern)
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Set-TopTomlString([string]$Content, [string]$Key, [string]$Value) {
  Assert-TomlBareKeyPath $Key 'Top-level TOML key'
  $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"[^"]*"'
  $line = ('{0} = {1}' -f $Key, (ConvertTo-TomlString $Value))
  if ([regex]::IsMatch($Content, $pattern)) {
    return [regex]::Replace($Content, $pattern, $line, 1)
  }
  return $line + "`r`n" + $Content
}

function Set-TomlSection([string]$Content, [string]$SectionName, [string]$SectionBody) {
  Assert-TomlBareKeyPath $SectionName 'TOML section name'
  $pattern = '(?ms)^\[' + [regex]::Escape($SectionName) + '\]\r?\n.*?(?=^\[|\z)'
  $section = '[' + $SectionName + "]`r`n" + $SectionBody.Trim() + "`r`n"
  if ([regex]::IsMatch($Content, $pattern)) {
    return [regex]::Replace($Content, $pattern, $section, 1)
  }
  if (-not $Content.EndsWith("`n")) { $Content += "`r`n" }
  return $Content.TrimEnd() + "`r`n`r`n" + $section
}

function Get-TomlSection([string]$Content, [string]$SectionName) {
  Assert-TomlBareKeyPath $SectionName 'TOML section name'
  $pattern = '(?ms)^\[' + [regex]::Escape($SectionName) + '\]\r?\n(.*?)(?=^\[|\z)'
  $m = [regex]::Match($Content, $pattern)
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Set-SectionKeyValue([string]$Body, [string]$Key, [string]$ValueExpression) {
  Assert-TomlBareKeyPath $Key 'TOML key'
  $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
  $line = "$Key = $ValueExpression"
  if ([regex]::IsMatch($Body, $pattern)) {
    return [regex]::Replace($Body, $pattern, $line, 1)
  }
  if (-not $Body.EndsWith("`n")) { $Body += "`r`n" }
  return $Body + $line + "`r`n"
}

function Get-JsonObject([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return $raw | ConvertFrom-Json
}

function Write-JsonObject([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 80
  if ($DryRun) {
    Write-Step "DryRun: would write JSON $Path"
    return
  }
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Find-Python {
  $candidates = @('python', 'py')
  foreach ($cmd in $candidates) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
  }
  throw 'Python 3 is required for this action but was not found on PATH.'
}

function Invoke-PythonCode([string]$PythonExe, [string]$Code, [string[]]$Arguments = @()) {
  $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("codex-desktop-doctor-{0}.py" -f [guid]::NewGuid().ToString('N'))
  Set-Content -LiteralPath $tempScript -Value $Code -Encoding UTF8
  try {
    return & $PythonExe $tempScript @Arguments
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-TargetProvider([hashtable]$Paths) {
  if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
    Assert-TomlBareKeyPath $ProviderName 'ProviderName'
    return $ProviderName
  }

  $config = Read-TextFile $Paths.Config
  $currentProvider = Get-TopTomlString $config 'model_provider'
  if (-not [string]::IsNullOrWhiteSpace($currentProvider)) {
    Assert-TomlBareKeyPath $currentProvider 'current model_provider'
    return $currentProvider
  }

  throw 'No active model_provider was found. Re-run with -ProviderName, and pass -ProviderBaseUrl if the provider section must be created.'
}

function Get-CodexAuthMode([hashtable]$Paths) {
  $auth = Get-JsonObject $Paths.Auth
  if (-not $auth) { return '<missing>' }
  $mode = [string](Get-ObjectPropertyValue $auth 'auth_mode' '<unset>')
  if ([string]::IsNullOrWhiteSpace($mode)) { return '<unset>' }
  return $mode
}

function Write-AuthModeDiagnosis([hashtable]$Paths) {
  $mode = Get-CodexAuthMode $Paths
  Write-Step "auth_mode: $mode"
  if ($mode -match '^(?i:apikey)$') {
    Write-Step 'WARNING: Codex is logged in with an API key. Plugins/connectors/skills UI require ChatGPT/OAuth login, so config repair alone cannot un-grey them.'
    Write-Step 'Next step: in Codex Desktop choose Settings -> Log out, then sign in with ChatGPT/OAuth. Keep your local model_provider/base_url unchanged after login.'
  } elseif ($mode -match '^(?i:chatgpt)$') {
    Write-Step 'auth_mode check: ChatGPT/OAuth login is present; plugin UI auth prerequisite is satisfied.'
  }
}

function Invoke-Diagnose {
  $paths = Get-Paths
  Write-Step "Codex home: $($paths.Home)"
  foreach ($k in @('Config','Auth','Credentials','State','Sessions','ArchivedSessions')) {
    Write-Step ("{0}: {1}" -f $k, (Test-Path -LiteralPath $paths[$k]))
  }
  Write-AuthModeDiagnosis $paths

  $config = Read-TextFile $paths.Config
  $provider = Get-TopTomlString $config 'model_provider'
  Write-Step "model_provider: $provider"
  if ($provider) {
    $section = Get-TomlSection $config ("model_providers.$provider")
    if ($section) {
      $requires = if ($section -match '(?m)^requires_openai_auth\s*=\s*(true|false)') { $Matches[1] } else { '<unset>' }
      $baseUrl = if ($section -match '(?m)^base_url\s*=\s*"([^"]+)"') { $Matches[1] } else { '<unset>' }
      Write-Step "provider.base_url: $baseUrl"
      Write-Step "provider.requires_openai_auth: $requires"
    } else {
      Write-Step "provider section missing: [model_providers.$provider]"
    }
  }

  $providerMatches = [regex]::Matches($config, '(?m)^\[model_providers\.([A-Za-z0-9_.-]+)\]\s*$')
  if ($providerMatches.Count -gt 0) {
    $seen = @{}
    foreach ($m in $providerMatches) {
      $name = $m.Groups[1].Value
      if ($seen.ContainsKey($name)) { continue }
      $seen[$name] = $true
      $body = Get-TomlSection $config ("model_providers.$name")
      $baseUrl = if ($body -match '(?m)^base_url\s*=\s*"([^"]+)"') { $Matches[1] } else { '<unset>' }
      $requires = if ($body -match '(?m)^requires_openai_auth\s*=\s*(true|false)') { $Matches[1] } else { '<unset>' }
      $marker = if ($name -eq $provider) { '*' } else { '-' }
      Write-Step ("provider {0} {1}: base_url={2}; requires_openai_auth={3}" -f $marker, $name, $baseUrl, $requires)
    }
  }

  $cfSection = Get-TomlSection $config 'mcp_servers.cloudflare-api'
  Write-Step ("cloudflare-api MCP config: {0}" -f [bool]$cfSection)
  if ($cfSection) {
    $hasUa = $cfSection -match 'User-Agent'
    Write-Step "cloudflare-api User-Agent header: $hasUa"
  }

  $creds = Get-JsonObject $paths.Credentials
  $cfCreds = @()
  if ($creds) {
    foreach ($p in $creds.PSObject.Properties) {
      $v = $p.Value
      $serverName = Get-ObjectPropertyValue $v 'server_name' ''
      $serverUrl = Get-ObjectPropertyValue $v 'server_url' ''
      if ($p.Name -like 'cloudflare-api|*' -or $serverName -eq 'cloudflare-api' -or ([string]$serverUrl) -like '*mcp.cloudflare.com*') {
        $cfCreds += $p
      }
    }
  }
  Write-Step "cloudflare credentials: $($cfCreds.Count)"
  foreach ($p in $cfCreds) {
    $exp = Get-ObjectPropertyValue $p.Value 'expires_at' $null
    if ($exp) {
      $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$exp).LocalDateTime
      Write-Step ("cloudflare credential expires_at: {0:yyyy-MM-dd HH:mm:ss}" -f $dt)
    }
  }

  if (Test-Path -LiteralPath $paths.State) {
    try {
      $python = Find-Python
      $py = @'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
cur = con.cursor()
print(cur.execute("select count(*) from threads").fetchone()[0])
'@
      $count = Invoke-PythonCode $python $py @($paths.State)
      Write-Step "state_5.sqlite threads: $count"
      $py = @'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
counts = {
    "rollout_extended": 0,
    "rollout_normal": 0,
    "cwd_extended": 0,
    "cwd_normal": 0,
}
for row in con.execute("select rollout_path, cwd from threads"):
    rollout_path = row["rollout_path"] or ""
    cwd = row["cwd"] or ""
    if rollout_path.startswith("\\\\?\\"):
        counts["rollout_extended"] += 1
    else:
        counts["rollout_normal"] += 1
    if cwd.startswith("\\\\?\\"):
        counts["cwd_extended"] += 1
    else:
        counts["cwd_normal"] += 1
print(counts)
'@
      $pathCounts = Invoke-PythonCode $python $py @($paths.State)
      Write-Step "state_5.sqlite path styles: $pathCounts"
    } catch {
      Write-Step "state_5.sqlite threads: <unable to inspect: $($_.Exception.Message)>"
    }
  }
}

function Repair-PluginUi {
  $paths = Get-Paths
  if (-not (Test-Path -LiteralPath $paths.Config)) { throw "config.toml not found: $($paths.Config)" }
  if (-not [string]::IsNullOrWhiteSpace($ProviderName)) { Assert-TomlBareKeyPath $ProviderName 'ProviderName' }
  if (-not [string]::IsNullOrWhiteSpace($LocalTokenEnvVar)) { Assert-EnvVarName $LocalTokenEnvVar 'LocalTokenEnvVar' }
  if (-not [string]::IsNullOrWhiteSpace($ProviderBaseUrl)) { Assert-NoControlChars $ProviderBaseUrl 'ProviderBaseUrl' }
  if (-not [string]::IsNullOrWhiteSpace($ProviderWireApi)) { Assert-NoControlChars $ProviderWireApi 'ProviderWireApi' }
  $backup = New-BackupSet $paths 'plugin-ui'
  Backup-File $paths.Config $backup | Out-Null

  $content = Read-TextFile $paths.Config
  $targetProvider = Resolve-TargetProvider $paths
  if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
    $content = Set-TopTomlString $content 'model_provider' $ProviderName
  }

  $sectionName = "model_providers.$targetProvider"
  $body = Get-TomlSection $content $sectionName
  if ([string]::IsNullOrWhiteSpace($body)) {
    if ([string]::IsNullOrWhiteSpace($ProviderBaseUrl)) {
      throw "Provider section [$sectionName] is missing. Re-run with -ProviderBaseUrl to create it, or run your switcher first so Codex config.toml has an active provider."
    }
    $body = ''
    $body = Set-SectionKeyValue $body 'name' (ConvertTo-TomlString $targetProvider)
    $body = Set-SectionKeyValue $body 'base_url' (ConvertTo-TomlString $ProviderBaseUrl)
    if (-not [string]::IsNullOrWhiteSpace($LocalTokenEnvVar)) { $body = Set-SectionKeyValue $body 'env_key' (ConvertTo-TomlString $LocalTokenEnvVar) }
    if (-not [string]::IsNullOrWhiteSpace($ProviderWireApi)) { $body = Set-SectionKeyValue $body 'wire_api' (ConvertTo-TomlString $ProviderWireApi) }
    $body = Set-SectionKeyValue $body 'requires_openai_auth' 'true'
  } else {
    if (-not [string]::IsNullOrWhiteSpace($ProviderBaseUrl)) { $body = Set-SectionKeyValue $body 'base_url' (ConvertTo-TomlString $ProviderBaseUrl) }
    if (-not [string]::IsNullOrWhiteSpace($LocalTokenEnvVar)) { $body = Set-SectionKeyValue $body 'env_key' (ConvertTo-TomlString $LocalTokenEnvVar) }
    if (-not [string]::IsNullOrWhiteSpace($ProviderWireApi)) { $body = Set-SectionKeyValue $body 'wire_api' (ConvertTo-TomlString $ProviderWireApi) }
    $body = Set-SectionKeyValue $body 'requires_openai_auth' 'true'
  }
  $content = Set-TomlSection $content $sectionName $body

  $features = Get-TomlSection $content 'features'
  if ([string]::IsNullOrWhiteSpace($features)) { $features = '' }
  $features = Set-SectionKeyValue $features 'remote_control' 'false'
  $content = Set-TomlSection $content 'features' $features
  Write-TextFile $paths.Config $content
  Write-Step "Plugin UI config repaired for provider '$targetProvider'."
  Write-AuthModeDiagnosis $paths

  if ($FixEnv) {
    $effectiveTokenEnvVar = $LocalTokenEnvVar
    if ([string]::IsNullOrWhiteSpace($effectiveTokenEnvVar)) {
      $effectiveTokenEnvVar = Get-TomlBodyString $body 'env_key'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveTokenEnvVar)) {
      Write-Step 'FixEnv skipped because no LocalTokenEnvVar was provided and the provider has no env_key.'
      return
    }
    Assert-EnvVarName $effectiveTokenEnvVar 'effective provider env_key'
    $userApiKey = [Environment]::GetEnvironmentVariable('CODEX_API_KEY', 'User')
    $localToken = [Environment]::GetEnvironmentVariable($effectiveTokenEnvVar, 'User')
    if ($userApiKey -and -not $localToken) {
      [Environment]::SetEnvironmentVariable($effectiveTokenEnvVar, $userApiKey, 'User')
      Write-Step "$effectiveTokenEnvVar saved from existing CODEX_API_KEY: $(Mask-Secret $userApiKey)"
    } elseif ($userApiKey -and $localToken -and $userApiKey -ne $localToken) {
      if (-not $ForceEnvMigration) {
        Write-Step "$effectiveTokenEnvVar already exists and differs from CODEX_API_KEY; environment cleanup skipped. Re-run with -ForceEnvMigration to overwrite $effectiveTokenEnvVar from CODEX_API_KEY and clear CODEX_API_KEY."
        return
      }
      [Environment]::SetEnvironmentVariable($effectiveTokenEnvVar, $userApiKey, 'User')
      Write-Step "$effectiveTokenEnvVar overwritten from CODEX_API_KEY because -ForceEnvMigration was set: $(Mask-Secret $userApiKey)"
    }
    [Environment]::SetEnvironmentVariable('CODEX_API_KEY', $null, 'User')
    [Environment]::SetEnvironmentVariable('CODEX_API_BASE_URL', $null, 'User')
    Remove-Item Env:\CODEX_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_API_BASE_URL -ErrorAction SilentlyContinue
    Write-Step "Cleared user-level CODEX_API_KEY and CODEX_API_BASE_URL."
  }
}

function Get-McpCredentialKey([string]$ServerName, [string]$ServerUrl) {
  $paths = Get-Paths
  $creds = Get-JsonObject $paths.Credentials
  if ($creds) {
    foreach ($p in $creds.PSObject.Properties) {
      $v = $p.Value
      $serverNameValue = Get-ObjectPropertyValue $v 'server_name' ''
      $serverUrlValue = Get-ObjectPropertyValue $v 'server_url' ''
      if ($p.Name -like "$ServerName|*" -or $serverNameValue -eq $ServerName -or ([string]$serverUrlValue) -eq $ServerUrl) {
        return $p.Name
      }
    }
  }

  try {
    $python = Find-Python
    $py = @'
import os, re, sqlite3, sys
home, server = sys.argv[1], sys.argv[2]
best = None
for name in ("logs_2.sqlite", "logs_1.sqlite"):
    path = os.path.join(home, name)
    if not os.path.exists(path):
        continue
    try:
        con = sqlite3.connect(path)
        rows = con.execute("select feedback_log_body from logs where feedback_log_body like ? order by id desc limit 500", (f"%{server}|%",)).fetchall()
        for (body,) in rows:
            m = re.search(re.escape(server) + r"\|[0-9a-f]{16}", body or "")
            if m:
                print(m.group(0))
                raise SystemExit(0)
    except Exception:
        pass
'@
    $out = Invoke-PythonCode $python $py @($paths.Home, $ServerName) 2>$null
    if ($out) { return [string]($out | Select-Object -First 1) }
  } catch {
    # Fall through to official Cloudflare plugin default seen in current Codex Desktop builds.
  }

  if ($ServerName -eq 'cloudflare-api') { return 'cloudflare-api|2e40c71145c8b601' }
  return "$ServerName|manual"
}

function Repair-CloudflareMcp {
  $paths = Get-Paths
  if (-not (Test-Path -LiteralPath $paths.Config)) { throw "config.toml not found: $($paths.Config)" }
  Assert-NoControlChars $CloudflareUserAgent 'CloudflareUserAgent'
  $backup = New-BackupSet $paths 'cloudflare-mcp'
  Backup-File $paths.Config $backup | Out-Null

  $content = Read-TextFile $paths.Config
  $cfUrl = ConvertTo-TomlString 'https://mcp.cloudflare.com/mcp'
  $cfUserAgent = ConvertTo-TomlString $CloudflareUserAgent
  $body = @"
url = $cfUrl
enabled = true
oauth_resource = $cfUrl
startup_timeout_sec = 30
tool_timeout_sec = 60
http_headers = { "User-Agent" = $cfUserAgent }
"@
  $content = Set-TomlSection $content 'mcp_servers.cloudflare-api' $body
  Write-TextFile $paths.Config $content
  Write-Step "Cloudflare MCP config repaired."

  if ($CloudflareOAuth) {
    Start-CloudflareOAuth
  } else {
    Write-Step "Cloudflare OAuth skipped. Re-run with -CloudflareOAuth if token login is required."
  }
}

function Start-CloudflareOAuth {
  $paths = Get-Paths
  $backup = New-BackupSet $paths 'cloudflare-oauth'
  Backup-File $paths.Credentials $backup -RedactSecrets | Out-Null

  Add-Type -AssemblyName System.Net.Http
  $listener = [System.Net.HttpListener]::new()
  $tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), 0)
  $tcp.Start()
  $port = $tcp.LocalEndpoint.Port
  $tcp.Stop()
  $redirectUri = "http://127.0.0.1:$port/callback/"
  $listener.Prefixes.Add($redirectUri)
  $listener.Start()

  if ($CloudflareScopes -and $CloudflareScopes.Count -gt 0) {
    $scopes = $CloudflareScopes
  } elseif ($CloudflareScopePreset -eq 'Broad') {
    $scopes = @(
      'offline_access','user:read','account:read','zone:read',
      'dns_records:read','dns_records:edit',
      'workers:read','workers:write',
      'pages:read','pages:write',
      'd1:write','ai:read','ai:write'
    )
  } else {
    $scopes = @('offline_access','user:read','account:read','zone:read','workers:read','pages:read','ai:read')
  }
  Write-Step ("Cloudflare OAuth scopes: {0}" -f ($scopes -join ' '))

  $registerBody = @{
    redirect_uris = @($redirectUri)
    client_name = 'Codex Cloudflare Plugin'
    grant_types = @('authorization_code','refresh_token')
    response_types = @('code')
    token_endpoint_auth_method = 'none'
  } | ConvertTo-Json -Depth 10 -Compress

  $headers = @{ 'User-Agent' = $CloudflareUserAgent; 'Accept' = 'application/json' }
  $client = Invoke-RestMethod -Uri 'https://mcp.cloudflare.com/register' -Method Post -Headers $headers -ContentType 'application/json' -Body $registerBody
  $clientId = [string](Get-ObjectPropertyValue $client 'client_id' '')
  if (-not $clientId) { throw 'Cloudflare dynamic client registration did not return client_id.' }

  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] 48
  $rng.GetBytes($bytes)
  $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
  $sha = [Security.Cryptography.SHA256]::Create()
  $challengeBytes = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
  $challenge = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
  $stateBytes = New-Object byte[] 24
  $rng.GetBytes($stateBytes)
  $state = [Convert]::ToBase64String($stateBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

  $query = @{
    response_type = 'code'
    client_id = $clientId
    redirect_uri = $redirectUri
    code_challenge = $challenge
    code_challenge_method = 'S256'
    state = $state
    resource = 'https://mcp.cloudflare.com/mcp'
    scope = ($scopes -join ' ')
  }
  $authUrl = 'https://mcp.cloudflare.com/authorize?' + (($query.GetEnumerator() | ForEach-Object {
    [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value)
  }) -join '&')

  Write-Step "Open Cloudflare OAuth in browser and approve access."
  if ($NoBrowser) {
    Write-Host $authUrl
  } else {
    Start-Process $authUrl
  }

  $task = $listener.GetContextAsync()
  $deadline = (Get-Date).AddSeconds($CloudflareCallbackTimeoutSec)
  while (-not $task.IsCompleted) {
    if ((Get-Date) -gt $deadline) {
      $listener.Stop()
      throw "Timed out waiting for OAuth callback after $CloudflareCallbackTimeoutSec seconds."
    }
    Start-Sleep -Milliseconds 250
  }

  $context = $task.Result
  $rawQuery = $context.Request.Url.Query.TrimStart('?')
  $params = @{}
  foreach ($part in $rawQuery -split '&') {
    if (-not $part) { continue }
    $kv = $part -split '=', 2
    $k = [uri]::UnescapeDataString($kv[0])
    $v = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+',' ')) } else { '' }
    $params[$k] = $v
  }

  $html = '<html><body><h2>Cloudflare OAuth received. You can close this tab.</h2></body></html>'
  $buffer = [Text.Encoding]::UTF8.GetBytes($html)
  $context.Response.ContentType = 'text/html; charset=utf-8'
  $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
  $context.Response.Close()
  $listener.Stop()

  if ($params.ContainsKey('error')) { throw "Cloudflare OAuth error: $($params['error'])" }
  if ($params['state'] -ne $state) { throw 'Cloudflare OAuth state mismatch.' }
  $code = $params['code']
  if (-not $code) { throw 'Cloudflare OAuth callback did not include code.' }

  $tokenBody = @{
    grant_type = 'authorization_code'
    code = $code
    redirect_uri = $redirectUri
    client_id = $clientId
    code_verifier = $verifier
    resource = 'https://mcp.cloudflare.com/mcp'
  }
  $token = Invoke-RestMethod -Uri 'https://mcp.cloudflare.com/token' -Method Post -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
  $accessToken = [string](Get-ObjectPropertyValue $token 'access_token' '')
  if (-not $accessToken) { throw 'Cloudflare token response did not include access_token.' }

  $expiresInValue = Get-ObjectPropertyValue $token 'expires_in' $null
  $expiresIn = if ($expiresInValue) { [int]$expiresInValue } else { 3600 }
  $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(60, $expiresIn - 60)).ToUnixTimeMilliseconds()
  $key = Get-McpCredentialKey 'cloudflare-api' 'https://mcp.cloudflare.com/mcp'
  $creds = [ordered]@{}
  $existing = Get-JsonObject $paths.Credentials
  if ($existing) {
    foreach ($p in $existing.PSObject.Properties) {
      $v = $p.Value
      $serverName = Get-ObjectPropertyValue $v 'server_name' ''
      $serverUrl = Get-ObjectPropertyValue $v 'server_url' ''
      if ($p.Name -like 'cloudflare-api|*' -or $serverName -eq 'cloudflare-api' -or ([string]$serverUrl) -like '*mcp.cloudflare.com*') {
        continue
      }
      $creds[$p.Name] = $v
    }
  }
  $creds[$key] = [ordered]@{
    server_name = 'cloudflare-api'
    server_url = 'https://mcp.cloudflare.com/mcp'
    client_id = $clientId
    access_token = $accessToken
    expires_at = $expiresAt
    refresh_token = [string](Get-ObjectPropertyValue $token 'refresh_token' '')
    scopes = $scopes
  }
  Write-JsonObject $paths.Credentials $creds
  $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($expiresAt).LocalDateTime
  Write-Step ("Cloudflare OAuth credential saved as {0}; expires_at={1:yyyy-MM-dd HH:mm:ss}; refresh_token={2}" -f $key, $dt, [bool](Get-ObjectPropertyValue $token 'refresh_token' ''))
}

function Repair-SessionVisibility {
  $paths = Get-Paths
  if (-not (Test-Path -LiteralPath $paths.State)) { throw "state_5.sqlite not found: $($paths.State)" }
  $targetProvider = Resolve-TargetProvider $paths
  $backup = New-BackupSet $paths 'session-visibility'
  Backup-File $paths.State $backup | Out-Null

  $python = Find-Python
  $py = @'
import datetime, json, os, re, shutil, sqlite3, sys
from pathlib import Path

home = Path(sys.argv[1])
provider = sys.argv[2]
dry = sys.argv[3].lower() == "true"
backup_dir = Path(sys.argv[4])
thread_filter = sys.argv[5].strip().lower()
path_style = sys.argv[6]
state = home / "state_5.sqlite"
rollout_roots = [(home / "sessions", 0), (home / "archived_sessions", 1)]

def parse_ts(value):
    if not value:
        return None
    try:
        return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

def safe_json(line):
    try:
        return json.loads(line)
    except Exception:
        return None

def thread_id_from_path(path):
    m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$", path.name, re.I)
    return m.group(1) if m else None

def strip_extended(path):
    path = str(path)
    if path.startswith("\\\\?\\UNC\\"):
        return "\\\\" + path[8:]
    if path.startswith("\\\\?\\"):
        return path[4:]
    return path

def to_extended(path):
    path = str(path)
    if path.startswith("\\\\?\\"):
        return path
    if path.startswith("\\\\"):
        return "\\\\?\\UNC\\" + path.lstrip("\\")
    if re.match(r"^[A-Za-z]:\\", path):
        return "\\\\?\\" + path
    return path

def apply_path_style(path, existing=None):
    if path is None:
        return None
    if path_style == "Extended":
        return to_extended(path)
    if path_style == "Normal":
        return strip_extended(path)
    if existing and str(existing).startswith("\\\\?\\"):
        return to_extended(path)
    return strip_extended(path)

def summarize(path, archived):
    tid = thread_id_from_path(path)
    if not tid:
        return None
    if thread_filter and tid.lower() != thread_filter:
        return None
    created_ms = None
    updated_ms = None
    cwd = str(home)
    title = ""
    first_user = ""
    model = None
    effort = None
    sandbox = {"type": "danger-full-access"}
    approval = "never"
    cli = ""

    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for index, line in enumerate(f):
                obj = safe_json(line)
                if not obj:
                    continue
                ts = parse_ts(obj.get("timestamp"))
                if ts:
                    created_ms = created_ms or ts
                    updated_ms = ts
                payload = obj.get("payload") or {}
                typ = obj.get("type")
                if index == 0 and isinstance(payload, dict):
                    cwd = payload.get("cwd") or cwd
                    cli = payload.get("cli_version") or cli
                if typ == "turn_context":
                    cwd = payload.get("cwd") or cwd
                    model = payload.get("model") or model
                    effort = payload.get("effort") or payload.get("reasoning_effort") or effort
                    sandbox = payload.get("sandbox_policy") or sandbox
                    approval = payload.get("approval_policy") or approval
                if typ == "event_msg":
                    if payload.get("type") == "thread_name_updated":
                        title = payload.get("thread_name") or title
                    if payload.get("type") == "user_message" and not first_user:
                        first_user = (payload.get("message") or "").strip()
                if typ == "response_item" and payload.get("type") == "message" and payload.get("role") == "user" and not first_user:
                    parts = payload.get("content") or []
                    texts = []
                    for part in parts:
                        if isinstance(part, dict):
                            texts.append(part.get("text") or part.get("input_text") or "")
                    first_user = "\n".join([t for t in texts if t]).strip()
    except OSError:
        return None

    if not created_ms:
        created_ms = int(path.stat().st_mtime * 1000)
    if not updated_ms:
        updated_ms = int(path.stat().st_mtime * 1000)
    if not title:
        title = first_user[:80].replace("\n", " ") if first_user else tid

    return {
        "id": tid,
        "rollout_path": str(path),
        "created_at": created_ms // 1000,
        "updated_at": updated_ms // 1000,
        "source": "vscode",
        "model_provider": provider,
        "cwd": cwd,
        "title": title,
        "sandbox_policy": json.dumps(sandbox, ensure_ascii=False) if not isinstance(sandbox, str) else sandbox,
        "approval_mode": str(approval),
        "tokens_used": 0,
        "has_user_event": 1 if first_user else 0,
        "archived": archived,
        "archived_at": (updated_ms // 1000) if archived else None,
        "git_sha": None,
        "git_branch": None,
        "git_origin_url": None,
        "cli_version": cli,
        "first_user_message": first_user[:4000],
        "agent_nickname": None,
        "agent_role": None,
        "memory_mode": "enabled",
        "agent_path": None,
        "model": model,
        "reasoning_effort": effort,
        "created_at_ms": created_ms,
        "updated_at_ms": updated_ms,
    }

items = []
for root, archived in rollout_roots:
    if root.exists():
        for path in root.rglob("rollout-*.jsonl"):
            item = summarize(path, archived)
            if item:
                items.append(item)

con = sqlite3.connect(state)
con.row_factory = sqlite3.Row
cols = [r[1] for r in con.execute("pragma table_info(threads)").fetchall()]
existing = {r["id"]: r for r in con.execute("select * from threads").fetchall()}
inserted = 0
updated = 0

if not dry:
    con.execute("begin")
for item in items:
    row = existing.get(item["id"])
    if row is None:
        item["rollout_path"] = apply_path_style(item.get("rollout_path"))
        item["cwd"] = apply_path_style(item.get("cwd"))
        keys = [c for c in cols if c in item]
        placeholders = ",".join(["?"] * len(keys))
        sql = f"insert into threads ({','.join(keys)}) values ({placeholders})"
        if not dry:
            con.execute(sql, [item[k] for k in keys])
        inserted += 1
    else:
        item["rollout_path"] = apply_path_style(item.get("rollout_path"), row["rollout_path"] if "rollout_path" in cols else None)
        item["cwd"] = apply_path_style(item.get("cwd"), row["cwd"] if "cwd" in cols else None)
        changes = {}
        for key in ("model_provider", "rollout_path", "cwd", "title", "updated_at", "updated_at_ms", "archived", "archived_at", "model", "reasoning_effort"):
            if key in cols and item.get(key) is not None and row[key] != item[key]:
                changes[key] = item[key]
        if changes:
            sets = ",".join([f"{k}=?" for k in changes])
            sql = f"update threads set {sets} where id=?"
            if not dry:
                con.execute(sql, list(changes.values()) + [item["id"]])
            updated += 1
if not dry:
    con.commit()

manifest = {
    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "codexHome": str(home),
    "targetProvider": provider,
    "threadIdFilter": thread_filter or None,
    "threadPathStyle": path_style,
    "rolloutFilesScanned": len(items),
    "threadsInserted": inserted,
    "threadsUpdated": updated,
    "dryRun": dry,
}
if not dry:
    backup_dir.mkdir(parents=True, exist_ok=True)
    (backup_dir / "session-visibility-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(manifest, ensure_ascii=False))
'@
  $dryArg = if ($DryRun) { 'true' } else { 'false' }
  $out = Invoke-PythonCode $python $py @($paths.Home, $targetProvider, $dryArg, $backup, $ThreadId, $ThreadPathStyle)
  Write-Step "Session visibility result: $out"
}

switch ($Action) {
  'Diagnose' { Invoke-Diagnose }
  'RepairPluginUi' { Repair-PluginUi; Invoke-Diagnose }
  'RepairCloudflareMcp' { Repair-CloudflareMcp; Invoke-Diagnose }
  'RepairSessionVisibility' { Repair-SessionVisibility; Invoke-Diagnose }
  'RepairAll' {
    Repair-PluginUi
    Repair-CloudflareMcp
    Repair-SessionVisibility
    Invoke-Diagnose
  }
}

