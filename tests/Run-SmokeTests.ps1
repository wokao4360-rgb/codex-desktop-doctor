[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Doctor = Join-Path $RepoRoot 'scripts\CodexDesktopDoctor.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$WindowsPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Test($Name) {
  Write-Host "== $Name =="
}

function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function New-FixtureHome([string]$Name) {
  $root = Join-Path ([IO.Path]::GetTempPath()) ("codex-doctor-$Name-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Invoke-Doctor([string[]]$DoctorArgs) {
  & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Doctor @DoctorArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Doctor exited with code $LASTEXITCODE"
  }
}

Write-Test 'PowerShell parser'
$parseErrors = $null
[void][System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Doctor -Raw), [ref]$parseErrors)
Assert (($null -eq $parseErrors) -or ($parseErrors.Count -eq 0)) "PowerShell parse errors: $($parseErrors | Out-String)"

Write-Test 'Secret scan'
$literalLeakFragments = @(
  ('982' + '5987'),
  ('agt_' + 'codex')
)
$secretPattern = 'sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{20,}|Bearer [A-Za-z0-9._-]{20,}|' + (($literalLeakFragments | ForEach-Object { [regex]::Escape($_) }) -join '|')
$hits = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File |
  Where-Object { $_.FullName -notmatch '\\\.git\\' } |
  Select-String -Pattern $secretPattern -AllMatches
Assert (-not $hits) "Potential secret-like strings found: $($hits | Select-Object -First 5 | Out-String)"

Write-Test 'RepairPluginUi keeps current provider fixture'
$fixtureHome = New-FixtureHome 'plugin'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "cc_switch_provider"

[model_providers.cc_switch_provider]
name = "cc_switch_provider"
base_url = "http://127.0.0.1:3456/v1"
env_key = "OLD_KEY"
requires_openai_auth = false

[features]
remote_control = true

[other]
keep = "yes"
'@
  Invoke-Doctor @('-Action','RepairPluginUi','-CodexHome',$fixtureHome)
  $config = Get-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Raw
  Assert ($config -match 'model_provider\s*=\s*"cc_switch_provider"') 'model_provider should not be switched by default.'
  Assert ($config -match '\[model_providers\.cc_switch_provider\]') 'current provider section was not preserved.'
  Assert ($config -match 'base_url\s*=\s*"http://127\.0\.0\.1:3456/v1"') 'existing provider base_url was not preserved.'
  Assert ($config -match 'requires_openai_auth\s*=\s*true') 'requires_openai_auth was not enabled.'
  Assert ($config -match 'remote_control\s*=\s*false') 'remote_control was not disabled.'
  Assert ($config -match 'keep\s*=\s*"yes"') 'unrelated section was not preserved.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'RepairPluginUi explicit provider fixture'
$fixtureHome = New-FixtureHome 'plugin-explicit'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "old_provider"

[model_providers.old_provider]
name = "old_provider"
base_url = "http://example.invalid/v1"
requires_openai_auth = false
'@
  Invoke-Doctor @('-Action','RepairPluginUi','-CodexHome',$fixtureHome,'-ProviderName','codex_local_access','-ProviderBaseUrl','http://127.0.0.1:53528/v1','-LocalTokenEnvVar','CODEX_LOCAL_ACCESS_TOKEN','-ProviderWireApi','responses')
  $config = Get-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Raw
  Assert ($config -match 'model_provider\s*=\s*"codex_local_access"') 'explicit model_provider was not selected.'
  Assert ($config -match '\[model_providers\.codex_local_access\]') 'explicit provider section was not created.'
  Assert ($config -match 'env_key\s*=\s*"CODEX_LOCAL_ACCESS_TOKEN"') 'explicit env_key was not written.'
  Assert ($config -match 'wire_api\s*=\s*"responses"') 'explicit wire_api was not written.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'RepairCloudflareMcp fixture'
$fixtureHome = New-FixtureHome 'cloudflare'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value 'model_provider = "codex_local_access"'
  Invoke-Doctor @('-Action','RepairCloudflareMcp','-CodexHome',$fixtureHome)
  $config = Get-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Raw
  Assert ($config -match '\[mcp_servers\.cloudflare-api\]') 'cloudflare MCP section was not created.'
  Assert ($config -match 'http_headers\s*=\s*\{\s*"User-Agent"\s*=\s*"curl/8\.15\.0"\s*\}') 'Cloudflare User-Agent header was not written.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'Diagnose tolerates unknown credential shapes'
$fixtureHome = New-FixtureHome 'credentials'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "codex_local_access"

