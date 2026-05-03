[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Doctor = Join-Path $RepoRoot 'scripts\CodexDesktopDoctor.ps1'
$Standalone = Join-Path $RepoRoot 'CodexDesktopDoctor.cmd'
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

function Initialize-SessionStateFixture([string]$State) {
  $schema = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("""
create table threads (
  id text primary key,
  rollout_path text,
  cwd text,
  title text,
  model_provider text,
  updated_at integer,
  updated_at_ms integer,
  archived integer,
  archived_at integer,
  model text,
  reasoning_effort text
)
""")
con.commit()
'@
  $schema | python - $State
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create sqlite fixture.' }
}

function Write-RolloutFixture {
  param(
    [string]$FixtureHome,
    [string]$ThreadId,
    [string]$Title = 'Smoke Test Thread',
    [string]$Cwd = 'C:\tmp\fixture'
  )

  $dir = Join-Path $FixtureHome 'sessions\2026\05\03'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $rollout = Join-Path $dir "rollout-2026-05-03T05-00-00-$ThreadId.jsonl"
  @(
    @{ timestamp='2026-05-03T05:00:00Z'; type='session_meta'; payload=@{ cwd=$Cwd; cli_version='0.0.0-test' } },
    @{ timestamp='2026-05-03T05:00:01Z'; type='turn_context'; payload=@{ cwd=$Cwd; model='gpt-5.5'; reasoning_effort='xhigh'; sandbox_policy=@{ type='danger-full-access' }; approval_policy='never' } },
    @{ timestamp='2026-05-03T05:00:02Z'; type='event_msg'; payload=@{ type='user_message'; message="hello from $ThreadId" } },
    @{ timestamp='2026-05-03T05:00:03Z'; type='event_msg'; payload=@{ type='thread_name_updated'; thread_name=$Title } }
  ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 } |
    Set-Content -LiteralPath $rollout -Encoding UTF8

  return $rollout
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

Write-Test 'Standalone CMD Diagnose fixture'
$fixtureHome = New-FixtureHome 'standalone-cmd'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "standalone_provider"

[model_providers.standalone_provider]
name = "standalone_provider"
base_url = "http://127.0.0.1:9999/v1"
requires_openai_auth = false
'@
  $output = & cmd /c "`"$Standalone`" -Action Diagnose -CodexHome `"$fixtureHome`"" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Standalone CMD exited with code $LASTEXITCODE`: $($output | Out-String)" }
  $text = $output | Out-String
  Assert ($text -match 'model_provider:\s*standalone_provider') 'Standalone CMD did not run the embedded Diagnose action.'
  Assert ($text -match 'provider\.base_url:\s*http://127\.0\.0\.1:9999/v1') 'Standalone CMD did not pass arguments correctly.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'Diagnose warns for API key auth fixture'
$fixtureHome = New-FixtureHome 'apikey-auth'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value @'
model_provider = "local_provider"

[model_providers.local_provider]
name = "local_provider"
base_url = "http://127.0.0.1:9999/v1"
requires_openai_auth = true
'@
  Set-Content -LiteralPath (Join-Path $fixtureHome 'auth.json') -Encoding UTF8 -Value (@{
    auth_mode = 'apikey'
    OPENAI_API_KEY = 'agt_test_redacted'
  } | ConvertTo-Json)
  $output = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Doctor -Action Diagnose -CodexHome $fixtureHome 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Diagnose exited with code $LASTEXITCODE`: $($output | Out-String)" }
  $text = $output | Out-String
  Assert ($text -match 'auth_mode:\s*apikey') 'Diagnose did not report API key auth mode.'
  Assert ($text -match 'Plugins/connectors/skills UI require ChatGPT/OAuth login') 'Diagnose did not explain why API key auth keeps plugins grey.'
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

Write-Test 'RepairSessionVisibility Auto preserves existing extended paths'
$fixtureHome = New-FixtureHome 'sessions-auto-path'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value 'model_provider = "codex_local_access"'
  $threadId = '22222222-3333-4444-5555-666666666666'
  $rollout = Write-RolloutFixture -FixtureHome $fixtureHome -ThreadId $threadId -Title 'Extended Path Thread'
  $state = Join-Path $fixtureHome 'state_5.sqlite'
  Initialize-SessionStateFixture $state

  $seed = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("insert into threads (id,rollout_path,cwd,title,model_provider) values (?,?,?,?,?)", (sys.argv[2], sys.argv[3], sys.argv[4], "Old Title", "old_provider"))
con.commit()
'@
  $seed | python - $state $threadId ('\\?\' + $rollout) '\\?\C:\tmp\fixture'
  if ($LASTEXITCODE -ne 0) { throw 'Failed to seed sqlite fixture.' }

  Invoke-Doctor @('-Action','RepairSessionVisibility','-CodexHome',$fixtureHome,'-ProviderName','codex_local_access')
  $query = @'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
row = con.execute("select rollout_path,cwd,title,model_provider from threads where id=?", (sys.argv[2],)).fetchone()
print(json.dumps(dict(row)))
'@
  $row = $query | python - $state $threadId | ConvertFrom-Json
  Assert ($row.rollout_path.StartsWith('\\?\')) 'Auto should preserve existing extended rollout_path style.'
  Assert ($row.cwd.StartsWith('\\?\')) 'Auto should preserve existing extended cwd style.'
  Assert ($row.title -eq 'Extended Path Thread') 'Auto path fixture should still update normal metadata.'
  Assert ($row.model_provider -eq 'codex_local_access') 'Auto path fixture should still update provider metadata.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'RepairSessionVisibility can force extended paths'
$fixtureHome = New-FixtureHome 'sessions-force-extended'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value 'model_provider = "codex_local_access"'
  $threadId = '33333333-4444-5555-6666-777777777777'
  [void](Write-RolloutFixture -FixtureHome $fixtureHome -ThreadId $threadId -Title 'Forced Extended Path Thread')
  $state = Join-Path $fixtureHome 'state_5.sqlite'
  Initialize-SessionStateFixture $state

  Invoke-Doctor @('-Action','RepairSessionVisibility','-CodexHome',$fixtureHome,'-ProviderName','codex_local_access','-ThreadPathStyle','Extended')
  $query = @'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
row = con.execute("select rollout_path,cwd from threads where id=?", (sys.argv[2],)).fetchone()
print(json.dumps(dict(row)))
'@
  $row = $query | python - $state $threadId | ConvertFrom-Json
  Assert ($row.rollout_path.StartsWith('\\?\')) 'ThreadPathStyle=Extended should write extended rollout_path.'
  Assert ($row.cwd.StartsWith('\\?\')) 'ThreadPathStyle=Extended should write extended cwd.'
}
finally {
  Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Test 'RepairSessionVisibility ThreadId only updates one thread'
$fixtureHome = New-FixtureHome 'sessions-thread-filter'
try {
  Set-Content -LiteralPath (Join-Path $fixtureHome 'config.toml') -Encoding UTF8 -Value 'model_provider = "codex_local_access"'
  $threadOne = '44444444-5555-6666-7777-888888888888'
  $threadTwo = '55555555-6666-7777-8888-999999999999'
  [void](Write-RolloutFixture -FixtureHome $fixtureHome -ThreadId $threadOne -Title 'Target Thread')
  [void](Write-RolloutFixture -FixtureHome $fixtureHome -ThreadId $threadTwo -Title 'Other Thread')
  $state = Join-Path $fixtureHome 'state_5.sqlite'
  Initialize-SessionStateFixture $state

  $seed = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("insert into threads (id,rollout_path,cwd,title,model_provider) values (?,?,?,?,?)", (sys.argv[2], "old-one-path", "old-one-cwd", "Old One", "old_provider"))
con.execute("insert into threads (id,rollout_path,cwd,title,model_provider) values (?,?,?,?,?)", (sys.argv[3], "old-two-path", "old-two-cwd", "Old Two", "old_provider"))
con.commit()
'@
  $seed | python - $state $threadOne $threadTwo
  if ($LASTEXITCODE -ne 0) { throw 'Failed to seed sqlite fixture.' }

  Invoke-Doctor @('-Action','RepairSessionVisibility','-CodexHome',$fixtureHome,'-ProviderName','codex_local_access','-ThreadId',$threadOne,'-ThreadPathStyle','Extended')
  $query = @'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
row = con.execute("select rollout_path,cwd,title,model_provider from threads where id=?", (sys.argv[2],)).fetchone()
print(json.dumps(dict(row)))
'@
  $rowOne = $query | python - $state $threadOne | ConvertFrom-Json
  $rowTwo = $query | python - $state $threadTwo | ConvertFrom-Json
  Assert ($rowOne.title -eq 'Target Thread') 'ThreadId filter should update the selected thread.'
  Assert ($rowOne.model_provider -eq 'codex_local_access') 'ThreadId filter should update selected provider metadata.'
  Assert ($rowOne.rollout_path.StartsWith('\\?\')) 'ThreadId filter should allow forcing selected path style.'
  Assert ($rowTwo.title -eq 'Old Two') 'ThreadId filter should not update other thread titles.'
  Assert ($rowTwo.model_provider -eq 'old_provider') 'ThreadId filter should not update other thread providers.'
  Assert ($rowTwo.rollout_path -eq 'old-two-path') 'ThreadId filter should not update other thread paths.'
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