[model_providers.codex_local_access]
name = "codex_local_access"
base_url = "http://127.0.0.1:53528/v1"
requires_openai_auth = true
'@
  Set-Content -LiteralPath (Join-Path $fixtureHome '.credentials.json') -Encoding UTF8 -Value (@{
    random = @{ foo = 'bar' }
    'cloudflare-api|abc' = @{ expires_at = 1893456000000 }
  } | ConvertTo-Json -Depth 10)
  Invoke-Doctor @('-Action','Diagnose','-CodexHome',$fixtureHome)
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'RepairSessionVisibility fixture'
$fixtureHome = New-FixtureHome 'sessions'
try {
  New-Item -ItemType Directory -Force -Path (Join-Path $fixtureHome 'sessions\2026\05\03') | Out-Null
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value 'model_provider = "codex_local_access"'
  $threadId = '11111111-2222-3333-4444-555555555555'
  $rollout = Join-Path $fixtureHome "sessions\2026\05\03\rollout-2026-05-03T05-00-00-$threadId.jsonl"
  @(
    @{ timestamp='2026-05-03T05:00:00Z'; type='session_meta'; payload=@{ cwd='C:\tmp\fixture'; cli_version='0.0.0-test' } },
    @{ timestamp='2026-05-03T05:00:01Z'; type='turn_context'; payload=@{ cwd='C:\tmp\fixture'; model='gpt-5.5'; reasoning_effort='xhigh'; sandbox_policy=@{ type='danger-full-access' }; approval_policy='never' } },
    @{ timestamp='2026-05-03T05:00:02Z'; type='event_msg'; payload=@{ type='user_message'; message='hello from smoke test' } },
    @{ timestamp='2026-05-03T05:00:03Z'; type='event_msg'; payload=@{ type='thread_name_updated'; thread_name='Smoke Test Thread' } }
  ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 } |
    Set-Content -LiteralPath $rollout -Encoding UTF8

  $state = Join-Path $fixtureHome 'state_5.sqlite'
  $schema = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("""
create table threads (
  id text primary key,
  rollout_path text not null,
  created_at integer not null,
  updated_at integer not null,
  source text not null,
  model_provider text not null,
  cwd text not null,
  title text not null,
  sandbox_policy text not null,
  approval_mode text not null,
  tokens_used integer not null default 0,
  has_user_event integer not null default 0,
  archived integer not null default 0,
  archived_at integer,
  git_sha text,
  git_branch text,
  git_origin_url text,
  cli_version text not null default '',
  first_user_message text not null default '',
  agent_nickname text,
  agent_role text,
  memory_mode text not null default 'enabled',
  agent_path text,
  model text,
  reasoning_effort text,
  created_at_ms integer,
  updated_at_ms integer
)
""")
con.commit()
'@
  $schema | python - $state
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create sqlite fixture.' }

  Invoke-Doctor @('-Action','RepairSessionVisibility','-CodexHome',$fixtureHome,'-ProviderName','codex_local_access')
  $query = "import sqlite3,sys; con=sqlite3.connect(sys.argv[1]); print(con.execute('select id,title,model_provider,model,reasoning_effort from threads').fetchall())"
  $rows = python -c $query $state
  Assert ($rows -match $threadId) 'thread row was not inserted.'
  Assert ($rows -match 'Smoke Test Thread') 'thread title was not populated.'
  Assert ($rows -match 'codex_local_access') 'thread provider was not populated.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'Windows PowerShell Diagnose compatibility'
if (Test-Path -LiteralPath $WindowsPowerShellExe) {
  $fixtureHome = New-FixtureHome 'winps'
  try {
    Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "winps_provider"

[model_providers.winps_provider]
name = "winps_provider"
base_url = "http://127.0.0.1:9876/v1"
requires_openai_auth = true
'@
    $state = Join-Path $fixtureHome 'state_5.sqlite'
    $schema = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table threads (id text primary key)")
con.execute("insert into threads (id) values ('winps-smoke')")
con.commit()
'@
    $schema | python - $state
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create Windows PowerShell sqlite fixture.' }
    $output = & $WindowsPowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Doctor -Action Diagnose -CodexHome $fixtureHome 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell Diagnose exited with code $LASTEXITCODE`: $($output | Out-String)" }
    Assert (($output | Out-String) -match 'state_5\.sqlite threads:\s*1') 'Windows PowerShell Diagnose did not report the sqlite thread count.'
  }
  finally {
    Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
  }
} else {
  Write-Host 'Windows PowerShell not found; skipping.'
}

Write-Host 'All smoke tests passed.'
