$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (!$PSVersionTable -or $PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion -lt [version]"5.1") {
  [Console]::Error.WriteLine("BUILDA_UNSUPPORTED_POWERSHELL: Run .builda-agent\builda.cmd")
  exit 2
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Shared by the Windows installer and CLI self-update. Keep Windows PowerShell 5.1 syntax.
function Read-Utf8Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.Encoding]::UTF8)
}

function Write-Utf8Text {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $Encoding = New-Object System.Text.UTF8Encoding($false)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Parent = [System.IO.Path]::GetDirectoryName($FullPath)
  if ($Parent) { [System.IO.Directory]::CreateDirectory($Parent) | Out-Null }
  [System.IO.File]::WriteAllText($FullPath, $Content, $Encoding)
}

function Write-WindowsPowerShellScript {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $Encoding = New-Object System.Text.UTF8Encoding($true)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Parent = [System.IO.Path]::GetDirectoryName($FullPath)
  if ($Parent) { [System.IO.Directory]::CreateDirectory($Parent) | Out-Null }
  [System.IO.File]::WriteAllText($FullPath, $Content, $Encoding)
}

function Get-BuildaFileSha256 {
  param([string]$Path)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Stream = $null
  $Hasher = $null
  try {
    $Stream = [System.IO.File]::Open(
      $FullPath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    [byte[]]$Digest = $Hasher.ComputeHash($Stream)
    return -join ($Digest | ForEach-Object { $_.ToString("x2") })
  } finally {
    if ($Hasher -is [System.IDisposable]) { $Hasher.Dispose() }
    if ($Stream -is [System.IDisposable]) { $Stream.Dispose() }
  }
}

function Get-BuildaExceptionChain {
  param([object]$Failure)
  [object[]]$Items = @()
  $Current = if ($Failure -is [System.Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
  while ($null -ne $Current -and $Items -notcontains $Current) {
    $Items += $Current
    $Current = $Current.InnerException
  }
  return $Items
}

function Test-BuildaSchannelNoCredentials {
  param([object]$Failure)
  foreach ($Exception in @(Get-BuildaExceptionChain $Failure)) {
    $Message = [string]$Exception.Message
    $HexHResult = ""
    try { $HexHResult = "{0:X8}" -f ([uint32]$Exception.HResult) } catch { $HexHResult = "" }
    if ($HexHResult -eq "8009030E" -or
        $Message -match '(?i)SEC_E_NO_CREDENTIALS|0x8009030e|No credentials are available in the security package' -or
        $Message -like '*安全包中没有可用的凭证*') {
      return $true
    }
  }
  return $false
}

function Get-BuildaDownloadFailureSummary {
  param([object]$Failure, [string]$Transport)
  $Exception = @(Get-BuildaExceptionChain $Failure) | Select-Object -Last 1
  $Type = if ($Exception) { $Exception.GetType().FullName } else { "unknown" }
  $HexHResult = "unknown"
  if ($Exception) {
    try { $HexHResult = "0x{0:X8}" -f ([uint32]$Exception.HResult) } catch { $HexHResult = "unknown" }
  }
  return "transport=$Transport hresult=$HexHResult exception=$Type"
}

function Invoke-BuildaNodeRawDownload {
  param([string]$Uri, [string]$Destination)
  $Node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
  if (!$Node) { $Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue }
  if (!$Node) {
    throw "BUILDA_WINDOWS_TLS_UNAVAILABLE: code=SEC_E_NO_CREDENTIALS transport=schannel recovery=install Node.js or run outside the restricted environment"
  }

  $FullDestination = [System.IO.Path]::GetFullPath($Destination)
  $Part = "$FullDestination.node-part-$PID"
  $PreviousUri = $env:BUILDA_DOWNLOAD_URI
  $PreviousDestination = $env:BUILDA_DOWNLOAD_DESTINATION
  $PreviousPart = $env:BUILDA_DOWNLOAD_PART
  $env:BUILDA_DOWNLOAD_URI = $Uri
  $env:BUILDA_DOWNLOAD_DESTINATION = $FullDestination
  $env:BUILDA_DOWNLOAD_PART = $Part
  $NodeScript = @'
const fs = require('fs');
const http = require('http');
const https = require('https');
const source = process.env.BUILDA_DOWNLOAD_URI;
const destination = process.env.BUILDA_DOWNLOAD_DESTINATION;
const part = process.env.BUILDA_DOWNLOAD_PART;
function fail(error) {
  try { fs.unlinkSync(part); } catch (_) {}
  process.stderr.write('node download failed: ' + (error && error.message ? error.message : String(error)) + '\n');
  process.exit(1);
}
function download(url, redirects) {
  if (redirects > 5) return fail(new Error('too many redirects'));
  const parsed = new URL(url);
  const transport = parsed.protocol === 'https:' ? https : parsed.protocol === 'http:' ? http : null;
  if (!transport) return fail(new Error('unsupported protocol'));
  const request = transport.get(parsed, { timeout: 30000 }, response => {
    if ([301, 302, 303, 307, 308].includes(response.statusCode) && response.headers.location) {
      response.resume();
      return download(new URL(response.headers.location, parsed).toString(), redirects + 1);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      response.resume();
      return fail(new Error('HTTP ' + response.statusCode));
    }
    const output = fs.createWriteStream(part, { flags: 'w' });
    output.on('error', fail);
    response.on('error', fail);
    output.on('finish', () => output.close(() => {
      try { fs.unlinkSync(destination); } catch (error) { if (error.code !== 'ENOENT') return fail(error); }
      try { fs.renameSync(part, destination); } catch (error) { return fail(error); }
    }));
    response.pipe(output);
  });
  request.on('timeout', () => request.destroy(new Error('timeout')));
  request.on('error', fail);
}
download(source, 0);
'@
  try {
    Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
    & $Node.Source -e $NodeScript
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0 -or !(Test-Path -LiteralPath $FullDestination)) {
      throw "BUILDA_DOWNLOAD_FAILED: transport=node-openssl exit=$ExitCode"
    }
    $script:BuildaLastDownloadTransport = "node-openssl"
  } finally {
    Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
    if ($null -eq $PreviousUri) { Remove-Item Env:BUILDA_DOWNLOAD_URI -ErrorAction SilentlyContinue } else { $env:BUILDA_DOWNLOAD_URI = $PreviousUri }
    if ($null -eq $PreviousDestination) { Remove-Item Env:BUILDA_DOWNLOAD_DESTINATION -ErrorAction SilentlyContinue } else { $env:BUILDA_DOWNLOAD_DESTINATION = $PreviousDestination }
    if ($null -eq $PreviousPart) { Remove-Item Env:BUILDA_DOWNLOAD_PART -ErrorAction SilentlyContinue } else { $env:BUILDA_DOWNLOAD_PART = $PreviousPart }
  }
}

function Invoke-BuildaRawDownload {
  param([string]$Uri, [string]$Destination)
  $PreviousProgressPreference = $ProgressPreference
  $ProgressPreference = "SilentlyContinue"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    $script:BuildaLastDownloadTransport = "powershell-webrequest"
  } catch {
    if (!(Test-BuildaSchannelNoCredentials $_)) {
      $Summary = Get-BuildaDownloadFailureSummary $_ "powershell-webrequest"
      throw "BUILDA_DOWNLOAD_FAILED: $Summary"
    }
    [Console]::Error.WriteLine("download-warning=schannel-no-credentials retry-transport=node-openssl")
    Invoke-BuildaNodeRawDownload -Uri $Uri -Destination $Destination
  } finally {
    $ProgressPreference = $PreviousProgressPreference
  }
}

function Get-BuildaRemoteUtf8Text {
  param([string]$Uri)
  $Temporary = [System.IO.Path]::GetTempFileName()
  try {
    Invoke-BuildaRawDownload -Uri $Uri -Destination $Temporary
    return Read-Utf8Text $Temporary
  } finally {
    Remove-Item -Force -LiteralPath $Temporary -ErrorAction SilentlyContinue
  }
}

function Get-BuildaRemoteJson {
  param([string]$Uri)
  return (Get-BuildaRemoteUtf8Text -Uri $Uri | ConvertFrom-Json)
}

function Test-WindowsPowerShellScriptBom {
  param([string]$Path)
  [byte[]]$Prefix = [System.IO.File]::ReadAllBytes($Path)
  return $Prefix.Length -ge 3 -and $Prefix[0] -eq 0xef -and $Prefix[1] -eq 0xbb -and $Prefix[2] -eq 0xbf
}

function Install-BuildaWindowsToolchain {
  param(
    [string]$Root,
    [string]$ReleaseBase,
    [string]$ExpectedVersion,
    [scriptblock]$ReplaceAction = $null,
    [scriptblock]$RestoreAction = $null
  )

  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($Root)) | Out-Null
  $TransactionRoot = Join-Path $Root (".windows-install-" + [System.Guid]::NewGuid().ToString("N"))
  $StageRoot = Join-Path $TransactionRoot "stage"
  $BackupRoot = Join-Path $TransactionRoot "backup"
  New-Item -ItemType Directory -Force -Path $StageRoot, $BackupRoot | Out-Null
  $Files = @(
    @{ Remote = "builda"; Local = "builda"; Script = $false },
    @{ Remote = "builda.ps1"; Local = "builda.ps1"; Script = $true },
    @{ Remote = "builda.cmd"; Local = "builda.cmd"; Script = $false },
    @{ Remote = "builda-skill.md"; Local = "SKILL.md"; Script = $false }
  )
  $Replaced = New-Object System.Collections.Generic.List[object]
  $TransactionCommitted = $false
  $RollbackComplete = $false

  try {
    $ManifestPath = Join-Path $TransactionRoot "manifest.json"
    Invoke-BuildaRawDownload "$ReleaseBase/manifest.json" $ManifestPath
    $Manifest = Read-Utf8Text $ManifestPath | ConvertFrom-Json
    if ([string]$Manifest.version -ne $ExpectedVersion) {
      throw "release manifest version mismatch: expected $ExpectedVersion, got $($Manifest.version)"
    }
    foreach ($File in $Files) {
      $RemoteName = [string]$File.Remote
      $MetadataProperty = $Manifest.artifacts.PSObject.Properties[$RemoteName]
      if (!$MetadataProperty -or !$MetadataProperty.Value.sha256) {
        throw "release manifest is missing SHA-256 for $RemoteName"
      }
      $StagePath = Join-Path $StageRoot ([string]$File.Local)
      Invoke-BuildaRawDownload "$ReleaseBase/$RemoteName" $StagePath
      $ActualSha = Get-BuildaFileSha256 $StagePath
      $ExpectedSha = ([string]$MetadataProperty.Value.sha256).ToLowerInvariant()
      if ($ActualSha -ne $ExpectedSha) { throw "SHA-256 mismatch for $RemoteName" }
      if ($File.Script -and !(Test-WindowsPowerShellScriptBom $StagePath)) {
        throw "$RemoteName is missing the Windows PowerShell UTF-8 BOM"
      }
    }

    $CliText = Read-Utf8Text (Join-Path $StageRoot "builda.ps1")
    if ($CliText -notmatch ('\$Version\s*=\s*"' + [regex]::Escape($ExpectedVersion) + '"')) {
      throw "builda.ps1 version does not match $ExpectedVersion"
    }
    $SkillText = Read-Utf8Text (Join-Path $StageRoot "SKILL.md")
    # The English marker is authoritative; the Chinese marker stays in the Skill's HTML comment for Windows CLI 0.4.101 and earlier to verify, and is accepted here too.
    if ($SkillText -notlike "*BuildaGame agent toolchain version: $ExpectedVersion*" -and $SkillText -notlike "*BuildaGame agent 工具链版本：$ExpectedVersion*") {
      throw "SKILL.md version does not match $ExpectedVersion"
    }
    $CmdText = Read-Utf8Text (Join-Path $StageRoot "builda.cmd")
    if ($CmdText -notlike '*%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe*' -or $CmdText -notlike '*"%~dp0builda.ps1" %**') {
      throw "builda.cmd does not pin Windows PowerShell 5.1 or preserve arguments"
    }
    $UnixText = Read-Utf8Text (Join-Path $StageRoot "builda")
    if (!$UnixText.StartsWith("#!/usr/bin/env bash")) { throw "builda Unix launcher is invalid" }

    Write-Utf8Text (Join-Path $StageRoot "VERSION") "$ExpectedVersion$([Environment]::NewLine)"
    $InstallFiles = @($Files) + @(@{ Local = "VERSION" })
    foreach ($File in $InstallFiles) {
      $LocalName = [string]$File.Local
      $StagePath = Join-Path $StageRoot $LocalName
      $Destination = Join-Path $Root $LocalName
      $BackupPath = Join-Path $BackupRoot $LocalName
      $Existed = Test-Path -LiteralPath $Destination
      if ($ReplaceAction) {
        & $ReplaceAction $StagePath $Destination $BackupPath $Existed
      } else {
        if ($Existed) {
          [System.IO.File]::Replace([System.IO.Path]::GetFullPath($StagePath), [System.IO.Path]::GetFullPath($Destination), [System.IO.Path]::GetFullPath($BackupPath), $true)
        } else {
          [System.IO.File]::Move([System.IO.Path]::GetFullPath($StagePath), [System.IO.Path]::GetFullPath($Destination))
        }
      }
      $Replaced.Add(@{ Path = $Destination; Backup = $BackupPath; Existed = $Existed })
    }
    $TransactionCommitted = $true
  } catch {
    $OriginalFailure = $_.Exception.Message
    $RollbackFailures = New-Object System.Collections.Generic.List[string]
    for ($Index = $Replaced.Count - 1; $Index -ge 0; $Index--) {
      $Entry = $Replaced[$Index]
      try {
        if ($RestoreAction) {
          & $RestoreAction $Entry.Path $Entry.Backup $Entry.Existed
        } else {
          if ($Entry.Existed -and (Test-Path -LiteralPath $Entry.Backup)) {
            if (Test-Path -LiteralPath $Entry.Path) { Remove-Item -Force -LiteralPath $Entry.Path }
            Move-Item -Force -LiteralPath $Entry.Backup -Destination $Entry.Path
          } elseif (!$Entry.Existed -and (Test-Path -LiteralPath $Entry.Path)) {
            Remove-Item -Force -LiteralPath $Entry.Path
          }
        }
      } catch {
        $RollbackFailures.Add("$($Entry.Path): $($_.Exception.Message)")
      }
    }
    if ($RollbackFailures.Count -gt 0) {
      [Console]::Error.WriteLine("BUILDA_INSTALL_ROLLBACK_FAILED: transaction preserved at $TransactionRoot")
      throw "BUILDA_INSTALL_ROLLBACK_FAILED: original=$OriginalFailure rollback=$([string]::Join('; ', $RollbackFailures)) transaction=$TransactionRoot"
    }
    $RollbackComplete = $true
    throw
  } finally {
    if (($TransactionCommitted -or $RollbackComplete) -and (Test-Path -LiteralPath $TransactionRoot)) {
      try {
        Remove-Item -Recurse -Force -LiteralPath $TransactionRoot
      } catch {
        [Console]::Error.WriteLine("BUILDA_INSTALL_CLEANUP_WARNING: transaction cleanup failed; remove manually: $TransactionRoot")
      }
    }
  }
}


$SelfDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($PSCommandPath))
# The legacy name .builda-godot-agent (pre multi-engine) is migrated automatically by Invoke-LegacyProjectDirMigrate / Invoke-LegacyAuthMigrate
$UserAuthDir = Join-Path $HOME ".builda-agent"
$AuthDir = if ($env:BUILDA_AUTH_DIR) { [System.IO.Path]::GetFullPath($env:BUILDA_AUTH_DIR) } else { $UserAuthDir }
$LegacyAuthDir = Join-Path $HOME ".builda-godot-agent"
$ProjectStateDir = if ($env:BUILDA_PROJECT_STATE_DIR) { $env:BUILDA_PROJECT_STATE_DIR } else { ".builda-agent" }
$LegacyProjectStateDir = ".builda-godot-agent"
$Root = $ProjectStateDir
$EnvPath = Join-Path $Root "publish.env"
$TokenPath = Join-Path $AuthDir "token"
$RefreshPath = Join-Path $AuthDir "refresh-token"
$IssueTokenPath = Join-Path $AuthDir "issue-token"
$IssueRefreshPath = Join-Path $AuthDir "issue-refresh-token"
$IssueActorPath = Join-Path $AuthDir "issue-actor-id"
$Manifest = if ($env:BUILDA_MANIFEST) { $env:BUILDA_MANIFEST } else { "builda.publish.json" }
$ProjectFile = if ($env:BUILDA_PROJECT_FILE) { $env:BUILDA_PROJECT_FILE } else { Join-Path $ProjectStateDir "game.json" }
$LegacyProjectFile = if ($env:BUILDA_LEGACY_PROJECT_FILE) { $env:BUILDA_LEGACY_PROJECT_FILE } else { "builda.game.json" }
$Version = "0.4.105"
$RuntimeVersionFile = Join-Path $Root "VERSION"
$SdkVersionFile = Join-Path $ProjectStateDir "sdk-version"
$DefaultBase = "https://builda-godot-api.poni.fun"
if ($DefaultBase -like "{{*") {
  $DefaultBase = ""
}
$Base = $DefaultBase
$DefaultAgentBase = "https://ai.builda.game"
if ($DefaultAgentBase -like "{{*") {
  $DefaultAgentBase = $Base
}
$AgentBase = $DefaultAgentBase
$DefaultSiteBase = "https://builda.game"
if ($DefaultSiteBase -like "{{*") {
  $DefaultSiteBase = "https://builda.game"
}
$SiteOrigin = ""
$EarlyAccessUrl = ""
$PairCode = ""
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)

function Read-Utf8Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), $script:Utf8Strict)
}

function Read-Utf8Lines {
  param([string]$Path)
  return [System.IO.File]::ReadAllLines([System.IO.Path]::GetFullPath($Path), $script:Utf8Strict)
}

function Write-Utf8TextNoBom {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Parent = [System.IO.Path]::GetDirectoryName($FullPath)
  if ($Parent) { [System.IO.Directory]::CreateDirectory($Parent) | Out-Null }
  [System.IO.File]::WriteAllText($FullPath, $Content, $script:Utf8NoBom)
}

function Append-Utf8TextNoBom {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Parent = [System.IO.Path]::GetDirectoryName($FullPath)
  if ($Parent) { [System.IO.Directory]::CreateDirectory($Parent) | Out-Null }
  [System.IO.File]::AppendAllText($FullPath, $Content, $script:Utf8NoBom)
}

function Write-Utf8LinesNoBom {
  param([string]$Path, [System.Collections.IEnumerable]$Lines)
  [string[]]$Values = @($Lines | ForEach-Object { [string]$_ })
  $Content = [string]::Join([Environment]::NewLine, $Values)
  if ($Values.Count -gt 0) { $Content += [Environment]::NewLine }
  Write-Utf8TextNoBom $Path $Content
}

if (Test-Path $EnvPath) {
  Read-Utf8Lines $EnvPath | ForEach-Object {
    if ($_ -match "^BUILDA_BASE=(.*)$") { $script:Base = $Matches[1].Trim() }
    if ($_ -match "^BUILDA_AGENT_BASE=(.*)$") { $script:AgentBase = $Matches[1].Trim() }
    if ($_ -match "^BUILDA_SITE_ORIGIN=(.*)$") { $script:SiteOrigin = $Matches[1].Trim() }
    if ($_ -match "^BUILDA_PAIR_CODE=(.*)$") { $script:PairCode = $Matches[1].Trim() }
  }
}
if ($env:BUILDA_STUDIO_API_BASE) {
  # Studio Worker explicitly injects the in-cluster API; external users keep using the public address from the project's publish.env.
  $Base = $env:BUILDA_STUDIO_API_BASE.Trim()
}
$EffectiveSiteBase = if ($SiteOrigin) { $SiteOrigin } else { $DefaultSiteBase }
$EarlyAccessUrl = if ($env:BUILDA_EARLY_ACCESS_URL) { $env:BUILDA_EARLY_ACCESS_URL } else { "$EffectiveSiteBase/early-access" }
$IssueBase = if ($env:BUILDA_ISSUE_BASE) { $env:BUILDA_ISSUE_BASE.TrimEnd('/') } else { $Base.TrimEnd('/') }

# Inlined into builda.ps1. C# owns strict/case-sensitive Schema JSON; PowerShell
# only orchestrates frozen operation state and existing publish primitives.
$script:ObjectSchemasReady = $false
$script:ObjectSchemasSource = @'
// Inlined into Windows PowerShell 5.1. Uses only .NET Framework base libraries.
// JSON numbers and case-sensitive member names remain lossless until validated.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public static class BuildaObjectSchemas
{
    private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    private static readonly Regex Identifier = new Regex(@"\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\z", RegexOptions.CultureInvariant);
    private sealed class Number
    {
        public readonly string Text;
        public Number(string text) { Text = text; }
    }

    private static Exception Invalid(string message) { return new FormatException("schema_invalid: " + message); }
    private static Exception Limit(string message) { return new FormatException("schema_limit_exceeded: " + message); }

    private const int MaxSchemaDepth = 16;
    private const int MaxSchemaNodes = 1024;
    private const int MaxDefinitionBytes = 16 * 1024;
    private const int MaxSchemaItems = 100;
    private const int MaxSchemaArrayBytes = 256 * 1024;
    private static readonly Regex PlainField = new Regex(@"\A[A-Za-z_][A-Za-z0-9_]*\z");

    // where names the definition and path the node, so a limit failure points at the exact spot.
    private static string At(string where, string path) { return where + " " + path + ": "; }
    private static string ChildPath(string path, string name) { return PlainField.IsMatch(name) ? path + "." + name : path + "[" + Json(name) + "]"; }

    private sealed class Parser
    {
        private readonly string text;
        private int position;
        public int SchemaBytes;
        public Parser(string input)
        {
            if (Utf8.GetByteCount(input) > 2 * 1024 * 1024) throw Limit("JSON exceeds 2 MiB");
            text = input;
        }
        private void Space() { while (position < text.Length && " \t\r\n".IndexOf(text[position]) >= 0) position++; }
        private bool Take(char c)
        {
            Space();
            if (position >= text.Length || text[position] != c) return false;
            position++;
            return true;
        }
        private void Expect(char c) { if (!Take(c)) throw Invalid("invalid JSON delimiter"); }
        public object Read()
        {
            object result = Value(0);
            Space();
            if (position != text.Length) throw Invalid("trailing JSON input");
            return result;
        }
        private object Value(int depth)
        {
            if (depth > 64) throw Invalid("JSON nesting exceeds 64");
            Space();
            if (position >= text.Length) throw Invalid("incomplete JSON");
            char c = text[position];
            if (c == '{') return Object(depth);
            if (c == '[') return Array(depth);
            if (c == '"') return String();
            if (c == 't') { Literal("true"); return true; }
            if (c == 'f') { Literal("false"); return false; }
            if (c == 'n') { Literal("null"); return null; }
            int start = position;
            while (position < text.Length && "0123456789.-+eE".IndexOf(text[position]) >= 0) position++;
            string number = text.Substring(start, position - start);
            if (!Regex.IsMatch(number, @"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z", RegexOptions.CultureInvariant)) throw Invalid("invalid JSON number");
            return new Number(number);
        }
        private void Literal(string value)
        {
            if (position + value.Length > text.Length || System.String.CompareOrdinal(text, position, value, 0, value.Length) != 0) throw Invalid("invalid JSON literal");
            position += value.Length;
        }
        private Dictionary<string, object> Object(int depth)
        {
            Expect('{');
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            if (Take('}')) return result;
            do
            {
                string key = String();
                Expect(':');
                Space();
                int start = position;
                object value = Value(depth + 1);
                if (result.ContainsKey(key)) throw Invalid("duplicate JSON member");
                result.Add(key, value);
                if (depth == 0 && key == "objectSchemas") SchemaBytes = Utf8.GetByteCount(text.Substring(start, position - start));
                if (Take('}')) return result;
                Expect(',');
            } while (true);
        }
        private List<object> Array(int depth)
        {
            Expect('[');
            var result = new List<object>();
            if (Take(']')) return result;
            do
            {
                result.Add(Value(depth + 1));
                if (Take(']')) return result;
                Expect(',');
            } while (true);
        }
        private string String()
        {
            Expect('"');
            var result = new StringBuilder();
            while (position < text.Length)
            {
                char c = text[position++];
                if (c == '"')
                {
                    string value = result.ToString();
                    Utf8.GetByteCount(value); // Reject unpaired UTF-16, including escaped surrogates.
                    return value;
                }
                if (c < 32) throw Invalid("unescaped JSON control character");
                if (c != '\\') { result.Append(c); continue; }
                if (position >= text.Length) throw Invalid("incomplete JSON escape");
                c = text[position++];
                switch (c)
                {
                    case '"': case '\\': case '/': result.Append(c); break;
                    case 'b': result.Append('\b'); break;
                    case 'f': result.Append('\f'); break;
                    case 'n': result.Append('\n'); break;
                    case 'r': result.Append('\r'); break;
                    case 't': result.Append('\t'); break;
                    case 'u':
                        if (position + 4 > text.Length) throw Invalid("incomplete Unicode escape");
                        string hex = text.Substring(position, 4);
                        if (!Regex.IsMatch(hex, @"\A[0-9A-Fa-f]{4}\z")) throw Invalid("invalid Unicode escape");
                        result.Append((char)Int32.Parse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        position += 4;
                        break;
                    default: throw Invalid("invalid JSON escape");
                }
            }
            throw Invalid("unterminated JSON string");
        }
    }

    private static Dictionary<string, object> Map(object value)
    {
        var result = value as Dictionary<string, object>;
        if (result == null) throw Invalid("expected JSON object");
        return result;
    }
    private static object Get(Dictionary<string, object> value, string key)
    {
        object result;
        if (!value.TryGetValue(key, out result)) throw Invalid("required member missing: " + key);
        return result;
    }
    private static string Text(object value)
    {
        var text = value as string;
        if (text == null) throw Invalid("expected JSON string");
        return text;
    }
    private static uint Version(object value)
    {
        var number = value as Number;
        uint result;
        if (number == null || !Regex.IsMatch(number.Text, @"\A[1-9][0-9]*\z") || !UInt32.TryParse(number.Text, NumberStyles.None, CultureInfo.InvariantCulture, out result)) throw Invalid("schemaVersion must be a uint32 integer");
        return result;
    }

    private static void Node(object value, int depth, bool field, ref int count, string where, string path)
    {
        count++;
        if (depth > MaxSchemaDepth) throw Invalid(At(where, path) + "nesting depth " + depth.ToString(CultureInfo.InvariantCulture) + " exceeds limit " + MaxSchemaDepth.ToString(CultureInfo.InvariantCulture) + " (root is depth 0)");
        if (count > MaxSchemaNodes) throw Invalid(At(where, path) + "definition exceeds " + MaxSchemaNodes.ToString(CultureInfo.InvariantCulture) + " nodes");
        if (!(value is Dictionary<string, object>)) throw Invalid(At(where, path) + "node must be an object");
        var node = Map(value);
        foreach (string key in node.Keys)
            if (key != "kind" && key != "fields" && key != "mapValue" && key != "optional") throw Invalid(At(where, path) + "unknown node field");
        if (node.ContainsKey("optional") != field || (field && !(node["optional"] is bool))) throw Invalid(At(where, path) + "optional must be explicit only on fixed fields");
        string kind = node.ContainsKey("kind") ? node["kind"] as string : null;
        if (kind != "bool" && kind != "int64" && kind != "float64" && kind != "string" && kind != "bytes" && kind != "map") throw Invalid(At(where, path) + "unsupported node kind");
        if (kind != "map")
        {
            if (node.ContainsKey("fields") || node.ContainsKey("mapValue")) throw Invalid(At(where, path) + "scalar cannot contain child rules");
            return;
        }
        if (node.ContainsKey("fields") == node.ContainsKey("mapValue")) throw Invalid(At(where, path) + "map needs exactly fields or mapValue");
        if (node.ContainsKey("mapValue")) { Node(node["mapValue"], depth + 1, false, ref count, where, path + ".mapValue"); return; }
        var fields = node["fields"] as Dictionary<string, object>;
        if (fields == null || fields.Count == 0) throw Invalid(At(where, path) + "fields must be a nonempty object");
        foreach (var pair in fields)
        {
            string child = ChildPath(path + ".fields", pair.Key);
            bool control = false;
            foreach (char c in pair.Key) if (Char.IsControl(c)) control = true;
            if (pair.Key.Length == 0 || Utf8.GetByteCount(pair.Key) > 128 || control) throw Invalid(At(where, child) + "invalid field name");
            Node(pair.Value, depth + 1, true, ref count, where, child);
        }
    }

    private static int CompareUtf8(string left, string right)
    {
        byte[] a = Utf8.GetBytes(left), b = Utf8.GetBytes(right);
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++)
            if (a[i] != b[i]) return a[i].CompareTo(b[i]);
        return a.Length.CompareTo(b.Length);
    }

    public static string SchemaArray(string manifest)
    {
        var parser = new Parser(manifest);
        var root = Map(parser.Read());
        if (!root.ContainsKey("objectSchemas")) return "[]";
        var schemas = root["objectSchemas"] as List<object>;
        if (schemas == null) throw Invalid("objectSchemas must be an array");
        if (schemas.Count > MaxSchemaItems) throw Limit("objectSchemas has " + schemas.Count.ToString(CultureInfo.InvariantCulture) + " definitions, exceeds limit " + MaxSchemaItems.ToString(CultureInfo.InvariantCulture));
        if (parser.SchemaBytes > MaxSchemaArrayBytes) throw Limit("objectSchemas is " + parser.SchemaBytes.ToString(CultureInfo.InvariantCulture) + " bytes, exceeds limit " + MaxSchemaArrayBytes.ToString(CultureInfo.InvariantCulture) + " (256 KiB)");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (object value in schemas)
        {
            var definition = Map(value);
            if (definition.Count != 3) throw Invalid("schema requires schemaId, schemaVersion and root");
            string id = Text(Get(definition, "schemaId"));
            uint version = Version(Get(definition, "schemaVersion"));
            if (!Identifier.IsMatch(id)) throw Invalid("invalid schemaId");
            if (!seen.Add(id + "\0" + version.ToString(CultureInfo.InvariantCulture))) throw Invalid("duplicate schema id/version");
            int count = 0;
            string where = id + "@" + version.ToString(CultureInfo.InvariantCulture);
            Node(Get(definition, "root"), 0, false, ref count, where, "root");
            if (Text(Get(Map(definition["root"]), "kind")) != "map") throw Invalid(At(where, "root") + "root must be map");
            int size = Utf8.GetByteCount(Json(definition));
            if (size > MaxDefinitionBytes) throw Limit(where + ": canonical definition is " + size.ToString(CultureInfo.InvariantCulture) + " bytes, exceeds limit " + MaxDefinitionBytes.ToString(CultureInfo.InvariantCulture) + " (16 KiB)");
        }
        schemas.Sort(delegate(object left, object right) {
            var a = Map(left); var b = Map(right);
            int result = CompareUtf8(Text(a["schemaId"]), Text(b["schemaId"]));
            return result != 0 ? result : Version(a["schemaVersion"]).CompareTo(Version(b["schemaVersion"]));
        });
        string canonical = Json(schemas);
        int arrayBytes = Utf8.GetByteCount(canonical);
        if (arrayBytes > MaxSchemaArrayBytes) throw Limit("canonical objectSchemas is " + arrayBytes.ToString(CultureInfo.InvariantCulture) + " bytes, exceeds limit " + MaxSchemaArrayBytes.ToString(CultureInfo.InvariantCulture) + " (256 KiB)");
        return canonical;
    }

    public static string StripSchemas(string manifest)
    {
        SchemaArray(manifest);
        var root = Map(new Parser(manifest).Read());
        root.Remove("objectSchemas");
        return Json(root);
    }
    public static string MergeSchemas(string original, string updated)
    {
        SchemaArray(original);
        var before = Map(new Parser(original).Read());
        var after = Map(new Parser(updated).Read());
        if (before.ContainsKey("objectSchemas")) after["objectSchemas"] = before["objectSchemas"];
        return Json(after);
    }
    public static string Registration(string gameId, string schemas)
    {
        if (!Identifier.IsMatch(gameId)) throw Invalid("gameId required");
        string validated = SchemaArray("{\"objectSchemas\":" + schemas + "}");
        return Json(new Dictionary<string, object> { {"formatVersion", 1}, {"gameId", gameId}, {"objectSchemas", new Parser(validated).Read()} });
    }
    public static string Receipt(string gameId, string schemas)
    {
        schemas = SchemaArray("{\"objectSchemas\":" + schemas + "}");
        var entries = (List<object>)new Parser(schemas).Read();
        var items = new List<object>();
        foreach (object value in entries)
        {
            var definition = Map(value);
            items.Add(new Dictionary<string, object> { {"schemaId", definition["schemaId"]}, {"schemaVersion", definition["schemaVersion"]}, {"definitionDigest", Sha(Json(definition))} });
        }
        return Json(new Dictionary<string, object> { {"formatVersion", 1}, {"gameId", gameId}, {"status", "registered"}, {"batchDigest", Sha(schemas)}, {"schemas", items} });
    }
    public static void VerifyReceipt(string response, string expected)
    {
        var actual = Map(new Parser(response).Read());
        var wanted = Map(new Parser(expected).Read());
        foreach (var pair in wanted)
            if (!actual.ContainsKey(pair.Key) || Json(actual[pair.Key]) != Json(pair.Value)) throw new FormatException("schema_contract_unsupported: receipt differs from frozen input");
    }
    public static string Sha(string text)
    {
        using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(Utf8.GetBytes(text))).Replace("-", "").ToLowerInvariant();
    }

    private static string Json(object value)
    {
        if (value == null) return "null";
        if (value is bool) return (bool)value ? "true" : "false";
        if (value is string) return Quote((string)value);
        if (value is Number) return ((Number)value).Text;
        var map = value as Dictionary<string, object>;
        if (map != null)
        {
            var keys = new List<string>(map.Keys);
            keys.Sort(CompareUtf8);
            var parts = new List<string>();
            foreach (string key in keys) parts.Add(Quote(key) + ":" + Json(map[key]));
            return "{" + String.Join(",", parts.ToArray()) + "}";
        }
        var list = value as List<object>;
        if (list != null)
        {
            var parts = new List<string>();
            foreach (object item in list) parts.Add(Json(item));
            return "[" + String.Join(",", parts.ToArray()) + "]";
        }
        if (value is int || value is uint) return Convert.ToString(value, CultureInfo.InvariantCulture);
        throw Invalid("unsupported JSON value");
    }
    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        foreach (char c in value)
        {
            if (c == '"' || c == '\\') { result.Append('\\'); result.Append(c); }
            else if (c < 32) result.Append("\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture));
            else result.Append(c);
        }
        return result.Append('"').ToString();
    }
}

'@

function Initialize-ObjectSchemas {
  if ($script:ObjectSchemasReady) { return }
  Add-Type -TypeDefinition $script:ObjectSchemasSource -Language CSharp
  $script:ObjectSchemasReady = $true
}

function Get-SchemaOperationPath { return (Join-Path $Root "last-schema-operation.json") }

function Write-SchemaAtomicText {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $FullPath = [System.IO.Path]::GetFullPath($Path)
  $Directory = [System.IO.Path]::GetDirectoryName($FullPath)
  if ($Directory) { [System.IO.Directory]::CreateDirectory($Directory) | Out-Null }
  $Temporary = Join-Path $Directory (".schema-write-" + [System.Guid]::NewGuid().ToString("N"))
  $Stream = $null
  try {
    $Stream = [System.IO.File]::Open($Temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $Bytes = $script:Utf8NoBom.GetBytes($Content)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush($true)
    $Stream.Dispose()
    $Stream = $null
    if (Test-Path $FullPath) {
      # PowerShell converts $null to "" for .NET string parameters, and File.Replace throws on an empty backup path; a real null must be passed.
      [System.IO.File]::Replace($Temporary, $FullPath, [NullString]::Value)
    } else {
      [System.IO.File]::Move($Temporary, $FullPath)
    }
  } finally {
    if ($null -ne $Stream) { $Stream.Dispose() }
    Remove-Item -Force $Temporary -ErrorAction SilentlyContinue
  }
}

function Read-SchemaOperation {
  $Path = Get-SchemaOperationPath
  if (!(Test-Path $Path)) { throw "schema_operation_invalid: operation receipt is missing" }
  $Operation = Read-Utf8Text $Path | ConvertFrom-Json
  $ExpectedWorking = [System.IO.Path]::GetFullPath((Join-Path $Root "last-schema-manifest.json"))
  if ($null -eq $Operation -or [int]$Operation.journalVersion -ne 1 -or [string]$Operation.working -ne $ExpectedWorking) {
    throw "schema_operation_invalid: invalid operation receipt"
  }
  return $Operation
}

function Write-SchemaOperation {
  param($Operation)
  Write-SchemaAtomicText (Get-SchemaOperationPath) ($Operation | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-ObjectSchemasManifest {
  param([string]$File)
  Initialize-ObjectSchemas
  [void][BuildaObjectSchemas]::SchemaArray((Read-Utf8Text $File))
}

function Get-ObjectSchemaManifestEngine {
  param([string]$File)
  Initialize-ObjectSchemas
  $Engine = ""
  if (Test-Path $File) {
    try {
      $Raw = Read-Utf8Text $File
      [void][BuildaObjectSchemas]::SchemaArray($Raw)
      $Data = [BuildaObjectSchemas]::StripSchemas($Raw) | ConvertFrom-Json
      if ($Data.engine) { $Engine = [string]$Data.engine }
    } catch {}
  }
  if (!$Engine) { $Engine = Get-EngineValue "." }
  if ($Engine -notin @("godot", "h5", "unity")) { $Engine = "godot" }
  return $Engine
}

function Get-ObjectSchemaManifestTitle {
  param([string]$File)
  Initialize-ObjectSchemas
  if (!(Test-Path $File)) { return "" }
  try {
    $Data = [BuildaObjectSchemas]::StripSchemas((Read-Utf8Text $File)) | ConvertFrom-Json
    if ($Data.title) { return [string]$Data.title }
  } catch {}
  return ""
}

function Get-ObjectSchemaMode {
  param([string]$File)
  $Journal = Get-SchemaOperationPath
  if (Test-Path $Journal) {
    $Operation = Read-SchemaOperation
    if ([string]$Operation.status -ne "failed") { return "active" }
  }
  Initialize-ObjectSchemas
  $Schemas = [BuildaObjectSchemas]::SchemaArray((Read-Utf8Text $File))
  if ($Schemas -eq "[]") { return "inactive" }
  return "active"
}

function Begin-ObjectSchemaOperation {
  param([string]$Action, [string]$Source, [string]$Target, [string]$Zip)
  Initialize-ObjectSchemas
  $Journal = Get-SchemaOperationPath
  $SourcePath = [System.IO.Path]::GetFullPath($Source)
  $ApiBase = $Base.TrimEnd('/')
  if (Test-Path $Journal) {
    $Previous = Read-SchemaOperation
    if ([string]$Previous.status -eq "failed") {
      # Registration failure cannot undo the confirmed game creation.
      if ($Previous.gameId) {
        if ([string]$Previous.apiBase -ne $ApiBase -or ($Target -and $Target -ne [string]$Previous.gameId)) {
          throw "schema_operation_pending: confirmed game identity changed"
        }
        $Target = [string]$Previous.gameId
      }
      Write-SchemaAtomicText (Join-Path $Root "last-schema-failed.json") ($Previous | ConvertTo-Json -Depth 20 -Compress)
    } else {
      if ([string]$Previous.source -ne $SourcePath -or [string]$Previous.apiBase -ne $ApiBase -or [string]$Previous.action -ne $Action) {
        throw "schema_operation_pending: resume original command, manifest and API environment"
      }
      if ($Target -and $Target -ne [string]$Previous.gameId -and $Target -ne [string]$Previous.target) {
        throw "schema_operation_pending: game binding changed"
      }
      return [string]$Previous.working
    }
  }
  $Original = Read-Utf8Text $SourcePath
  $Schemas = [BuildaObjectSchemas]::SchemaArray($Original)
  if (($Action -eq "schemas" -or $Action -eq "update-draft") -and !$Target) {
    throw "schema_invalid: bind this project to a game before schemas upload"
  }
  $Working = [System.IO.Path]::GetFullPath((Join-Path $Root "last-schema-manifest.json"))
  $ZipPath = if ($Zip) { [System.IO.Path]::GetFullPath($Zip) } else { "" }
  $ZipDigest = if ($ZipPath) { Get-BuildaFileSha256 $ZipPath } else { "" }
  $Operation = [ordered]@{
    journalVersion = 1; status = "pending"; action = $Action; source = $SourcePath; apiBase = $ApiBase
    target = $Target; gameId = $Target; authorId = ""; original = $Original
    originalDigest = [BuildaObjectSchemas]::Sha($Original); schemasJson = $Schemas; working = $Working
    zip = $ZipPath; zipDigest = $ZipDigest; prepared = $false; preparedManifest = ""; finalManifest = ""
    gameRequest = ""; gameOperationId = ""; gameAction = ""; gameResult = ""; versionId = ""
    schemaReceipt = ""; studioOperation = $(if ($env:BUILDA_PUBLISH_OPERATION_ID) { $env:BUILDA_PUBLISH_OPERATION_ID } else { "" })
  }
  Write-SchemaOperation $Operation
  Write-SchemaAtomicText $Working $Original
  return $Working
}

function Restore-ObjectSchemaWorkingManifest {
  $Operation = Read-SchemaOperation
  $Content = if ($Operation.finalManifest) { [string]$Operation.finalManifest } elseif ($Operation.preparedManifest) { [string]$Operation.preparedManifest } else { [string]$Operation.original }
  Write-SchemaAtomicText ([string]$Operation.working) $Content
}

function Invoke-SchemaPreservingManifestEdit {
  param([string]$File, [scriptblock]$Action)
  Initialize-ObjectSchemas
  $Original = Read-Utf8Text $File
  Write-SchemaAtomicText $File ([BuildaObjectSchemas]::StripSchemas($Original))
  $Failure = $null
  try { & $Action } catch { $Failure = $_ }
  try {
    $Updated = Read-Utf8Text $File
    Write-SchemaAtomicText $File ([BuildaObjectSchemas]::MergeSchemas($Original, $Updated))
  } catch {
    if ($null -eq $Failure) { throw }
  }
  if ($null -ne $Failure) { throw $Failure }
}

function Set-ObjectSchemaPrepared {
  param([string]$Working)
  $Operation = Read-SchemaOperation
  if ([string]$Operation.action -ne "schemas") {
    Invoke-SchemaPreservingManifestEdit $Working {
      Sync-OnlineCompatibilityRevision $Working
      Invoke-DraftPreflight $Working
      Set-ManifestSdkVersion $Working
    }
  }
  $Operation = Read-SchemaOperation
  $Operation.prepared = $true
  $Operation.preparedManifest = Read-Utf8Text $Working
  Write-SchemaOperation $Operation
}

function Authorize-ObjectSchemaOperation {
  param([string]$AuthorId, [string]$Binding)
  $Operation = Read-SchemaOperation
  if (!$AuthorId -or ($Operation.authorId -and [string]$Operation.authorId -ne $AuthorId)) {
    throw "schema_operation_pending: resume with original author"
  }
  if ($Binding -and $Binding -ne [string]$Operation.gameId) {
    throw "schema_operation_pending: project binding changed"
  }
  $Studio = if ($env:BUILDA_PUBLISH_OPERATION_ID) { $env:BUILDA_PUBLISH_OPERATION_ID } else { "" }
  if ([string]$Operation.studioOperation -ne $Studio) { throw "schema_operation_pending: publish operation context changed" }
  $Operation.authorId = $AuthorId
  Write-SchemaOperation $Operation
}

function Register-SavedObjectSchemas {
  Initialize-ObjectSchemas
  $Operation = Read-SchemaOperation
  if (!$Operation.gameId) { throw "schema_invalid: gameId is not yet known" }
  $Body = [BuildaObjectSchemas]::Registration([string]$Operation.gameId, [string]$Operation.schemasJson)
  $RequestPath = Join-Path $Root "last-schema-request.json"
  $ResponsePath = Join-Path $Root "last-schema-response.json"
  Write-SchemaAtomicText $RequestPath $Body
  Need-Token
  $Response = Invoke-BuildaAuthenticatedRequest -Method "POST" -Uri "$Base/api/v1/agent/object-schemas/register" -BodyBytes $script:Utf8NoBom.GetBytes($Body) -ContentType "application/json" -AllowHttpFailure
  Write-SchemaAtomicText $ResponsePath ([string]$Response.Body)
  if ([int]$Response.Status -ne 200) {
    $Reason = ""
    try { $Reason = [string](([string]$Response.Body | ConvertFrom-Json).reason) } catch {}
    if ([int]$Response.Status -eq 404 -and $Reason -ne "game_not_found") { $Reason = "schema_contract_unsupported" }
    if ([int]$Response.Status -ge 500 -or [int]$Response.Status -eq 429) { $Reason = "schema_registry_unavailable" }
    if (!$Reason) { $Reason = "schema_registry_unavailable" }
    if ($Reason -in @("schema_invalid", "schema_limit_exceeded", "schema_version_conflict", "schema_contract_unsupported", "game_not_found")) {
      $Operation.status = "failed"
      Write-SchemaOperation $Operation
    }
    throw "$Reason`: HTTP $($Response.Status)"
  }
  $Expected = [BuildaObjectSchemas]::Receipt([string]$Operation.gameId, [string]$Operation.schemasJson)
  [BuildaObjectSchemas]::VerifyReceipt([string]$Response.Body, $Expected)
  $Operation.schemaReceipt = $Expected
  Write-SchemaOperation $Operation
  [Console]::Error.WriteLine("schema=registered")
}

function Test-FrozenSchemaZip {
  $Operation = Read-SchemaOperation
  if ($Operation.zip -and (Get-BuildaFileSha256 ([string]$Operation.zip)) -ne [string]$Operation.zipDigest) {
    throw "schema_operation_pending: frozen build zip changed"
  }
}

function Prepare-ObjectSchemaGameRequest {
  param([string]$Working, [string]$Target)
  Test-FrozenSchemaZip
  $Operation = Read-SchemaOperation
  if ($Operation.zip) {
    $PreviousManifest = $env:BUILDA_MANIFEST
    $PreviousStaging = $env:BUILDA_SCHEMA_STAGING
    try {
      Invoke-SchemaPreservingManifestEdit $Working {
        $env:BUILDA_MANIFEST = $Working
        $env:BUILDA_SCHEMA_STAGING = "1"
        & $PSCommandPath upload-build ([string]$Operation.zip)
        if (!$?) { throw "build upload failed" }
      }
    } finally {
      if ($null -eq $PreviousManifest) { Remove-Item Env:BUILDA_MANIFEST -ErrorAction SilentlyContinue } else { $env:BUILDA_MANIFEST = $PreviousManifest }
      if ($null -eq $PreviousStaging) { Remove-Item Env:BUILDA_SCHEMA_STAGING -ErrorAction SilentlyContinue } else { $env:BUILDA_SCHEMA_STAGING = $PreviousStaging }
    }
  }
  $DraftData = [BuildaObjectSchemas]::StripSchemas((Read-Utf8Text $Working)) | ConvertFrom-Json
  $DraftData = Remove-DeprecatedDisplayFields $DraftData
  if ($Target) { $DraftData | Add-Member -NotePropertyName id -NotePropertyValue $Target -Force }
  $Body = $DraftData | ConvertTo-Json -Depth 16 -Compress
  $Payload = Join-Path $Root "last-schema-game-request.json"
  Write-SchemaAtomicText $Payload $Body
  $GameAction = if ($Target) { "update" } else { "create" }
  $GameOperationId = if ($env:BUILDA_PUBLISH_OPERATION_ID) { $env:BUILDA_PUBLISH_OPERATION_ID } else { Get-DraftIdempotencyKey $GameAction $Target $Payload }
  $Operation = Read-SchemaOperation
  $Operation.gameRequest = $Body
  $Operation.gameOperationId = $GameOperationId
  $Operation.gameAction = $GameAction
  $Operation.finalManifest = Read-Utf8Text $Working
  Write-SchemaOperation $Operation
}

function Save-ObjectSchemaGameResult {
  param([string]$ResponseBody)
  $Result = $ResponseBody | ConvertFrom-Json
  Assert-CmdResponseOk $Result "schema publish draft"
  $GameId = [string]$Result.body.game.id
  $VersionId = if ($Result.body.game.versionId) { [string]$Result.body.game.versionId } elseif ($Result.body.game.currentVersionId) { [string]$Result.body.game.currentVersionId } else { [string]$Result.body.game.draftVersionId }
  if (!$GameId -or $GameId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or !$VersionId) {
    throw "schema_operation_pending: missing gameId/versionId; replay the same request"
  }
  $Operation = Read-SchemaOperation
  if ($Operation.target -and [string]$Operation.target -ne $GameId) { throw "schema_operation_pending: game response identity mismatch" }
  $Operation.gameId = $GameId
  $Operation.versionId = $VersionId
  $Operation.gameResult = $ResponseBody
  Write-SchemaOperation $Operation
}

function Bind-ObjectSchemaGameResult {
  $Operation = Read-SchemaOperation
  if (!$Operation.gameResult) { return }
  Write-ProjectGame ([string]$Operation.gameId) (Get-ObjectSchemaManifestTitle ([string]$Operation.working)) ([string]$Operation.versionId)
  Write-Utf8TextNoBom (Join-Path $Root "last-draft.json") ([string]$Operation.gameResult)
  Write-Utf8TextNoBom (Join-Path $Root "last-game-id") ([string]$Operation.gameId)
  Write-Utf8TextNoBom (Join-Path $Root "last-draft-id") ([string]$Operation.gameId)
  Write-Utf8TextNoBom (Join-Path $Root "last-version-id") ([string]$Operation.versionId)
}

function Send-ObjectSchemaGameRequest {
  $Operation = Read-SchemaOperation
  $Endpoint = if ([string]$Operation.gameAction -eq "create") { "game/create" } else { "game/updatedraft" }
  $Headers = if ($env:BUILDA_PUBLISH_OPERATION_ID) { Get-StudioUploadHeaders ([string]$Operation.gameOperationId) } else { @{ "Idempotency-Key" = [string]$Operation.gameOperationId } }
  $Response = Invoke-BuildaAuthenticatedRequest -Method "POST" -Uri (Get-CmdUrl $Endpoint) -Headers $Headers -BodyBytes $script:Utf8NoBom.GetBytes([string]$Operation.gameRequest) -ContentType "application/json"
  if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { throw "schema_operation_pending: empty game response; replay the same request" }
  Write-SchemaAtomicText (Join-Path $Root "last-schema-game-response.json") ([string]$Response.Body)
  Save-ObjectSchemaGameResult ([string]$Response.Body)
  Bind-ObjectSchemaGameResult
}

function Get-SchemaDisplayPath {
  param([string]$Path)
  $Base = [System.IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  if ($Path.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($Base.Length) }
  return $Path
}

function Finish-ObjectSchemaOperation {
  Initialize-ObjectSchemas
  $Operation = Read-SchemaOperation
  if (!$Operation.schemaReceipt -or ([string]$Operation.action -ne "schemas" -and !$Operation.gameResult)) {
    throw "schema_operation_pending: required steps are incomplete"
  }
  $Operation.status = "completed"
  Write-SchemaOperation $Operation
  if ([string]$Operation.action -ne "schemas" -and (Test-Path ([string]$Operation.source))) {
    $Current = Read-Utf8Text ([string]$Operation.source)
    if ([BuildaObjectSchemas]::Sha($Current) -eq [string]$Operation.originalDigest) {
      $WorkingText = Read-Utf8Text ([string]$Operation.working)
      Write-SchemaAtomicText ([string]$Operation.source) $WorkingText
      if ($WorkingText -cne [string]$Operation.original) {
        $Detail = if ($Operation.zip) { " with build and H5 Bundle fields" } else { "" }
        [Console]::Error.WriteLine("Updated $(Get-SchemaDisplayPath ([string]$Operation.source))$Detail.")
      }
    } else {
      [Console]::Error.WriteLine("schema-resume=completed frozen input; newer manifest edits were not published")
    }
  }
  if ($Operation.gameResult) { Write-Output ([string]$Operation.gameResult) } else { Write-Output ([string]$Operation.schemaReceipt) }
  Remove-Item -Force (Get-SchemaOperationPath)
}

function Invoke-ObjectSchemaPublishLocked {
  param([string]$Action, [string]$Source, [string]$Target, [string]$Zip)
  if ($Action -eq "create-draft" -and (Get-ProjectGameId) -and !(Test-Path (Get-SchemaOperationPath))) {
    throw "Project already has a game binding; use update-draft."
  }
  $Working = Begin-ObjectSchemaOperation $Action $Source $Target $Zip
  Restore-ObjectSchemaWorkingManifest
  $Operation = Read-SchemaOperation
  if (!$Operation.prepared) {
    try { Set-ObjectSchemaPrepared $Working } catch {
      $Operation = Read-SchemaOperation
      if (!$Operation.gameRequest -and !$Operation.schemaReceipt) { $Operation.status = "failed"; Write-SchemaOperation $Operation }
      throw
    }
  }
  Need-Token
  $Identity = Get-ActingIdentity
  Authorize-ObjectSchemaOperation ([string]$Identity.userId) (Get-ProjectGameId)
  $Operation = Read-SchemaOperation
  $Target = [string]$Operation.target
  if ($Operation.gameResult) {
    Bind-ObjectSchemaGameResult
  } elseif ($Target -and !$Operation.schemaReceipt) {
    Register-SavedObjectSchemas
  }
  $Operation = Read-SchemaOperation
  if ($Action -ne "schemas" -and !$Operation.gameResult) {
    if (!$Operation.gameRequest) { Prepare-ObjectSchemaGameRequest $Working $Target }
    Send-ObjectSchemaGameRequest
  }
  $Operation = Read-SchemaOperation
  if (!$Operation.schemaReceipt) {
    [Console]::Error.WriteLine("schema=pending gameId=$($Operation.gameId) versionId=$($Operation.versionId)")
    Register-SavedObjectSchemas
  }
  $Operation = Read-SchemaOperation
  if ($Operation.gameOperationId -and !$env:BUILDA_PUBLISH_OPERATION_ID) { Complete-DraftIdempotencyKey ([string]$Operation.gameOperationId) }
  Finish-ObjectSchemaOperation
  [Console]::Error.WriteLine("schema=registered sync=ok")
}

function Invoke-ObjectSchemaPublish {
  param([string]$Action, [string]$Source, [string]$Target = "", [string]$Zip = "")
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($Root)) | Out-Null
  $LockPath = Join-Path $Root "last-schema-operation.lock"
  $Lock = $null
  try {
    try {
      $Lock = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      throw "schema_operation_busy: another publish is running in this project"
    }
    Invoke-ObjectSchemaPublishLocked $Action $Source $Target $Zip
  } finally {
    if ($null -ne $Lock) { $Lock.Dispose() }
  }
}


function Show-Usage {
  Write-Host "builda auth [code|--force]      Ensure agent authorization; --force switches account."
  Write-Host "builda auth status              Show the selected credential store without changing authorization."
  Write-Host "builda auth logout              Remove credentials from the selected store only."
  Write-Host "builda diagnostics private-kv data --role-id <id> --json"
  Write-Host "builda diagnostics private-kv logs --role-id <id> --from <UTC-RFC3339> --to <UTC-RFC3339> --json"
  Write-Host "builda diagnostics player-data data --role-id <id> --json"
  Write-Host "builda diagnostics player-data logs --role-id <id> --from <UTC-RFC3339> --to <UTC-RFC3339> [--limit 50] --json"
  Write-Host "                                Read data and logs scoped to games you own."
  Write-Host "builda whoami                   Show the account used for publishing."
  Write-Host "builda check                    Check local BuildaGame agent environment."
  Write-Host "builda update                   Update this local CLI and installed agent skill."
  Write-Host "builda uninstall [--purge]      Remove project toolchain/registrations; --purge also removes project data and credentials."
  Write-Host "builda engine detect [dir]      Detect project engine; Godot, HTML5 and Unity draft upload are available."
  Write-Host "builda new-manifest             Write builda.publish.json template if missing."
  Write-Host "builda dev --web <dir|zip>      Run a local H5 build (Godot Web / pixi / phaser / Unity WebGL ...) with the Builda mock SDK."
  Write-Host "                               --assets <dir|zip> serves audio/**, res/** as a same-origin fallback (auto-detects ./assets)."
  Write-Host "builda bundle-pack <dir> <zip>  Create a portable H5 Bundle zip with '/' entry paths."
  Write-Host "builda bundle-check <zip>       Check that an H5 Bundle zip is uploadable (per-engine rules)."
  Write-Host "builda sdk init                 Create a minimal Godot project skeleton for SDK testing."
  Write-Host "builda sdk install              Install the Builda SDK (Godot: addons/builda; HTML5: .builda-agent/sdk/web; Unity: Assets/Builda)."
  Write-Host "builda sdk upgrade              Upgrade the project SDK to the latest independently published version."
  Write-Host "builda sdk check                Check installed Builda SDK files in this project."
  Write-Host "builda sdk smoke                Run local mock SDK smoke test when Node.js exists."
  Write-Host "builda cloud-advisories list [--json]"
  Write-Host "                               List active Cloud State design findings for this project."
  Write-Host "builda cloud-advisories inspect --id <id> [--json]"
  Write-Host "builda cloud-advisories match --id <id> --candidates <local-json>"
  Write-Host "builda cloud-advisories ack --id <id> --generation <n> --revision <n>"
  Write-Host "builda cloud-advisories resolve --id <id> --generation <n> --online-release <ref>"
  Write-Host "builda upload-build <zip>       Upload H5 Bundle zip; update manifest."
  Write-Host "builda upload-list [--all] [--json]  List active uploads (current game by default)."
  Write-Host "builda upload-status <session>  Query a resumable build upload using the current grant."
  Write-Host "builda upload-cancel <session>  Cancel an owned resumable build upload."
  Write-Host "builda publish [zip] [manifest]  Upload an optional build and sync this project's draft."
  Write-Host "builda schemas upload [manifest] Register immutable object schemas for the bound game."
  Write-Host "builda gen <audio|music|image|model3d> --prompt <text> -o <file>"
  Write-Host "                               Generate assets with Builda AI (consumes Builda Credits); see builda gen --help."
  Write-Host "builda assets check <zip>       Check assets.zip: audio/** (.mp3|ogg|wav) + res/** (.glb|gltf|bin|ktx2|png|jpg|jpeg|webp|json|bundle|hash|pck; pck must be data-only)."
  Write-Host "builda assets upload <zip>      Upload audio/res assets; update manifest."
  Write-Host "builda create-draft [manifest]  Sync a new Builda pending draft and update the Builda current version."
  Write-Host "builda update-draft [game_id] [manifest]"
  Write-Host "                               Sync a Builda pending draft and update the Builda current version."
  Write-Host "builda status                   Show saved receipts."
  Write-Host "builda sync-project             Re-write project-level agent registrations (.gitignore/stubs/AGENTS.md)."
  Write-Host "builda version                  Show local CLI version."
  Write-Host ""
  Write-Host "Project-scoped toolchain: this CLI lives in <project>/.builda-agent/ and must run"
  Write-Host 'from that project''s root. Credentials default to per-user $HOME/.builda-agent/;'
  Write-Host 'set BUILDA_AUTH_DIR explicitly when an isolated, gitignored credential store is required.'
}

function Need-Token {
  if (Grant-NeedsRefresh) {
    try { Refresh-Grant | Out-Null } catch {}
  }
  if (!(Test-Path $TokenPath)) {
    throw "No agent grant. Run: builda auth"
  }
}

function Get-Token {
  (Read-Utf8Text $TokenPath).Trim()
}

function Get-CmdUrl {
  param([string]$Path)
  # Game_* commands are mandarin cmd-over-HTTP routes mounted at /game/*.
  # Agent REST helpers such as upload/auth live under /api/v1/*.
  "$Base/$Path"
}

function Get-ActingIdentity {
  Need-Token
  $Headers = @{ Authorization = "Bearer $(Get-Token)" }
  $Response = Invoke-BuildaAuthenticatedRequest -Method "GET" -Uri "$Base/api/v1/agent/whoami" -Headers $Headers
  if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { throw "whoami returned an empty response" }
  return ([string]$Response.Body | ConvertFrom-Json)
}

function Write-ActingIdentity {
  $Identity = Get-ActingIdentity
  Write-Host "api-base=$Base"
  Write-Host "acting-as-role-id=$($Identity.roleId)"
  Write-Host "acting-as-user-id=$($Identity.userId)"
  Write-Host "acting-as-username=$($Identity.username)"
  if ($Identity.accountSystem) { Write-Host "acting-as-account-system=$($Identity.accountSystem)" }
}

function Write-PublishPreflight {
  param([string]$Action, [string]$Target)
  Write-ActingIdentity
  Write-Host "action=$Action"
  Write-Host "target-game=$Target"
}

# Get-EngineValue silently detects the engine (lowercase, consistent with backend/protocol): godot first;
# unity = ProjectSettings/ProjectVersion.txt or Assets/+Packages/manifest.json;
# HTML5 = index.html or package.json in the root directory.
# Outputs the on-demand topics beyond the base Skill core that apply to this project's engine; the Agent reads only the matching ones (see the task routing table in SKILL.md).
function Write-SkillTopics {
  param([string]$Engine)
  $TopicBase = "$AgentBase/agent/releases/$Version"
  $Topic = switch ($Engine) { "godot" { "godot" } "h5" { "html5" } "unity" { "unity" } default { "" } }
  Write-Host "skill-topic-publish=$TopicBase/md_agent_publish.md"
  Write-Host "skill-topic-diagnostics=$TopicBase/md_agent_diagnostics.md"
  if ($Topic) { Write-Host "skill-topic-export=$TopicBase/md_agent_$Topic.md" }
  $SdkVersion = ""
  if (Test-Path -LiteralPath $SdkVersionFile) { $SdkVersion = ([string](Get-Content -LiteralPath $SdkVersionFile -Raw)).Trim() }
  if ($Topic -and $SdkVersion) {
    $SdkTopic = Join-Path (Join-Path (Join-Path $ProjectStateDir "sdk-guidance") $SdkVersion) "md_sdk_$Topic.md"
    if (Test-Path -LiteralPath $SdkTopic) { Write-Host "sdk-topic-engine=$($SdkTopic -replace '\\', '/')" }
  }
}

function Get-EngineValue {
  param([string]$Dir = ".")
  if (Test-Path (Join-Path $Dir "project.godot")) { return "godot" }
  if ((Test-Path (Join-Path $Dir "ProjectSettings/ProjectVersion.txt")) -or ((Test-Path (Join-Path $Dir "Assets")) -and (Test-Path (Join-Path $Dir "Packages/manifest.json")))) { return "unity" }
  if ((Test-Path (Join-Path $Dir "index.html")) -or (Test-Path (Join-Path $Dir "package.json"))) { return "h5" }
  return "unknown"
}

# Get-ManifestEngine is the single source for the engine: manifest engine field first, falls back to directory detection if missing, invalid values fall back to godot
function Get-ManifestEngine {
  param([string]$File = $Manifest)
  $V = ""
  if (Test-Path $File) {
    try {
      $Data = Read-Utf8Text $File | ConvertFrom-Json
      if ($Data.engine) { $V = [string]$Data.engine }
    } catch {}
  }
  if (!$V) { $V = Get-EngineValue "." }
  if ($V -notin @("godot", "h5", "unity")) { $V = "godot" }
  return $V
}

function Invoke-EngineDetect {
  param([string]$Dir = ".")
  if (!(Test-Path $Dir -PathType Container)) {
    Write-Host "engine-detect=failed"
    throw "directory not found: $Dir"
  }
  $Engine = Get-EngineValue $Dir
  Write-Host "engine=$Engine"
  switch ($Engine) {
    { $_ -in @("godot", "h5", "unity") } {
      Write-Host "engine-upload-support=available"
      return
    }
    default {
      Write-Host "engine-upload-support=unknown"
      Write-Error "Project engine could not be detected. Do not upload until the user points you at a Godot, HTML5 or Unity project root."
      exit 1
    }
  }
}

function Show-AuthFailureHint {
  Write-Error "auth-required=1"
  if (Test-Path $RefreshPath) {
    Write-Error "Agent grant is missing or expired. Retry the failed command; saved agent authorization refreshes it automatically when still valid."
  } else {
    Write-Error "Agent grant is missing or expired. Run: builda auth"
  }
}

function Get-StubBody {
  @(
    "This project has the project-scoped BuildaGame toolchain installed (publishes Godot Web / HTML5 / Unity WebGL games to Builda). The CLI and the base Skill share one version; the SDK version is pinned per project:"
    ""
    '1. Full guide (read first): `.builda-agent/SKILL.md` at the project root'
    'SDK tasks must read .builda-agent/sdk-guidance/<sdk-version>/SKILL.md; restore missing dependencies per the base Skill, and reread it after upgrading.'
    '2. At the start of every task run `./.builda-agent/builda check` (aligns the toolchain version automatically and reports whether the SDK needs syncing)'
    ""
    "If these files are missing (e.g. right after cloning this repo), reinstall from the project root:"
    ""
    '```bash'
    "curl -fsSL $AgentBase/agent/install.sh | bash"
    '```'
    ''
    'Windows (download to a file; never `iwr | iex`):'
    ''
    '```powershell'
    ('$p = Join-Path $env:TEMP "builda-install.ps1"; iwr ' + $AgentBase + '/agent/install.ps1 -UseBasicParsing -OutFile $p; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $p; Remove-Item -Force $p -ErrorAction SilentlyContinue')
    '```'
  ) -join "`n"
}

function Write-StateGitignore {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $Content = @'
# Managed by BuildaGame: only sensitive or regenerable runtime state is ignored.
# builda/builda.ps1/builda.cmd, SKILL.md, VERSION, game.json and sdk-version are committed.
AGENT_INSTALL.md
publish.env
md_*.md
last-*
sdk/
sdk-guidance/
.sdk-install*
tools/
gen/
token
refresh-token
'@
  Write-Utf8TextNoBom (Join-Path $Root ".gitignore") $Content
}

$AgentsBlockBegin = "<!-- BEGIN builda (auto-managed) -->"
$AgentsBlockEnd = "<!-- END builda -->"
# Legacy marker block from before multi-engine (builda-godot): clear it before writing the new block to avoid two blocks coexisting
$LegacyAgentsBlockBegin = "<!-- BEGIN builda-godot (auto-managed) -->"
$LegacyAgentsBlockEnd = "<!-- END builda-godot -->"

function Remove-AgentsMdBlockByMarkers {
  param([string]$Begin, [string]$End)
  $Path = "AGENTS.md"
  if (!(Test-Path $Path)) { return $false }
  $Content = Read-Utf8Text $Path
  if ($Content -notlike "*$Begin*") { return $false }
  $Pattern = "(?ms)^$([regex]::Escape($Begin))\r?\n.*?^$([regex]::Escape($End))\r?\n?"
  $Content = [regex]::Replace($Content, $Pattern, "")
  Write-Utf8TextNoBom $Path $Content
  return $true
}

function Write-AgentsMdBlock {
  $Path = "AGENTS.md"
  Remove-AgentsMdBlockByMarkers $LegacyAgentsBlockBegin $LegacyAgentsBlockEnd | Out-Null
  $Block = "$AgentsBlockBegin`n## BuildaGame publishing tools (project-scoped)`n`n$(Get-StubBody)`n$AgentsBlockEnd`n"
  if ((Test-Path $Path) -and ((Read-Utf8Text $Path) -like "*$AgentsBlockBegin*")) {
    # When the block content matches the current version, leave the user's file untouched; otherwise (e.g. an old Chinese block) replace the marker block in place;
    # content outside the block and the block's position stay unchanged; do nothing if the end marker is missing.
    $Content = Read-Utf8Text $Path
    $Pattern = "(?ms)^$([regex]::Escape($AgentsBlockBegin))\r?\n.*?^$([regex]::Escape($AgentsBlockEnd))\r?\n?"
    $Match = [regex]::Match($Content, $Pattern)
    if (!$Match.Success) { return }
    if (($Match.Value -replace "`r", "").TrimEnd("`n") -eq $Block.TrimEnd("`n")) { return }
    Write-Utf8TextNoBom $Path ($Content.Substring(0, $Match.Index) + $Block + $Content.Substring($Match.Index + $Match.Length))
    return
  }
  $Prefix = if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { "`n" } else { "" }
  Append-Utf8TextNoBom $Path "$Prefix$Block"
}

function Remove-AgentsMdBlock {
  if (Remove-AgentsMdBlockByMarkers $LegacyAgentsBlockBegin $LegacyAgentsBlockEnd) { Write-Host "removed=AGENTS.md builda-godot block" }
  if (Remove-AgentsMdBlockByMarkers $AgentsBlockBegin $AgentsBlockEnd) { Write-Host "removed=AGENTS.md builda block" }
}

function Write-AgentInstallMd {
  $Content = @"
# BuildaGame Agent Installed (project-scoped)

Runtime (all inside this project):

- CLI: ./.builda-agent/builda
- Skill: ./.builda-agent/SKILL.md
- Env: ./.builda-agent/publish.env
- Installed version: $Version (CLI/publish skill version; SDK is pinned independently)

Credentials stay per-user in `$HOME/.builda-agent/ (token / refresh-token only).

Next for SDK-only tasks:

    ./.builda-agent/builda check
    ./.builda-agent/builda auth
    ./.builda-agent/builda sdk install
    ./.builda-agent/builda sdk check
    ./.builda-agent/builda sdk smoke

Next for upload-draft tasks:

    ./.builda-agent/builda check
    ./.builda-agent/builda auth

Game identity lives in ./.builda-agent/game.json (committed with the project).
"@
  Write-Utf8TextNoBom (Join-Path $Root "AGENT_INSTALL.md") $Content
}

function Remove-LegacyProjectStubs {
  # Legacy stub name from before multi-engine (builda-godot): clean it up on every sync registration to avoid double registration
  foreach ($Path in @(".claude/skills/builda-godot", ".cursor/rules/builda-godot.mdc", ".clinerules/builda-godot.md", ".roo/rules/builda-godot.md", ".windsurf/rules/builda-godot.md")) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue }
  }
}

function Sync-ProjectRegistrations {
  $Registrations = New-Object System.Collections.Generic.List[string]
  Write-StateGitignore
  Write-AgentInstallMd
  Remove-LegacyProjectStubs
  Write-AgentsMdBlock
  $Registrations.Add("AGENTS.md: builda block")

  $ClaudeHome = Join-Path $HOME ".claude"
  if ((Test-Path $ClaudeHome) -or (Test-Path ".claude")) {
    $ClaudeSkillRoot = ".claude/skills/builda"
    New-Item -ItemType Directory -Force -Path $ClaudeSkillRoot | Out-Null
    Write-Utf8TextNoBom (Join-Path $ClaudeSkillRoot "SKILL.md") "---`nname: builda`ndescription: BuildaGame (Builda) game publishing toolchain - integrate the Builda SDK, debug locally with the mock, export Godot Web / Unity WebGL or package HTML5 builds, and upload/update game drafts.`n---`n`n$(Get-StubBody)`n"
    $Registrations.Add("Claude Code: .claude/skills/builda/SKILL.md")
  }

  $CursorHome = Join-Path $HOME ".cursor"
  if ((Test-Path $CursorHome) -or (Test-Path ".cursor")) {
    $CursorRuleRoot = ".cursor/rules"
    New-Item -ItemType Directory -Force -Path $CursorRuleRoot | Out-Null
    $CursorRulePath = Join-Path $CursorRuleRoot "builda.mdc"
    Write-Utf8TextNoBom $CursorRulePath "---`ndescription: BuildaGame skill`nalwaysApply: false`n---`n`n$(Get-StubBody)`n"
    $Registrations.Add("Cursor: .cursor/rules/builda.mdc")
  }

  $ClineGlobalRoot = Join-Path $HOME "Documents\Cline\Rules"
  if ((Test-Path ".clinerules") -or (Test-Path $ClineGlobalRoot)) {
    New-Item -ItemType Directory -Force -Path ".clinerules" | Out-Null
    Write-Utf8TextNoBom ".clinerules/builda.md" "$(Get-StubBody)`n"
    $Registrations.Add("Cline: .clinerules/builda.md")
  }

  if ((Test-Path ".roo") -or (Test-Path ".roo/rules")) {
    $RooRulesRoot = ".roo/rules"
    New-Item -ItemType Directory -Force -Path $RooRulesRoot | Out-Null
    $RooRulePath = Join-Path $RooRulesRoot "builda.md"
    Write-Utf8TextNoBom $RooRulePath "$(Get-StubBody)`n"
    $Registrations.Add("Roo Code: .roo/rules/builda.md")
  }

  if ((Test-Path ".windsurf") -or (Test-Path ".windsurf/rules")) {
    $WindsurfRulesRoot = ".windsurf/rules"
    New-Item -ItemType Directory -Force -Path $WindsurfRulesRoot | Out-Null
    $WindsurfRulePath = Join-Path $WindsurfRulesRoot "builda.md"
    Write-Utf8TextNoBom $WindsurfRulePath "---`ndescription: BuildaGame skill`nalwaysApply: false`n---`n`n$(Get-StubBody)`n"
    $Registrations.Add("Windsurf: .windsurf/rules/builda.md")
  }

  foreach ($Registration in $Registrations) { Write-Host "- $Registration" }
}

function Remove-IfExists {
  param([string]$Path)
  if (Test-Path $Path) {
    Remove-Item -Recurse -Force $Path
    Write-Host "removed=$Path"
  }
}

function Remove-LegacyGlobalRegistrations {
  $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
  Remove-IfExists (Join-Path $CodexHome "skills/builda-godot")
  Remove-IfExists (Join-Path $HOME ".claude/skills/builda-godot")
  Remove-IfExists (Join-Path $HOME ".cursor/rules/builda-godot.mdc")
  Remove-IfExists (Join-Path $HOME "Documents/Cline/Rules/builda-godot.md")
}

function Invoke-LegacyHomeMigrate {
  param([string[]]$OriginalArgs)
  $TargetRoot = Join-Path (Get-Location).Path $ProjectStateDir
  [Console]::Error.WriteLine('layout-migration=required (toolchain moved from $HOME to per-project)')
  if (((Get-Location).Path -eq [System.IO.Path]::GetFullPath($HOME)) -or ([System.IO.Path]::GetFullPath($TargetRoot) -eq $SelfDir)) {
    [Console]::Error.WriteLine("The BuildaGame toolchain is now project-level: cd to the game project root and rerun the command;")
    [Console]::Error.WriteLine('the migration then happens automatically (credentials stay in the credentials directory under $HOME).')
    exit 1
  }
  New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
  foreach ($Name in @("builda.ps1", "SKILL.md", "VERSION", "publish.env")) {
    $Source = Join-Path $SelfDir $Name
    if (Test-Path $Source) { Copy-Item -Force $Source (Join-Path $TargetRoot $Name) }
  }
  Sync-ProjectRegistrations *> $null
  foreach ($Name in @("builda", "builda.ps1", "builda.cmd", "SKILL.md", "VERSION", "AGENT_INSTALL.md", "publish.env", "md_cysj_app.md", "md_cjk_font.md", "md_mobile_perf.md", "last-build.json", "last-assets.json", "last-draft.json", "last-game-id", "last-draft-id", "last-version-id")) {
    $Path = Join-Path $SelfDir $Name
    if (Test-Path $Path) { Remove-Item -Force -Recurse $Path }
  }
  Remove-LegacyGlobalRegistrations
  [Console]::Error.WriteLine("layout-migration=done target=$TargetRoot (credentials kept in $AuthDir)")
  & (Join-Path $TargetRoot "builda.ps1") @OriginalArgs
  exit $LASTEXITCODE
}

function Invoke-LegacyProjectDirMigrate {
  # The binary lives in the legacy-named project dir .builda-godot-agent/: move it into .builda-agent/, rewrite the stub, delete the old dir, and relay the original command
  param([string[]]$OriginalArgs)
  $TargetRoot = Join-Path (Get-Location).Path $ProjectStateDir
  [Console]::Error.WriteLine("layout-migration=required (toolchain dir renamed $LegacyProjectStateDir -> $ProjectStateDir)")
  $Expected = Join-Path (Get-Location).Path $LegacyProjectStateDir
  $Resolved = if (Test-Path $Expected) { (Resolve-Path $Expected).Path } else { "" }
  if ($Resolved -ne $SelfDir) {
    [Console]::Error.WriteLine("run-from=project-root-required")
    [Console]::Error.WriteLine("This CLI is a project-level tool; run the migration from the root of the project it belongs to:")
    [Console]::Error.WriteLine("  cd $(Split-Path -Parent $SelfDir) && ./$LegacyProjectStateDir/builda.ps1 <command>")
    exit 1
  }
  New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
  foreach ($Name in @("builda", "builda.ps1", "builda.cmd", "SKILL.md", "VERSION", "publish.env", "game.json", "sdk-version",
                      "last-build.json", "last-assets.json", "last-draft.json", "last-game-id", "last-draft-id", "last-version-id",
                      "md_cysj_app.md", "md_cjk_font.md", "md_mobile_perf.md", "md_rankboards.md")) {
    $Source = Join-Path $SelfDir $Name
    if (Test-Path $Source) { Copy-Item -Force $Source (Join-Path $TargetRoot $Name) }
  }
  $SdkDir = Join-Path $SelfDir "sdk"
  if (Test-Path $SdkDir) { Copy-Item -Recurse -Force $SdkDir (Join-Path $TargetRoot "sdk") }
  Sync-ProjectRegistrations *> $null
  Remove-Item -Recurse -Force $SelfDir
  [Console]::Error.WriteLine("layout-migration=done target=$TargetRoot")
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TargetRoot "builda.ps1") @OriginalArgs
  exit $LASTEXITCODE
}

function Invoke-LegacyAuthMigrate {
  # Credential dir rename migration: copy without deleting (old CLIs still read the old dir); uninstall --purge removes both generations
  if ($env:BUILDA_AUTH_DIR) { return }
  if (Test-Path $TokenPath) { return }
  $LegacyToken = Join-Path $LegacyAuthDir "token"
  if (!(Test-Path $LegacyToken)) { return }
  New-Item -ItemType Directory -Force -Path $AuthDir | Out-Null
  Copy-Item -Force $LegacyToken $TokenPath
  $LegacyRefresh = Join-Path $LegacyAuthDir "refresh-token"
  if ((Test-Path $LegacyRefresh) -and !(Test-Path $RefreshPath)) { Copy-Item -Force $LegacyRefresh $RefreshPath }
  [Console]::Error.WriteLine("auth-migration=copied credentials $LegacyAuthDir -> $AuthDir (legacy kept for old CLIs)")
}

function Require-ProjectContext {
  param([string[]]$OriginalArgs)
  if (!$env:BUILDA_AUTH_DIR -and (($SelfDir -eq [System.IO.Path]::GetFullPath($UserAuthDir)) -or ($SelfDir -eq [System.IO.Path]::GetFullPath($LegacyAuthDir)))) { Invoke-LegacyHomeMigrate $OriginalArgs }
  if (((Split-Path -Leaf $SelfDir) -eq $LegacyProjectStateDir) -and ($ProjectStateDir -ne $LegacyProjectStateDir)) {
    Invoke-LegacyProjectDirMigrate $OriginalArgs
  }
  $Expected = Join-Path (Get-Location).Path $ProjectStateDir
  $Resolved = if (Test-Path $Expected) { (Resolve-Path $Expected).Path } else { "" }
  if ($Resolved -ne $SelfDir) {
    [Console]::Error.WriteLine("run-from=project-root-required")
    [Console]::Error.WriteLine("This CLI is a project-level tool; run it from the root of the project it belongs to:")
    [Console]::Error.WriteLine("  cd $(Split-Path -Parent $SelfDir) && ./$ProjectStateDir/builda.ps1 <command>")
    exit 1
  }
}

function Invoke-Uninstall {
  param([string[]]$Options)
  $Purge = $false
  if ($Options.Count -gt 0) {
    if ($Options[0] -eq "--purge") {
      $Purge = $true
    } elseif ($Options[0] -eq "-h" -or $Options[0] -eq "--help" -or $Options[0] -eq "help") {
      Write-Host "Usage: builda uninstall [--purge]"
      Write-Host "Default removes the project toolchain and agent registrations, keeps game.json/sdk-version"
      Write-Host 'and the per-user credentials in $HOME/.builda-agent/.'
      Write-Host "--purge also removes the whole $Root directory AND per-user credentials"
      Write-Host "(credentials are shared by every project on this machine)."
      return
    } else {
      throw "unknown uninstall option: $($Options[0])"
    }
  }

  Remove-IfExists ".claude/skills/builda"
  Remove-IfExists ".cursor/rules/builda.mdc"
  Remove-IfExists ".clinerules/builda.md"
  Remove-IfExists ".roo/rules/builda.md"
  Remove-IfExists ".windsurf/rules/builda.md"
  Remove-IfExists ".claude/skills/builda-godot"
  Remove-IfExists ".cursor/rules/builda-godot.mdc"
  Remove-IfExists ".clinerules/builda-godot.md"
  Remove-IfExists ".roo/rules/builda-godot.md"
  Remove-IfExists ".windsurf/rules/builda-godot.md"
  Remove-AgentsMdBlock
  Remove-LegacyGlobalRegistrations

  if ($Purge) {
    Remove-IfExists $TokenPath
    Remove-IfExists $RefreshPath
    Remove-IfExists $Root
    Remove-IfExists $LegacyProjectStateDir
    Remove-IfExists (Join-Path $LegacyAuthDir "token")
    Remove-IfExists (Join-Path $LegacyAuthDir "refresh-token")
    Write-Host "uninstall=ok"
    Write-Host "uninstall-mode=purge (credentials removed for ALL projects on this machine)"
    return
  }

  Remove-IfExists (Join-Path $Root "SKILL.md")
  Remove-IfExists (Join-Path $Root "md_cysj_app.md")
  Remove-IfExists (Join-Path $Root "md_cjk_font.md")
  Remove-IfExists (Join-Path $Root "md_mobile_perf.md")
  Remove-IfExists (Join-Path $Root "builda")
  Remove-IfExists (Join-Path $Root "builda.ps1")
  Remove-IfExists (Join-Path $Root "builda.cmd")
  Remove-IfExists (Join-Path $Root "VERSION")
  Remove-IfExists (Join-Path $Root "AGENT_INSTALL.md")
  Remove-IfExists (Join-Path $Root "publish.env")
  foreach ($Name in @("last-build.json", "last-assets.json", "last-draft.json", "last-game-id", "last-draft-id", "last-version-id")) { Remove-IfExists (Join-Path $Root $Name) }
  Write-Host "uninstall=ok"
  Write-Host "uninstall-mode=keep-project-data (game.json/sdk-version and credentials kept)"
  if (Test-Path $TokenPath) { Write-Host "grant=kept" }
  if (Test-Path $RefreshPath) { Write-Host "agent-authorization=kept" }
}

function Update-BuildaTool {
  param([string]$NewVersion = $Version)
  $ReleaseBase = "$AgentBase/agent/releases/$NewVersion"
  try {
    Install-BuildaWindowsToolchain -Root $Root -ReleaseBase $ReleaseBase -ExpectedVersion $NewVersion
  } catch {
    Write-Host "self-update=failed"
    throw
  }
  Write-Host "self-update=updated"
  $PreviousDisableAutoUpdate = $env:BUILDA_DISABLE_AUTO_UPDATE
  $env:BUILDA_DISABLE_AUTO_UPDATE = "1"
  try {
    & (Join-Path $Root "builda.cmd") sync-project
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("self-update-warning=tool updated but project registration sync failed; rerun .builda-agent\builda.cmd sync-project") }
  } finally {
    if ($null -eq $PreviousDisableAutoUpdate) {
      Remove-Item Env:BUILDA_DISABLE_AUTO_UPDATE -ErrorAction SilentlyContinue
    } else {
      $env:BUILDA_DISABLE_AUTO_UPDATE = $PreviousDisableAutoUpdate
    }
  }
}

function Test-BuildaToolchainCurrent {
  param([string]$ExpectedVersion)
  foreach ($Name in @("builda", "builda.ps1", "builda.cmd", "SKILL.md", "VERSION")) {
    if (!(Test-Path (Join-Path $Root $Name))) { return $false }
  }
  if (!(Test-WindowsPowerShellScriptBom (Join-Path $Root "builda.ps1"))) { return $false }
  if ((Read-Utf8Text (Join-Path $Root "VERSION")).Trim() -ne $ExpectedVersion) { return $false }
  $SkillText = Read-Utf8Text (Join-Path $Root "SKILL.md")
  # The English marker is authoritative; the Chinese marker stays in the Skill's HTML comment for Windows CLI 0.4.101 and earlier to verify, and is accepted here too.
  if ($SkillText -notlike "*BuildaGame agent toolchain version: $ExpectedVersion*" -and $SkillText -notlike "*BuildaGame agent 工具链版本：$ExpectedVersion*") { return $false }
  $CmdText = Read-Utf8Text (Join-Path $Root "builda.cmd")
  return $CmdText -like '*%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe*' -and $CmdText -like '*"%~dp0builda.ps1" %**'
}

# Auto-update only upgrades, never downgrades: upgrade when the remote version is newer; repair at the same version when versions match but local files are incomplete; when the remote is older (CDN briefly
# caching an old version number after a release, or an online rollback) do not auto-downgrade; use builda update to sync explicitly when needed. Treat an unparsable version as no update.
function Test-BuildaVersionNewer {
  param([string]$Candidate, [string]$Current)
  if ($Candidate -notmatch '^\d+\.\d+\.\d+$' -or $Current -notmatch '^\d+\.\d+\.\d+$') { return $false }
  return ([version]$Candidate) -gt ([version]$Current)
}

function Test-BuildaAutoUpdateNeeded {
  param([string]$RemoteVersion)
  if (!$RemoteVersion) { return $false }
  if (Test-BuildaVersionNewer $RemoteVersion $Version) { return $true }
  return ($RemoteVersion -eq $Version) -and !(Test-BuildaToolchainCurrent $RemoteVersion)
}

function Check-SelfUpdate {
  Write-Host "builda-version=$Version"
  Write-Host "toolchain-version=$Version"
  $RemoteFailure = ""
  try { $Remote = Get-BuildaRemoteJson -Uri "$AgentBase/agent/version" } catch { $Remote = $null; $RemoteFailure = $_.Exception.Message }
  $RemoteVersion = if ($Remote) { [string]$Remote.version } else { "" }
  if (!$RemoteVersion) {
    Write-Host "remote-version=unknown"
    Write-Host "self-update=skipped"
    [Console]::Error.WriteLine("self-update-warning=remote unavailable; existing toolchain kept; $RemoteFailure")
  } elseif (Test-BuildaAutoUpdateNeeded $RemoteVersion) {
    Write-Host "remote-version=$RemoteVersion"
    try {
      Update-BuildaTool -NewVersion $RemoteVersion
      Write-Host "builda-agent-skill-updated=1"
      Write-Host "action=rerun-current-command-with-updated-cli-and-reread-skill"
      & (Join-Path $Root "builda.cmd") check
      exit $LASTEXITCODE
    } catch {
      [Console]::Error.WriteLine("self-update-warning=update validation failed; existing toolchain restored")
    }
  } elseif ($RemoteVersion -eq $Version) {
    Write-Host "remote-version=$RemoteVersion"
    Write-Host "self-update=current"
  } else {
    Write-Host "remote-version=$RemoteVersion"
    Write-Host "self-update=skipped (remote $RemoteVersion is not newer than local $Version; run builda update to sync explicitly)"
  }
  if (Test-Path (Join-Path $Root "SKILL.md")) { Write-Host "skill=installed" } else { Write-Host "skill=missing (run: builda update)" }
  if (Test-Path $SdkVersionFile) {
    $SdkVersion = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim()
    Write-Host "sdk-version=$SdkVersion"
    try { Show-SdkGuidance } catch { Write-Host "sdk-guidance=missing-or-incomplete (restore pinned version before SDK tasks)" }
    Write-Host "sdk-sync=independent (SDK version pinned per project; upgrade explicitly: builda sdk upgrade)"
    Write-OnlineStatus
    Write-SdkLatestHint -Pin $SdkVersion
  } elseif ((Test-Path "addons/builda") -or (Test-Path (Join-Path $ProjectStateDir "sdk/web"))) {
    Write-Host "sdk-version=unknown (missing $SdkVersionFile; run: builda sdk install)"
  } else {
    Write-Host "sdk=not-installed"
    Find-SdkRelease
  }
}

function Maybe-SelfUpdate {
  param([string[]]$OriginalArgs)
  $First = if ($OriginalArgs.Count -gt 0) { $OriginalArgs[0] } else { "" }
  if ($First -in @("", "-h", "--help", "help", "check", "update", "uninstall", "version", "--version", "-v")) { return }
  if ($env:BUILDA_DISABLE_AUTO_UPDATE -eq "1") { return }
  $UpdateAttempted = $false
  try {
    $Remote = Get-BuildaRemoteJson -Uri "$AgentBase/agent/version"
    $RemoteVersion = $Remote.version
    if (Test-BuildaAutoUpdateNeeded ([string]$RemoteVersion)) {
      $UpdateAttempted = $true
      [Console]::Error.WriteLine("self-update-required=1")
      Update-BuildaTool -NewVersion $RemoteVersion
      [Console]::Error.WriteLine("builda-agent-skill-updated=1")
      [Console]::Error.WriteLine("action=rerun-current-command-with-updated-cli-and-reread-skill")
      & (Join-Path $Root "builda.cmd") @OriginalArgs
      exit $LASTEXITCODE
    }
  } catch {
    if ($UpdateAttempted) {
      [Console]::Error.WriteLine("self-update-warning=update failed; existing toolchain restored")
    } else {
      [Console]::Error.WriteLine("self-update=skipped warning=remote unavailable; existing toolchain kept")
    }
  }
}

function Get-ProjectGameId {
  Migrate-LegacyProjectFile
  if (!(Test-Path $ProjectFile)) { return "" }
  try {
    $Data = Read-Utf8Text $ProjectFile | ConvertFrom-Json
    if ($Data.gameId) { return [string]$Data.gameId }
  } catch {
    return ""
  }
  return ""
}

function Get-CloudAdvisoryCachePath {
  return (Join-Path $Root "cache/cloud-state-advisories.v1.json")
}

function Write-CloudAdvisoryCache {
  param($Page)
  $Page | Add-Member -NotePropertyName stale -NotePropertyValue $false -Force
  $Page | Add-Member -NotePropertyName fetchedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString("o")) -Force
  $CachePath = Get-CloudAdvisoryCachePath
  $CacheDirectory = Split-Path -Parent $CachePath
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($CacheDirectory)) | Out-Null
  $TempPath = Join-Path $CacheDirectory (".cloud-state-advisories." + [System.Guid]::NewGuid().ToString("N"))
  try {
    Write-Utf8TextNoBom $TempPath ($Page | ConvertTo-Json -Depth 20 -Compress)
    Move-Item -Force $TempPath $CachePath
  } finally {
    Remove-Item -Force $TempPath -ErrorAction SilentlyContinue
  }
  return $Page
}

function Read-StaleCloudAdvisoryCache {
  $CachePath = Get-CloudAdvisoryCachePath
  if (!(Test-Path $CachePath)) { return $null }
  $Page = Read-Utf8Text $CachePath | ConvertFrom-Json
  $Page | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
  return $Page
}

function Write-CloudAdvisoryPage {
  param($Page, [switch]$Json)
  if ($Json) {
    $Page | ConvertTo-Json -Depth 20 -Compress
    return
  }
  $Items = @($Page.items)
  $Stale = ([bool]$Page.stale).ToString().ToLowerInvariant()
  if ($Items.Count -eq 0) {
    Write-Host "cloud-state=pass advisories=0 stale=$Stale"
    return
  }
  Write-Host "cloud-state=attention advisories=$($Items.Count) stale=$Stale"
  foreach ($Item in @($Items | Select-Object -First 5)) {
    $Reasons = (@($Item.reasonCodes) -join ",")
    if (!$Reasons) { $Reasons = "UNKNOWN" }
    Write-Host "advisory=$($Item.advisoryId) severity=$($Item.severity) reason=$Reasons inspect=$($Item.inspectCommand)"
  }
}

function Get-CloudAdvisories {
  param([string[]]$Arguments)
  $Json = $Arguments -contains "--json"
  $NoAuthPrompt = $Arguments -contains "--no-auth-prompt"
  $Cursor = ""
  $Limit = ""
  for ($I = 0; $I -lt $Arguments.Count; $I++) {
    switch ($Arguments[$I]) {
      "--json" {}
      "--no-auth-prompt" {}
      "--cursor" { $I++; if ($I -ge $Arguments.Count) { throw "cursor value required" }; $Cursor = $Arguments[$I] }
      "--limit" { $I++; if ($I -ge $Arguments.Count) { throw "limit value required" }; $Limit = $Arguments[$I] }
      { $_ -in @("-h", "--help", "help") } {
        Write-Host "Usage: builda cloud-advisories list [--json] [--no-auth-prompt] [--cursor <cursor>] [--limit <1..50>]"
        return
      }
      default { throw "Unknown cloud-advisories list option: $($Arguments[$I])" }
    }
  }
  $GameId = Get-ProjectGameId
  if (!$GameId) { throw "cloud-advisories=project-game-id-missing" }
  if (!(Test-Path $TokenPath)) {
    if ($NoAuthPrompt) { Write-Host "cloud-advisories=auth-required"; return }
    Need-Token
  }
  $Uri = "$Base/api/v1/agent/cloud-advisories?gameId=$([Uri]::EscapeDataString($GameId))"
  if ($Cursor) { $Uri += "&cursor=$([Uri]::EscapeDataString($Cursor))" }
  if ($Limit) { $Uri += "&limit=$([Uri]::EscapeDataString($Limit))" }
  $Page = $null
  try {
    $Response = Invoke-BuildaAuthenticatedRequest -Method "GET" -Uri $Uri
    $Page = Write-CloudAdvisoryCache ([string]$Response.Body | ConvertFrom-Json)
  } catch {
    $Page = Read-StaleCloudAdvisoryCache
    if ($null -eq $Page) { throw }
  }
  Write-CloudAdvisoryPage $Page -Json:$Json
}

function Inspect-CloudAdvisory {
  param([string[]]$Arguments)
  $Id = ""
  $Json = $Arguments -contains "--json"
  for ($I = 0; $I -lt $Arguments.Count; $I++) {
    switch ($Arguments[$I]) {
      "--id" { $I++; if ($I -ge $Arguments.Count) { throw "advisory id required" }; $Id = $Arguments[$I] }
      "--json" {}
      { $_ -in @("-h", "--help", "help") } { Write-Host "Usage: builda cloud-advisories inspect --id <id> [--json]"; return }
      default { throw "Unknown cloud-advisories inspect option: $($Arguments[$I])" }
    }
  }
  $GameId = Get-ProjectGameId
  if (!$GameId -or !$Id) { throw "game id and advisory id are required" }
  Need-Token
  $Uri = "$Base/api/v1/agent/cloud-advisories/$([Uri]::EscapeDataString($Id))?gameId=$([Uri]::EscapeDataString($GameId))"
  $Response = Invoke-BuildaAuthenticatedRequest -Method "GET" -Uri $Uri
  $Value = [string]$Response.Body | ConvertFrom-Json
  if ($Json) { $Value | ConvertTo-Json -Depth 20 -Compress } else { $Value | ConvertTo-Json -Depth 20 }
}

function Match-CloudAdvisory {
  param([string[]]$Arguments)
  $Id = ""
  $CandidatesPath = ""
  for ($I = 0; $I -lt $Arguments.Count; $I++) {
    switch ($Arguments[$I]) {
      "--id" { $I++; if ($I -ge $Arguments.Count) { throw "advisory id required" }; $Id = $Arguments[$I] }
      "--candidates" { $I++; if ($I -ge $Arguments.Count) { throw "candidates path required" }; $CandidatesPath = $Arguments[$I] }
      { $_ -in @("-h", "--help", "help") } { Write-Host "Usage: builda cloud-advisories match --id <id> --candidates <local-json>"; return }
      default { throw "Unknown cloud-advisories match option: $($Arguments[$I])" }
    }
  }
  $GameId = Get-ProjectGameId
  if (!$GameId -or !$Id -or !(Test-Path $CandidatesPath)) { throw "game id, advisory id and candidates file are required" }
  Need-Token
  $Candidates = @(Read-Utf8Text $CandidatesPath | ConvertFrom-Json)
  $Body = @{ gameId = $GameId; candidates = $Candidates } | ConvertTo-Json -Depth 10 -Compress
  $Response = Invoke-BuildaAuthenticatedRequest -Method "POST" -Uri "$Base/api/v1/agent/cloud-advisories/$([Uri]::EscapeDataString($Id))/match" -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Body))
  Write-Output ([string]$Response.Body)
}

function Invoke-CloudAdvisoryAction {
  param([string]$Action, [string[]]$Arguments)
  $Values = @{ id = ""; generation = ""; revision = ""; release = "" }
  for ($I = 0; $I -lt $Arguments.Count; $I++) {
    switch ($Arguments[$I]) {
      "--id" { $I++; $Values.id = if ($I -lt $Arguments.Count) { $Arguments[$I] } else { "" } }
      "--generation" { $I++; $Values.generation = if ($I -lt $Arguments.Count) { $Arguments[$I] } else { "" } }
      "--revision" { $I++; $Values.revision = if ($I -lt $Arguments.Count) { $Arguments[$I] } else { "" } }
      "--online-release" { $I++; $Values.release = if ($I -lt $Arguments.Count) { $Arguments[$I] } else { "" } }
      { $_ -in @("-h", "--help", "help") } { Write-Host "Usage: builda cloud-advisories $Action --id <id> --generation <n> [--revision <n>] [--online-release <ref>]"; return }
      default { throw "Unknown cloud-advisories $Action option: $($Arguments[$I])" }
    }
  }
  $GameId = Get-ProjectGameId
  if (!$GameId -or !$Values.id -or !$Values.generation) { throw "game id, advisory id and generation are required" }
  if ($Action -eq "ack" -and !$Values.revision) { throw "notification revision is required for ack" }
  if ($Action -eq "resolve" -and !$Values.release) { throw "online release is required for resolve" }
  Need-Token
  $Payload = @{ gameId = $GameId; generation = [uint64]$Values.generation; clientActionId = [System.Guid]::NewGuid().ToString("N") }
  if ($Values.revision) { $Payload.notificationRevision = [uint64]$Values.revision }
  if ($Values.release) { $Payload.onlineRelease = $Values.release }
  $Body = $Payload | ConvertTo-Json -Compress
  $Response = Invoke-BuildaAuthenticatedRequest -Method "POST" -Uri "$Base/api/v1/agent/cloud-advisories/$([Uri]::EscapeDataString($Values.id))/$Action" -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Body))
  Write-Output ([string]$Response.Body)
}

function Invoke-CloudAdvisories {
  param([string[]]$Arguments)
  $Sub = if ($Arguments.Count -gt 0) { $Arguments[0] } else { "" }
  [string[]]$Tail = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
  switch ($Sub) {
    "list" { Get-CloudAdvisories $Tail }
    "inspect" { Inspect-CloudAdvisory $Tail }
    "match" { Match-CloudAdvisory $Tail }
    "ack" { Invoke-CloudAdvisoryAction "ack" $Tail }
    "resolve" { Invoke-CloudAdvisoryAction "resolve" $Tail }
    { $_ -in @("", "-h", "--help", "help") } { Write-Host "Usage: builda cloud-advisories list|inspect|match|ack|resolve" }
    default { throw "Unknown cloud-advisories command: $Sub" }
  }
}

function Migrate-LegacyProjectFile {
  if (!(Test-Path $ProjectFile) -and (Test-Path $LegacyProjectFile)) {
    $Parent = Split-Path -Parent $ProjectFile
    if ($Parent) {
      New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    Copy-Item -Force $LegacyProjectFile $ProjectFile
  }
}

function Get-ManifestTitle {
  param([string]$Path)
  if (!(Test-Path $Path)) { return "" }
  try {
    $Data = Read-Utf8Text $Path | ConvertFrom-Json
    if ($Data.title) { return [string]$Data.title }
  } catch {
    return ""
  }
  return ""
}

function Write-ProjectGame {
  param([string]$GameId, [string]$Title = "", [string]$VersionId = "")
  if (!$GameId) { return }
  $Parent = Split-Path -Parent $ProjectFile
  if ($Parent) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }
  $Data = @{
    provider = "builda-h5"
    gameId = $GameId
    title = $Title
    lastVersionId = $VersionId
    updatedAt = [int64](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
  }
  $Content = $Data | ConvertTo-Json -Depth 8
  Write-Utf8TextNoBom $ProjectFile $Content
  Write-Host "project-binding=$ProjectFile"
}

function Write-DefaultManifest {
  if (Test-Path $Manifest) {
    Write-Host "$Manifest already exists"
    return
  }
  # engine is written to the manifest based on directory detection; unknown falls back to godot (consistent with the backend's "empty = godot" convention)
  $DetectedEngine = Get-EngineValue "."
  if ($DetectedEngine -notin @("godot", "h5", "unity")) { $DetectedEngine = "godot" }
  $Data = @{
    title = "Your game"
    tagline = "One short sentence about the game."
    desc = "What players should know before playing."
    category = ""
    engine = $DetectedEngine
    tags = @($DetectedEngine)
    orientation = "landscape"
    minChromeMajor = 0
    minIOSMajor = 0
    coverKind = "palette"
    coverPalette = "ember"
    buildPrefix = ""
    buildEntry = "index.html"
    buildSize = 0
    bundleUrl = ""
    bundleMd5 = ""
    bundleVersion = ""
    bundleEntry = "index.html"
    bundleSize = 0
    assetsVersion = ""
    assetsBaseUrl = ""
    assetsManifestUrl = ""
  }
  Write-Utf8TextNoBom $Manifest ($Data | ConvertTo-Json -Depth 8)
  Write-Host 'For in-app purchases, add payPoints only when needed, for example:'
  Write-Host '  "payPoints": [{"payId":"coin_pack_1","payName":"Coins Pack","price":100,"grantBy":"client"}]'
  Write-Host 'Omit payPoints entirely for games without purchases; do not write an empty array.'
  Write-Host 'For leaderboards, omit rankBoards to keep existing boards; use [] only to clear all boards.'
  Write-Host '  "rankBoards": [{"rankId":"high_score","displayName":"High Score","sortType":"desc","cycleType":"forever","minScore":0,"maxScore":9999999999}]'
  Write-Host 'category is required: choose exactly one of the 28 values documented in .builda-agent/SKILL.md; do not invent a value or change its case.'
  Write-Host 'minChromeMajor/minIOSMajor gate which devices may play: fill the LOWEST browser majors the build actually runs on (lower = more players; the 0 placeholders are rejected until you assess and fill them).'
  Write-Host 'Judge by what the build really requires: WASM engine exports (e.g. Godot 4 Web, Unity WebGL) inherit their floor from the compiler toolchain (post-MVP WASM features land around Chrome 75-85 / iOS 15) - check the engine or Emscripten minimum-browser docs, and fall back to the platform baseline 80/15 when you cannot verify lower; plain canvas/DOM H5 with down-leveled JS can go much lower. Do not inflate the values, and do not claim majors the build cannot actually run on.'
  Write-Host "Wrote $Manifest"
}

function Assert-ManifestPayPoints {
  param([string]$File)
  if (!(Test-Path $File)) { return }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  $Names = @($Data.PSObject.Properties.Name)
  if ($Names -notcontains "payPoints") { return }
  $Points = @($Data.payPoints)
  if ($null -eq $Data.payPoints -or $Points.Count -eq 0) {
    throw "payPoints must be omitted for games without in-app purchases; do not send an empty array."
  }
  $Seen = @{}
  for ($I = 0; $I -lt $Points.Count; $I++) {
    $Point = $Points[$I]
    if ($null -eq $Point) { throw "payPoints[$I] must be an object with payId/payName/price." }
    if (@($Point.PSObject.Properties.Name) -contains "grantBy" -and ($Point.grantBy -isnot [string] -or @("", "client", "room") -cnotcontains $Point.grantBy)) {
      throw "payPoints[$I].grantBy must be a string: client or room; omission or empty string means client."
    }
    if ($Point.payId -isnot [string]) { throw "payPoints[$I].payId must be a string matching [A-Za-z0-9_-] with 1-64 bytes." }
    $PayId = $Point.payId
    $PayName = [string]$Point.payName
    if ([string]::IsNullOrWhiteSpace($PayId)) { throw "payPoints[$I].payId is required." }
    if ($PayId -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw "payPoints[$I].payId must match [A-Za-z0-9_-] and be 1-64 bytes." }
    if ($Seen.ContainsKey($PayId)) { throw "payPoints payId duplicated: $PayId" }
    $Seen[$PayId] = $true
    if ([string]::IsNullOrWhiteSpace($PayName)) { throw "payPoints[$I].payName is required." }
    if ($null -eq $Point.price -or $Point.price -isnot [int]) { throw "payPoints[$I].price must be an integer G-coin amount." }
    if ($Point.price -lt 100) { throw "payPoints[$I].price must be at least 100 G-coins." }
  }
}

function Assert-ManifestMetadata {
  param([string]$File)
  if (!(Test-Path $File)) { throw "manifest not found: $File" }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
    $Contract = '{"categories":["action","strategy","rolePlay","plot","adventure","sandBox","survival","pzzle","mystery","leisure","simulation","yangCheng","card","desktop","tower","rogueLike","shoot","speed","sport","fangZhi","music","dress","other","cooperation","moba","asymmetric","party","fight"],"coverKinds":["palette","image"],"engines":["godot","h5","unity"],"limits":{"descriptionBytes":600,"taglineBytes":90,"tags":5,"titleBytes":48},"orientations":["landscape","portrait"]}' | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  if ($null -eq $Data -or $Data -isnot [pscustomobject]) { throw "builda.publish.json must contain a JSON object." }
  $Limits = $Contract.limits
  foreach ($Field in @(
    @("title", $Limits.titleBytes, $true),
    @("tagline", $Limits.taglineBytes, $false),
    @("desc", $Limits.descriptionBytes, $false)
  )) {
    $Name, $MaxBytes, $Required = $Field
    $Value = $Data.$Name
    if ($Value -isnot [string]) { throw "$Name must be a string." }
    if ($Required -and !$Value) { throw "$Name is required." }
    if ([Text.Encoding]::UTF8.GetByteCount($Value) -gt $MaxBytes) { throw "$Name must be at most $MaxBytes UTF-8 bytes." }
  }
  foreach ($Field in @(
    @("category", "categories"),
    @("orientation", "orientations"),
    @("coverKind", "coverKinds")
  )) {
    $Name, $ContractName = $Field
    $Value = $Data.$Name
    $Allowed = @($Contract.$ContractName)
    if ($Value -isnot [string] -or $Allowed -notcontains $Value) {
      throw "$Name must be one of: $($Allowed -join ', '); got '$Value'."
    }
  }
  if ($null -ne $Data.engine -and ($Data.engine -isnot [string] -or ($Data.engine -and @($Contract.engines) -notcontains $Data.engine))) {
    throw "engine must be one of: $(@($Contract.engines) -join ', '); got '$($Data.engine)'."
  }
  $Tags = @($Data.tags)
  if ($null -ne $Data.tags -and $Data.tags -isnot [array]) { throw "tags must be an array of strings." }
  foreach ($Tag in $Tags) { if ($Tag -isnot [string]) { throw "tags must be an array of strings." } }
  if ($Tags.Count -gt $Limits.tags) { throw "tags supports at most $($Limits.tags) entries." }
}

function Normalize-ManifestCategory {
  param([string]$File)
  if (!(Test-Path $File)) { throw "manifest not found: $File" }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
    $Contract = '{"categories":["action","strategy","rolePlay","plot","adventure","sandBox","survival","pzzle","mystery","leisure","simulation","yangCheng","card","desktop","tower","rogueLike","shoot","speed","sport","fangZhi","music","dress","other","cooperation","moba","asymmetric","party","fight"],"coverKinds":["palette","image"],"engines":["godot","h5","unity"],"limits":{"descriptionBytes":600,"taglineBytes":90,"tags":5,"titleBytes":48},"orientations":["landscape","portrait"]}' | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  $Category = $Data.category
  if ($Category -isnot [string] -or !$Category) { return }
  if (@($Contract.categories) -contains $Category) { return }
  $Data.category = "other"
  Write-Utf8TextNoBom $File ($Data | ConvertTo-Json -Depth 16)
  Write-Host "category='$Category' normalized to other"
}

function ConvertTo-ManifestSafeInteger {
  param($Value, [string]$Field)
  $IsIntegral = $Value -is [sbyte] -or $Value -is [byte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
  if (!$IsIntegral) { throw "$Field must be an integer." }
  $Number = [decimal]$Value
  if ([decimal]::Truncate($Number) -ne $Number) { throw "$Field must be an integer." }
  if ($Number -lt -9999999999 -or $Number -gt 9999999999) {
    throw "$Field must be within the supported range [-9999999999, 9999999999]."
  }
  return [int64]$Number
}

function Assert-ManifestRankBoards {
  param([string]$File)
  if (!(Test-Path $File)) { return }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  $Names = @($Data.PSObject.Properties.Name)
  if ($Names -notcontains "rankBoards") { return }
  if ($null -eq $Data.rankBoards) {
    throw "rankBoards must be an array; omit it to keep existing boards or use [] to clear all boards."
  }
  if ($Data.rankBoards -isnot [array]) {
    throw "rankBoards must be an array; omit it to keep existing boards or use [] to clear all boards."
  }
  $Boards = @($Data.rankBoards)
  if ($Boards.Count -gt 100) { throw "rankBoards supports at most 100 boards." }
  $Required = @("rankId", "displayName", "sortType", "cycleType", "minScore", "maxScore")
  $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  for ($I = 0; $I -lt $Boards.Count; $I++) {
    $Board = $Boards[$I]
    if ($null -eq $Board -or $Board -isnot [pscustomobject]) {
      throw "rankBoards[$I] must be an object with all six fields."
    }
    $BoardNames = @($Board.PSObject.Properties.Name)
    foreach ($Field in $Required) {
      if ($BoardNames -notcontains $Field) { throw "rankBoards[$I] missing required field: $Field" }
    }
    if ($Board.rankId -isnot [string]) { throw "rankBoards[$I].rankId must be a string." }
    if ($Board.displayName -isnot [string]) { throw "rankBoards[$I].displayName must be a string." }
    if ($Board.sortType -isnot [string]) { throw "rankBoards[$I].sortType must be a string." }
    if ($Board.cycleType -isnot [string]) { throw "rankBoards[$I].cycleType must be a string." }
    $RankId = $Board.rankId
    $DisplayName = $Board.displayName
    $SortType = $Board.sortType
    $CycleType = $Board.cycleType
    if ($RankId -ne $RankId.Trim() -or $RankId -notmatch '^[A-Za-z0-9_-]{1,64}$') {
      throw "rankBoards[$I].rankId must match [A-Za-z0-9_-] and be 1-64 bytes without surrounding whitespace."
    }
    if (!$Seen.Add($RankId)) { throw "rankBoards rankId duplicated: $RankId" }
    if ([string]::IsNullOrWhiteSpace($DisplayName) -or $DisplayName -ne $DisplayName.Trim() -or [Text.Encoding]::UTF8.GetByteCount($DisplayName) -gt 64) {
      throw "rankBoards[$I].displayName must be non-empty UTF-8 up to 64 bytes without surrounding whitespace."
    }
    if ($SortType -notin @("asc", "desc")) { throw "rankBoards[$I].sortType must be asc or desc." }
    if ($CycleType -notin @("day", "week", "month", "forever")) { throw "rankBoards[$I].cycleType must be day, week, month, or forever." }
    $MinScore = ConvertTo-ManifestSafeInteger $Board.minScore "rankBoards[$I].minScore"
    $MaxScore = ConvertTo-ManifestSafeInteger $Board.maxScore "rankBoards[$I].maxScore"
    if ($MinScore -gt $MaxScore) { throw "rankBoards[$I].minScore must not exceed maxScore." }
  }
}

function Assert-ManifestBrowserMinimums {
  param([string]$File)
  if (!(Test-Path $File)) { throw "manifest not found: $File" }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  $Names = @($Data.PSObject.Properties.Name)
  foreach ($Key in @("minChromeMajor", "minIOSMajor")) {
    $Bad = $true
    if ($Names -contains $Key) {
      try {
        $Value = ConvertTo-ManifestSafeInteger $Data.$Key $Key
        if ($Value -gt 0) { $Bad = $false }
      } catch { }
    }
    if ($Bad) {
      throw "Fill minChromeMajor and minIOSMajor in $File as positive integers: the LOWEST Chrome major and Safari iOS major this build actually runs on. Lower values let more devices play, so do not inflate them; but ground the floor in evidence: WASM engine exports (e.g. Godot 4 Web) inherit it from the compiler toolchain (post-MVP WASM features land around Chrome 75-85 / iOS 15; check engine or Emscripten minimum-browser docs, fall back to the platform baseline 80/15 when unverifiable), while plain canvas/DOM H5 with down-leveled JS can go much lower. Then rerun this command."
    }
  }
}

function Set-ManifestSdkVersion {
  param([string]$File)
  # sdkVersion follows the project's SDK install receipt and goes into the release manifest sdk contract after draft upload; do not maintain it by hand
  if (!(Test-Path $SdkVersionFile)) { return }
  $V = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim()
  if (!$V) { return }
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
    $Data | Add-Member -NotePropertyName sdkVersion -NotePropertyValue $V -Force
    Write-Utf8TextNoBom $File ($Data | ConvertTo-Json -Depth 16)
  } catch {
    Write-Host "sdk-version-inject=skipped ($($_.Exception.Message))"
  }
}

function Invoke-DraftPreflight {
  param([string]$File)
  try {
    Normalize-ManifestCategory $File
    Assert-ManifestMetadata $File
    Assert-ManifestPayPoints $File
    Assert-ManifestRankBoards $File
    Assert-ManifestBrowserMinimums $File
  } catch {
    [Console]::Error.WriteLine("draft-preflight=failed")
    throw
  }
}

function Sync-OnlineCompatibilityRevision {
  param([string]$File)
  $OnlineFile = Join-Path (Get-Location) "builda.online.json"
  if (!(Test-Path $OnlineFile)) { return }
  try {
    $Online = Read-Utf8Text $OnlineFile | ConvertFrom-Json
    $Revision = ConvertTo-ManifestSafeInteger $Online.onlineCompatibilityRevision "onlineCompatibilityRevision"
    if ($Revision -le 0) { throw "onlineCompatibilityRevision must be positive" }
    $ManifestData = Read-Utf8Text $File | ConvertFrom-Json
    $ManifestData | Add-Member -NotePropertyName onlineCompatibilityRevision -NotePropertyValue $Revision -Force
    Write-Utf8TextNoBom $File ($ManifestData | ConvertTo-Json -Depth 16)
  } catch {
    throw "builda.online.json onlineCompatibilityRevision must be a positive integer: $($_.Exception.Message)"
  }
}

function ConvertTo-ManifestRequestBytes {
  param([string]$File)
  try {
    $Data = Read-Utf8Text $File | ConvertFrom-Json
  } catch {
    throw "manifest json invalid: $File"
  }
  $Data = Remove-DeprecatedDisplayFields $Data
  $Json = $Data | ConvertTo-Json -Depth 16
  Write-Output -NoEnumerate ([System.Text.UTF8Encoding]::new($false).GetBytes($Json))
}

# CYSJ listing cover/advert/images are ignored even on first publish.
# Strip those keys from the outgoing draft body so a leftover or hand-written
# field cannot be passed through. Title stays: it is a Builda candidate, not a
# CLI first/subsequent gate (CLI has no PublishTimes).
function Remove-DeprecatedDisplayFields {
  param($Data)
  if ($null -eq $Data) { return $Data }
  $Used = New-Object System.Collections.Generic.List[string]
  if ($Data.PSObject.Properties.Name -contains "objectSchemas") {
    $Data.PSObject.Properties.Remove("objectSchemas")
  }
  if ($Data.PSObject.Properties.Name -contains "coverUrl") {
    $Cover = [string]$Data.coverUrl
    if ($Cover.Trim()) { $Used.Add("coverUrl") | Out-Null }
    $Data.PSObject.Properties.Remove("coverUrl")
  }
  if ($Data.PSObject.Properties.Name -contains "advert") {
    $Used.Add("advert") | Out-Null
    $Data.PSObject.Properties.Remove("advert")
  }
  if ($Data.PSObject.Properties.Name -contains "images") {
    $Used.Add("images") | Out-Null
    $Data.PSObject.Properties.Remove("images")
  }
  if ($Used.Count -gt 0) {
    Write-Host "deprecated: $($Used -join ',') no longer update CYSJ listing cover, intro, or promo images. Edit those in the CYSJ app. This request omitted the fields and did not apply them."
  }
  return $Data
}

function Get-RelativePathCompat {
  param([string]$BasePath, [string]$TargetPath)
  if ([System.IO.Path].GetMethods().Name -contains "GetRelativePath") {
    return [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
  }
  $BaseFull = [System.IO.Path]::GetFullPath($BasePath)
  if (!$BaseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
    $BaseFull += [System.IO.Path]::DirectorySeparatorChar
  }
  $BaseUri = [System.Uri]::new($BaseFull)
  $TargetUri = [System.Uri]::new([System.IO.Path]::GetFullPath($TargetPath))
  $RelativeUri = $BaseUri.MakeRelativeUri($TargetUri)
  return [System.Uri]::UnescapeDataString($RelativeUri.ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-SafeZipEntryName {
  param([string]$Name)
  if (!$Name -or $Name.StartsWith("/") -or $Name.Contains("\") -or $Name.Contains(":") -or ($Name.Split("/") -contains "..")) {
    throw "Unsafe zip path: $Name (ZIP entries must use '/' and stay relative to the bundle root)"
  }
}

function New-BundleZip {
  param([string]$SourceDir, [string]$OutputZip)
  if (!$SourceDir -or !(Test-Path -PathType Container $SourceDir)) { throw "bundle source directory required" }
  if (!$OutputZip) { throw "bundle output zip required" }
  $SourceFull = [System.IO.Path]::GetFullPath((Resolve-Path $SourceDir).Path).TrimEnd('\', '/')
  $OutputFull = [System.IO.Path]::GetFullPath($OutputZip)
  if ($OutputFull.StartsWith($SourceFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "bundle output zip must be outside the source directory"
  }
  $OutputParent = Split-Path -Parent $OutputFull
  if ($OutputParent) { New-Item -ItemType Directory -Force -Path $OutputParent | Out-Null }
  if (Test-Path $OutputFull) { Remove-Item -Force $OutputFull }
  Add-Type -AssemblyName System.IO.Compression
  $FileStream = [System.IO.File]::Open($OutputFull, [System.IO.FileMode]::CreateNew)
  $Archive = New-Object System.IO.Compression.ZipArchive($FileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    Get-ChildItem -LiteralPath $SourceFull -Recurse -File | ForEach-Object {
      $EntryName = (Get-RelativePathCompat $SourceFull $_.FullName).Replace('\', '/')
      Assert-SafeZipEntryName $EntryName
      $Entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
      $Input = [System.IO.File]::OpenRead($_.FullName)
      $Output = $Entry.Open()
      try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose() }
    }
  } finally {
    $Archive.Dispose()
    $FileStream.Dispose()
  }
  Write-Host "bundle-packed=$OutputFull"
}

function Test-SdkCompat {
  $Allowed = @(".gd", ".js", ".ts", ".tsx", ".jsx", ".html", ".cfg", ".tscn")
  # Skip Unity project dirs entirely: the old Builda SDK API only existed in the GDScript/JS era, so Unity projects have no migration
  # burden; Library/Temp hold many files, and scanning only adds time and false positives.
  $Skip = @(".git", ".godot", ".builda-agent", ".builda-godot-agent", "addons", "node_modules", "__pycache__", "build", "dist", "target", "server-pack", "server_pack", "Library", "Temp", "Obj", "Logs", "Assets", "ProjectSettings", "Packages")
  $Errors = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -Path "." -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $Extension = $_.Extension.ToLowerInvariant()
    if ($Allowed -notcontains $Extension) { return }
    $Rel = Get-RelativePathCompat (Get-Location).Path $_.FullName
    foreach ($Part in ($Rel -split '[\\/]')) {
      if ($Skip -contains $Part) { return }
    }
    try { $Lines = Read-Utf8Lines $_.FullName } catch { return }
    $BlockEnd = ""
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
      $Line = [string]$Lines[$Index]
      $LineNo = $Index + 1
      $Code = $Line.TrimStart()
      if ($BlockEnd) {
        $End = $Code.IndexOf($BlockEnd)
        if ($End -lt 0) { continue }
        $Code = $Code.Substring($End + $BlockEnd.Length).TrimStart()
        $BlockEnd = ""
      }
      while ($Code) {
        $BlockStart = if ($Extension -eq ".html" -and $Code.StartsWith("<!--")) { "<!--" } elseif ($Code.StartsWith("/*")) { "/*" } else { "" }
        if (!$BlockStart) { break }
        $BlockEnd = if ($BlockStart -eq "<!--") { "-->" } else { "*/" }
        $End = $Code.IndexOf($BlockEnd, $BlockStart.Length)
        if ($End -lt 0) { $Code = ""; break }
        $Code = $Code.Substring($End + $BlockEnd.Length).TrimStart()
        $BlockEnd = ""
      }
      # comment-only lines are documentation, not executable legacy SDK calls.
      if (!$Code -or $Code.StartsWith("//") -or $Code.StartsWith("#") -or $Code.StartsWith(";")) { continue }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*cloud_get\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old cloud_get(...) with private_kv_get(...)") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*cloud_set\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old cloud_set(...) with private_kv_set(...)") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*cloud_delete\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old cloud_delete(...) with private_kv_remove(...)") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*kv_get\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; kv_get(...) no longer exists; use private_kv_get(...) (value is now bytes: var_to_bytes/bytes_to_var)") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*kv_set\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; kv_set(...) no longer exists; use private_kv_set(key, var_to_bytes(...))") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*kv_remove\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; kv_remove(...) no longer exists; use private_kv_remove(...)") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*kv\s*\.') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; Builda.kv.* no longer exists; use Builda.privateKV.* (value is now Uint8Array)") }
      if ($Extension -eq ".gd" -and $Code -match '\b(?:Builda|builda)\s*\.\s*ready\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old ready(...) with runtime_ready(...)") }
      if ($Extension -in @(".js", ".ts", ".tsx", ".jsx", ".html") -and $Code -match '\b(?:Builda|builda)\s*\.\s*ready\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old Builda.ready(...) with Builda.runtime.ready(...)") }
      if ($Code -match 'Engine\.get_singleton\s*\(\s*["'']Builda["'']\s*\)') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old Engine.get_singleton(""Builda"") usage with the generated BuildaClient autoload") }
      if ($Code -match 'get_node(?:_or_null)?\s*\(\s*["'']/root/Builda["'']\s*\)') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; replace old /root/Builda node usage with /root/BuildaClient") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*init\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; old Builda.init(...) is no longer part of the public SDK; use BuildaClient.builda.runtime_ready() when the game is ready") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*event\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; old event(...) analytics API is not part of the MVP SDK; remove it or keep analytics outside Builda") }
      if ($Code -match '\b(?:Builda|builda)\s*\.\s*track\s*\(') { $Errors.Add("${Rel}:${LineNo}: old Builda SDK API found; old track(...) analytics API is not part of the MVP SDK; remove it or keep analytics outside Builda") }
      if ($Code -match '\bbackend_create\s*\(') { $Errors.Add("${Rel}:${LineNo}: backend_create(...) is not supported; Builda Online toolchain entry: https://ai.builda.game/online/setup.md") }
      if ($Code -match '\bBuilda\s*\.\s*backend\s*\.\s*create\s*\(') { $Errors.Add("${Rel}:${LineNo}: Builda.backend.create() is not supported; Builda Online toolchain entry: https://ai.builda.game/online/setup.md") }
    }
  }
  if ($Errors.Count -gt 0) {
    Write-Host "sdk-compat=failed"
    foreach ($ErrorItem in $Errors) { Write-Error $ErrorItem }
    Write-Error "Current SDK calls are async request/signal based. If the old code expected a direct return value, store the request id and handle the result in BuildaClient.builda.sdk_result; see addons/builda/examples/example.gd and scripts/BuildaClient.gd."
    throw "SDK compatibility check failed"
  }
  Write-Host "sdk-compat=ok"
}

function Assert-CmdResponseOk {
  param([object]$Resp, [string]$Label)
  if ($null -ne $Resp.code -and [int]$Resp.code -ne 0) {
    if ([int]$Resp.code -eq 200455) {
      throw "Publish failed: this account does not have publishing access yet; apply for beta access at $EarlyAccessUrl"
    }
    if ([int]$Resp.code -eq 10008) {
      throw "BUILDA_GAME_QUOTA_EXCEEDED: game quota is full; manage an existing game in the Builda app, then retry the same publish command. upload-recovery=the uploaded Bundle receipt is retained and the same publish command will reuse it."
    }
    $Message = if ($Resp.error) { $Resp.error } elseif ($Resp.msg) { $Resp.msg } else { "" }
    throw "$Label failed: code=$($Resp.code) $Message"
  }
}

function Test-BundleZip {
  param([string]$Zip, [bool]$WebViewCompat = $false, [string]$Engine = "")
  if (!$Zip -or !(Test-Path $Zip)) { throw "zip file required" }
  if (!$Engine) { $Engine = Get-ManifestEngine }
  if ($Engine -notin @("godot", "h5", "unity")) { throw "bundle-check engine must be godot, h5 or unity: $Engine" }
  # Validation rules match the backend buildzip (single source of truth: h5_bundle_spec.md Appendix B)
  $GodotExt = @(".html", ".js", ".wasm", ".pck", ".png", ".jpg", ".jpeg", ".webp", ".svg", ".ico", ".json", ".css", ".txt", ".md")
  $Html5Ext = $GodotExt + @(".mjs", ".woff", ".woff2", ".ttf", ".otf", ".mp3", ".ogg", ".wav", ".m4a", ".mp4", ".webm", ".avif", ".gif", ".bin", ".dat", ".glsl", ".frag", ".vert", ".atlas", ".fnt", ".xml", ".gltf", ".glb", ".ktx2", ".basis")
  $UnityExt = $Html5Ext + @(".unityweb", ".data")
  $AllowedExt = switch ($Engine) { "godot" { $GodotExt } "unity" { $UnityExt } default { $Html5Ext } }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip))
  try {
    if ($Archive.Entries.Count -gt 20000) { throw "Too many ZIP entries: max 20000 (files and directories)" }
    $HasIndex = $false
    $HasJs = $false
    $HasWasm = $false
    $HasPck = $false
    $HasBuildaSdk = $false
    $IndexHtml = ""
    $IndexJs = ""
    $Forbidden = @()
    $BadExt = @()
    $FileCount = 0
    [int64]$TotalUncompressed = 0
    # unity's Build/ four-file set (file names include a build-name variable; only prefix+suffix matching, Appendix B.7)
    $UnityFound = @{ "loader.js" = $false; "framework.js" = $false; "wasm" = $false; "data" = $false }
    foreach ($Entry in $Archive.Entries) {
      Assert-SafeZipEntryName $Entry.FullName
      $Name = $Entry.FullName.TrimStart("./").TrimEnd("/")
      if (!$Name) { continue }
      if (!$Entry.FullName.EndsWith("/")) {
        $FileCount++
        if ($FileCount -gt 10000) { throw "Too many bundle files: max 10000" }
        if ([int64]$Entry.Length -gt 805306368) { throw "Bundle file exceeds 768MiB uncompressed: $Name" }
        $TotalUncompressed += [int64]$Entry.Length
        if ($TotalUncompressed -gt 1073741824) { throw "Bundle exceeds 1GiB total uncompressed size" }
      }
      if ($Name -eq "index.html") {
        $HasIndex = $true
        $Reader = New-Object System.IO.StreamReader($Entry.Open())
        try { $IndexHtml = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
      }
      if ($Name -eq "index.js") {
        $HasJs = $true
        if ($Engine -eq "godot") {
          $Reader = New-Object System.IO.StreamReader($Entry.Open())
          try { $IndexJs = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        }
      }
      if ($Name -eq "index.wasm") { $HasWasm = $true }
      if ($Name -eq "index.pck") { $HasPck = $true }
      if ($Name -eq "addons/builda/web/builda-sdk.js" -or $Name -eq "builda-sdk.js") { $HasBuildaSdk = $true }
      if ($Name -match '(^|/)(project\.godot|export_presets\.cfg|\.env|builda-dev-shell\.html)$' -or
          $Name -match '\.import$' -or $Name -match '\.d\.ts$' -or
          $Name -match '(^|/)(\.godot|\.git|\.svn|\.hg|__MACOSX)(/|$)') {
        $Forbidden += $Name
      }
      if ($Engine -ne "godot") {
        if ($Name -match '\.map$') { $Forbidden += "$Name (sourcemap leaks sources; disable sourcemaps and rebuild)" }
        if ($Name -match '(^|/)node_modules(/|$)') { $Forbidden += "$Name (node_modules must not be zipped)" }
      }
      if ($Engine -eq "unity") {
        if ($Name -match '\.(meta|csproj|sln|unity)$') { $Forbidden += "$Name (Unity project/editor files must not be zipped)" }
        if ($Name -match '(^|/)(Library|Temp|Obj|ProjectSettings)(/|$)') { $Forbidden += "$Name (Unity project directories must not be zipped)" }
        if ($Name -like "Build/*") {
          if ($Name -like "*.loader.js") { $UnityFound["loader.js"] = $true }
          elseif ($Name -like "*.framework.js" -or $Name -like "*.framework.js.unityweb") { $UnityFound["framework.js"] = $true }
          elseif ($Name -like "*.wasm" -or $Name -like "*.wasm.unityweb") { $UnityFound["wasm"] = $true }
          elseif ($Name -like "*.data" -or $Name -like "*.data.unityweb") { $UnityFound["data"] = $true }
        }
      }
      # unity's StreamingAssets/ skips the extension allowlist (AssetBundles conventionally often lack extensions, Appendix B.3);
      # the denylist still applies
      $StreamingExempt = ($Engine -eq "unity") -and ($Name -like "StreamingAssets/*")
      $Ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
      if (!$StreamingExempt -and $AllowedExt -notcontains $Ext) { $BadExt += $Name }
    }
    if (!$HasIndex) { throw "Missing root index.html" }
    if ($Engine -eq "godot") {
      if (!$HasJs) { throw "Missing root index.js" }
      if (!$HasWasm) { throw "Missing root index.wasm" }
      if (!$HasPck) { throw "Missing root index.pck" }
    }
    if ($Engine -eq "unity") {
      $MissingUnity = @($UnityFound.Keys | Where-Object { -not $UnityFound[$_] } | Sort-Object)
      if ($MissingUnity.Count -gt 0) {
        throw "Missing Build/ Unity WebGL artifacts (*.$($MissingUnity -join ', *.'); .unityweb suffix allowed). Re-export with the default Build/ output layout."
      }
    }
    if ($Forbidden.Count -gt 0) { throw "Forbidden project/editor files: $($Forbidden -join ', ')" }
    if ($BadExt.Count -gt 0) { throw "File types not allowed for engine=${Engine}: $($BadExt -join ', ')" }
    if ($HasBuildaSdk) { Write-Host "bundle-sdk=embedded (legacy form; new exports ship without SDK, host injects by manifest)" }
    if ($IndexHtml -notlike "*builda-sdk.js*") {
      if ($Engine -eq "godot") { throw "index.html does not load builda-sdk.js. Ensure Godot Web export head include injects the SDK script." }
      if ($Engine -eq "unity") { throw 'index.html does not load builda-sdk.js. Select the Builda WebGL Template (Player Settings -> Resolution and Presentation; installed by builda sdk install), or add <script src="builda-sdk.js"></script> to your custom template head, then rebuild.' }
      throw 'index.html does not load builda-sdk.js. Add <script src="builda-sdk.js"></script> to the HTML head and rebuild.'
    }
    if ($Engine -eq "godot" -and $WebViewCompat) {
      # Godot only: threads/COI export template variable regex (skipped for h5; false positives uncontrollable)
      if ($IndexHtml -match '\bGODOT_THREADS_ENABLED\s*=\s*true\b' -or $IndexJs -match '\bGODOT_THREADS_ENABLED\s*=\s*true\b') {
        throw "Godot Web export has threads enabled. For WebView compatibility mode, set variant/thread_support=false and re-export."
      }
      if ($IndexHtml -match '\bensureCrossOriginIsolationHeaders\s*:\s*true\b' -or $IndexJs -match '\bensureCrossOriginIsolationHeaders\s*:\s*true\b') {
        throw "Godot Web export requests cross-origin isolation headers. For WebView compatibility mode, set progressive_web_app/ensure_cross_origin_isolation_headers=false and re-export."
      }
    }
    Write-Host "bundle=ok"
    Write-Host "bundle-engine=$Engine"
    if ($Engine -eq "godot") {
      if ($WebViewCompat) { Write-Host "threads-check=webview-compatible" } else { Write-Host "threads-check=default-allowed" }
    }
    # Non-blocking hint: suggest bundle size optimization when the zip exceeds 50MiB; hint only, does not change the server's dynamic upload limit.
    [int64]$ZipBytes = (Get-Item $Zip).Length
    Write-Host "bundle-zip-bytes=$ZipBytes"
    if ($ZipBytes -gt 52428800) {
      $ZipMB = [math]::Floor($ZipBytes / 1048576)
      [Console]::Error.WriteLine("bundle-size-hint=zip is ${ZipMB}MiB (>50MiB). You must evaluate asset splitting / moving assets out of the bundle; read .builda-agent/sdk-guidance/<sdk-version>/md_bundle_size.md (move large assets to res/**, slim down audio/fonts/textures). This hint does not block the upload.")
    }
  } finally {
    $Archive.Dispose()
  }
}

function Parse-DevArguments {
  param([string[]]$DevArgs)
  $Web = ""
  $Port = 18088
  $GameId = "local-game"
  $SafeArea = ""
  $Assets = ""
  for ($i = 0; $i -lt $DevArgs.Count; $i++) {
    $Arg = $DevArgs[$i]
    switch -Regex ($Arg) {
      "^--web$" {
        $i++
        if ($i -ge $DevArgs.Count) { throw "BUILDA_BAD_DEV_ARGS: --web requires a path" }
        $Web = $DevArgs[$i]
      }
      "^--web=(.*)$" { $Web = $Matches[1] }
      "^--port$" {
        $i++
        if ($i -ge $DevArgs.Count) { throw "BUILDA_BAD_DEV_ARGS: --port requires a number" }
        try { $Port = [int]$DevArgs[$i] } catch { throw "BUILDA_BAD_DEV_ARGS: invalid port" }
      }
      "^--port=(.*)$" { try { $Port = [int]$Matches[1] } catch { throw "BUILDA_BAD_DEV_ARGS: invalid port" } }
      "^--game-id$" {
        $i++
        if ($i -ge $DevArgs.Count) { throw "BUILDA_BAD_DEV_ARGS: --game-id requires a value" }
        $GameId = $DevArgs[$i]
      }
      "^--game-id=(.*)$" { $GameId = $Matches[1] }
      "^--safearea$" {
        $i++
        if ($i -ge $DevArgs.Count) { throw "BUILDA_BAD_DEV_ARGS: --safearea requires a value" }
        $SafeArea = $DevArgs[$i]
      }
      "^--safearea=(.*)$" { $SafeArea = $Matches[1] }
      "^--assets$" {
        $i++
        if ($i -ge $DevArgs.Count) { throw "BUILDA_BAD_DEV_ARGS: --assets requires a path" }
        $Assets = $DevArgs[$i]
      }
      "^--assets=(.*)$" { $Assets = $Matches[1] }
      "^-h$|^--help$|^help$|^$" {
        return [pscustomobject]@{ Help = $true }
      }
      default { throw "BUILDA_BAD_DEV_ARGS: unknown argument $Arg" }
    }
  }
  if (!$Web) { throw "BUILDA_BAD_DEV_ARGS: --web is required" }
  if ($Port -lt 0 -or $Port -gt 65535) { throw "BUILDA_BAD_DEV_ARGS: port must be between 0 and 65535" }
  if ($SafeArea -and $SafeArea -notmatch "^\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$") {
    throw "BUILDA_BAD_DEV_ARGS: --safearea must be top,right,bottom,left in CSS px"
  }
  return [pscustomobject]@{ Help = $false; Web = $Web; Port = $Port; GameId = $GameId; SafeArea = $SafeArea; Assets = $Assets }
}

function Test-DevPathWithinRoot {
  param([string]$RootPath, [string]$CandidatePath)
  $RootFull = [System.IO.Path]::GetFullPath($RootPath)
  $CandidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
  $Comparison = [System.StringComparison]::OrdinalIgnoreCase
  if ($CandidateFull.Equals($RootFull, $Comparison)) { return $true }
  $Separator = [string][System.IO.Path]::DirectorySeparatorChar
  $RootPrefix = if ($RootFull.EndsWith($Separator, [System.StringComparison]::Ordinal)) { $RootFull } else { $RootFull + $Separator }
  return $CandidateFull.StartsWith($RootPrefix, $Comparison)
}

function Expand-DevZip {
  param([string]$ZipPath, [string]$Prefix)
  $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    foreach ($Entry in $Zip.Entries) {
      $Name = $Entry.FullName
      if ($Name.StartsWith("/") -or $Name.Contains("\") -or $Name.Contains(":") -or ($Name.Split("/") -contains "..")) {
        throw "Unsafe zip path: $Name"
      }
      if (!$Entry.Name) { continue }
      $Target = Join-Path $TempDir ($Name -replace "/", [System.IO.Path]::DirectorySeparatorChar)
      $Parent = Split-Path -Parent $Target
      if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Target, $true)
    }
  } finally {
    $Zip.Dispose()
  }
  return $TempDir
}

function Invoke-DevServer {
  param([string[]]$DevArgs)
  $Options = Parse-DevArguments $DevArgs
  if ($Options.Help) {
    Write-Host "Usage: builda dev --web <dir|zip> [--assets <dir|zip>] [--port 18088] [--game-id local-game] [--safearea 44,0,34,0]"
    return
  }
  $Web = [string]$Options.Web
  $Port = [int]$Options.Port
  $GameId = [string]$Options.GameId
  $SafeArea = [string]$Options.SafeArea
  $Assets = [string]$Options.Assets
  if (!(Test-Path $Web)) { throw "BUILDA_BAD_DEV_ARGS: web path not found: $Web" }

  $Resolved = Resolve-Path $Web
  $TempDir = $null
  if ((Get-Item $Resolved).PSIsContainer) {
    $WebRoot = $Resolved.Path
  } else {
    if ([System.IO.Path]::GetExtension($Resolved.Path).ToLowerInvariant() -ne ".zip") { throw "dev --web file must be a .zip H5 bundle" }
    $TempDir = Expand-DevZip $Resolved.Path "builda-dev-web-"
    $WebRoot = $TempDir
  }
  if (!(Test-Path (Join-Path $WebRoot "index.html"))) { throw "dev web root missing index.html: $WebRoot" }
  # assets fallback source (audio/**, res/**, same layout as assets.zip): the CP no longer needs to copy assets into the build dir;
  # /audio/... /res/... requests the mock SDK resolves relative to the page dir are served from here when missing from the web root
  if (!$Assets -and ((Test-Path "assets\audio") -or (Test-Path "assets\res"))) { $Assets = "assets" }
  $AssetsRoot = ""
  $AssetsTempDir = $null
  if ($Assets) {
    if (!(Test-Path $Assets)) { throw "BUILDA_BAD_DEV_ARGS: assets path not found: $Assets" }
    $AssetsResolved = Resolve-Path $Assets
    if ((Get-Item $AssetsResolved).PSIsContainer) {
      $AssetsRoot = $AssetsResolved.Path
    } else {
      if ([System.IO.Path]::GetExtension($AssetsResolved.Path).ToLowerInvariant() -ne ".zip") { throw "dev --assets file must be a .zip assets bundle" }
      $AssetsTempDir = Expand-DevZip $AssetsResolved.Path "builda-dev-assets-"
      $AssetsRoot = $AssetsTempDir
    }
  }
  # mock SDK/shell fallback lookup order: web export dir -> Godot addon -> HTML5 toolchain location ($ProjectStateDir/sdk/web/)
  $ProjectSdkJs = @(
    (Join-Path (Get-Location) "addons\builda\web\builda-sdk.js"),
    (Join-Path (Get-Location) (Join-Path $ProjectStateDir "sdk\web\builda-sdk.js"))
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  $SdkPresent = (Test-Path (Join-Path $WebRoot "addons\builda\web\builda-sdk.js")) -or (Test-Path (Join-Path $WebRoot "builda-sdk.js")) -or [bool]$ProjectSdkJs
  # The test shell is installed into the project with the mock SDK and is not in the web export; serve it from the project dir as a fallback
  $ProjectShell = @(
    (Join-Path (Get-Location) "addons\builda\web\builda-dev-shell.html"),
    (Join-Path (Get-Location) (Join-Path $ProjectStateDir "sdk\web\builda-dev-shell.html"))
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  $ShellPresent = (Test-Path (Join-Path $WebRoot "builda-dev-shell.html")) -or [bool]$ProjectShell

  $Listener = $null
  $TcpListener = $null
  $UseHttpListener = [System.Net.HttpListener]::IsSupported -and $env:BUILDA_DEV_FORCE_TCP_LISTENER -ne "1"
  $ActualPort = $Port
  $Bound = $false
  $Candidates = if ($Port -eq 0) { @(0) } else { $Port..([Math]::Min($Port + 20, 65535)) }
  if ($UseHttpListener) {
    try { $Listener = New-Object System.Net.HttpListener } catch { $UseHttpListener = $false }
  }
  if ($UseHttpListener) {
    foreach ($Candidate in $Candidates) {
      $TryPort = if ($Candidate -eq 0) {
        $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
        $Probe.Start()
        $FreePort = $Probe.LocalEndpoint.Port
        $Probe.Stop()
        $FreePort
      } else {
        $Candidate
      }
      $Listener.Prefixes.Clear()
      $Listener.Prefixes.Add("http://127.0.0.1:$TryPort/")
      try {
        $Listener.Start()
        $ActualPort = $TryPort
        $Bound = $true
        break
      } catch {}
    }
    if (!$Bound) {
      try { $Listener.Close() } catch {}
      $Listener = $null
      $UseHttpListener = $false
    }
  }
  if (!$UseHttpListener) {
    foreach ($Candidate in $Candidates) {
      try {
        $TcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Candidate)
        $TcpListener.Start()
        $ActualPort = ([System.Net.IPEndPoint]$TcpListener.LocalEndpoint).Port
        $Bound = $true
        break
      } catch {
        if ($TcpListener) { try { $TcpListener.Stop() } catch {} }
        $TcpListener = $null
      }
    }
  }
  if (!$Bound) { throw "could not bind localhost port $Port" }

  $EntryQuery = "gameId=$([uri]::EscapeDataString($GameId))"
  if ($SafeArea) { $EntryQuery += "&builda_mock_safearea=$([uri]::EscapeDataString($SafeArea))" }
  $EntryPath = "/index.html?$EntryQuery"
  $ShellPath = "/builda-dev-shell.html?$EntryQuery"
  function New-DevResponse([byte[]]$Bytes, [string]$ContentType, [int]$Status = 200, [string]$Location = "") {
    return [pscustomobject]@{ Bytes = $Bytes; ContentType = $ContentType; Status = $Status; Location = $Location }
  }
  function Get-DevContentType([string]$Path) {
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
      ".html" { "text/html; charset=utf-8" }
      ".htm" { "text/html; charset=utf-8" }
      ".css" { "text/css; charset=utf-8" }
      ".js" { "text/javascript; charset=utf-8" }
      ".mjs" { "text/javascript; charset=utf-8" }
      ".map" { "application/json; charset=utf-8" }
      ".wasm" { "application/wasm" }
      ".pck" { "application/octet-stream" }
      ".json" { "application/json; charset=utf-8" }
      ".xml" { "application/xml; charset=utf-8" }
      ".txt" { "text/plain; charset=utf-8" }
      ".svg" { "image/svg+xml" }
      ".ico" { "image/x-icon" }
      ".png" { "image/png" }
      ".jpg" { "image/jpeg" }
      ".jpeg" { "image/jpeg" }
      ".gif" { "image/gif" }
      ".webp" { "image/webp" }
      ".avif" { "image/avif" }
      ".woff" { "font/woff" }
      ".woff2" { "font/woff2" }
      ".ttf" { "font/ttf" }
      ".otf" { "font/otf" }
      ".eot" { "application/vnd.ms-fontobject" }
      ".mp3" { "audio/mpeg" }
      ".ogg" { "audio/ogg" }
      ".wav" { "audio/wav" }
      ".m4a" { "audio/mp4" }
      ".mp4" { "video/mp4" }
      ".webm" { "video/webm" }
      default { "application/octet-stream" }
    }
  }

  function Get-DevResponse([string]$Path) {
    if ($Path -eq "/") {
      $Location = if ($ShellPresent) { $ShellPath } else { $EntryPath }
      return New-DevResponse @() "text/plain; charset=utf-8" 302 $Location
    }
    if ($Path -eq "/health") {
      $InstalledSdkVersion = ""
      if (Test-Path $SdkVersionFile) { $InstalledSdkVersion = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim() }
      $Health = [ordered]@{
        toolchainVersion = $Version
        sdkVersion = $InstalledSdkVersion
        gameId = $GameId
        webRoot = $WebRoot
      } | ConvertTo-Json -Compress
      return New-DevResponse ([System.Text.Encoding]::UTF8.GetBytes($Health)) "application/json; charset=utf-8"
    }
    if ($Path -eq "/builda-dev-shell.html" -and !(Test-Path (Join-Path $WebRoot "builda-dev-shell.html")) -and $ProjectShell) {
      return New-DevResponse ([System.IO.File]::ReadAllBytes($ProjectShell)) "text/html; charset=utf-8"
    }
    if (($Path -eq "/builda-sdk.js" -or $Path -eq "/addons/builda/web/builda-sdk.js") -and $ProjectSdkJs) {
      $InWeb = Join-Path $WebRoot ($Path.TrimStart("/") -replace "/", [System.IO.Path]::DirectorySeparatorChar)
      if (!(Test-Path $InWeb)) {
        return New-DevResponse ([System.IO.File]::ReadAllBytes($ProjectSdkJs)) "text/javascript; charset=utf-8"
      }
    }
    if ($AssetsRoot -and ($Path -match '^/(audio|res)/')) {
      # assets fallback: when the web root lacks the file, serve it from the project assets source (Test-DevPathWithinRoot guards against .. escape)
      $RelAsset = $Path.TrimStart("/") -replace "/", [System.IO.Path]::DirectorySeparatorChar
      $InWeb = Join-Path $WebRoot $RelAsset
      if (!(Test-Path -LiteralPath $InWeb)) {
        try { $AssetTarget = [System.IO.Path]::GetFullPath((Join-Path $AssetsRoot $RelAsset)) } catch { $AssetTarget = "" }
        if ($AssetTarget -and (Test-DevPathWithinRoot $AssetsRoot $AssetTarget) -and (Test-Path -LiteralPath $AssetTarget) -and !(Get-Item -LiteralPath $AssetTarget).PSIsContainer) {
          return New-DevResponse ([System.IO.File]::ReadAllBytes($AssetTarget)) (Get-DevContentType $AssetTarget)
        }
      }
    }
    $Rel = $Path.TrimStart("/")
    if (!$Rel) { $Rel = "index.html" }
    try {
      $Target = [System.IO.Path]::GetFullPath((Join-Path $WebRoot ($Rel -replace "/", [System.IO.Path]::DirectorySeparatorChar)))
    } catch {
      return New-DevResponse ([System.Text.Encoding]::UTF8.GetBytes("not found")) "text/plain; charset=utf-8" 404
    }
    $RootFull = [System.IO.Path]::GetFullPath($WebRoot)
    if (!(Test-DevPathWithinRoot $RootFull $Target) -or !(Test-Path -LiteralPath $Target) -or (Get-Item -LiteralPath $Target).PSIsContainer) {
      return New-DevResponse ([System.Text.Encoding]::UTF8.GetBytes("not found")) "text/plain; charset=utf-8" 404
    }
    return New-DevResponse ([System.IO.File]::ReadAllBytes($Target)) (Get-DevContentType $Target)
  }

  function Send-DevHttpListenerResponse($Context, $Reply, [bool]$HeadOnly) {
    $Context.Response.StatusCode = $Reply.Status
    $Context.Response.ContentType = $Reply.ContentType
    if ($Reply.Location) { $Context.Response.Headers["Location"] = $Reply.Location }
    $Context.Response.Headers["Cross-Origin-Opener-Policy"] = "same-origin"
    $Context.Response.Headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    $Context.Response.Headers["Cross-Origin-Resource-Policy"] = "cross-origin"
    $Context.Response.ContentLength64 = $Reply.Bytes.Length
    if (!$HeadOnly) { $Context.Response.OutputStream.Write($Reply.Bytes, 0, $Reply.Bytes.Length) }
    $Context.Response.Close()
  }

  function Send-DevTcpResponse($Client, $Reply, [bool]$HeadOnly) {
    $Reason = switch ($Reply.Status) { 200 { "OK" } 302 { "Found" } 400 { "Bad Request" } 404 { "Not Found" } default { "Error" } }
    $Headers = "HTTP/1.1 $($Reply.Status) $Reason`r`nContent-Type: $($Reply.ContentType)`r`nContent-Length: $($Reply.Bytes.Length)`r`nConnection: close`r`nCross-Origin-Opener-Policy: same-origin`r`nCross-Origin-Embedder-Policy: require-corp`r`nCross-Origin-Resource-Policy: cross-origin`r`n"
    if ($Reply.Location) { $Headers += "Location: $($Reply.Location)`r`n" }
    $Headers += "`r`n"
    $Stream = $Client.GetStream()
    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Headers)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if (!$HeadOnly) { $Stream.Write($Reply.Bytes, 0, $Reply.Bytes.Length) }
    $Stream.Flush()
  }

  $BaseUrl = "http://127.0.0.1:$ActualPort"
  Write-Host "dev=ok"
  if ($ShellPresent) { Write-Host "dev-url=$BaseUrl$ShellPath" } else { Write-Host "dev-url=$BaseUrl$EntryPath" }
  Write-Host "game-url=$BaseUrl$EntryPath"
  Write-Host "sdk-mode=local-mock"
  if ($ShellPresent) { Write-Host "dev-shell=present" } else { Write-Host "dev-shell=missing" }
  if ($SdkPresent) { Write-Host "dev-sdk=present" } else { Write-Host "dev-sdk=missing" }
  Write-Host "dev-web=$WebRoot"
  if ($AssetsRoot) {
    Write-Host "dev-assets=$AssetsRoot (audio/**, res/** served as a same-origin fallback; keep them out of the build dir and the bundle zip)"
  } else {
    Write-Host "dev-assets=none (games using Builda.audio.* / assets.url(): pass --assets <dir|zip> or keep audio/, res/ under .\assets\ at the project root)"
  }
  if ($UseHttpListener) { Write-Host "dev-listener=http" } else { Write-Host "dev-listener=tcp-fallback" }
  Write-Host "dev-mock-player=local-player (append &builda_mock_player=<id>&builda_mock_name=<name> to the URL to switch identity)"
  if (!$ShellPresent) {
    Write-Host "dev-shell-warning=builda-dev-shell.html not found; run sdk install to get the test shell (orientation/notch/capsule/pay/ad mock)."
  }
  if (!$SdkPresent) {
    Write-Host "dev-warning=builda-sdk.js not found in web root or project; run sdk install (dev server serves the project copy automatically)."
  }

  try {
    if ($UseHttpListener) {
      while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        try {
          $Path = [System.Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)
          $Reply = Get-DevResponse $Path
          Send-DevHttpListenerResponse $Context $Reply ($Context.Request.HttpMethod -eq "HEAD")
        } catch {
          # An exception on a single connection, such as a browser-cancelled request, must not take down the whole dev server.
          [Console]::Error.WriteLine("dev-request-warning=$($_.Exception.GetType().FullName): $($_.Exception.Message)")
          try { $Context.Response.Abort() } catch {}
        }
      }
    } else {
      while ($true) {
        $ClientConnection = $TcpListener.AcceptTcpClient()
        try {
          $ClientConnection.ReceiveTimeout = 5000
          $Stream = $ClientConnection.GetStream()
          $Reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($Stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
          $RequestLine = $Reader.ReadLine()
          while ($null -ne ($HeaderLine = $Reader.ReadLine()) -and $HeaderLine.Length -gt 0) {}
          if ($RequestLine -notmatch '^(GET|HEAD) ([^ ]+) HTTP/1\.[01]$') {
            $Reply = New-DevResponse ([System.Text.Encoding]::UTF8.GetBytes("bad request")) "text/plain; charset=utf-8" 400
            Send-DevTcpResponse $ClientConnection $Reply $false
            continue
          }
          $Method = $Matches[1]
          $RequestTarget = $Matches[2]
          $RawPath = ($RequestTarget -split '\?', 2)[0]
          try { $Path = [System.Uri]::UnescapeDataString($RawPath) } catch { $Path = "/__invalid_path__" }
          $Reply = Get-DevResponse $Path
          Send-DevTcpResponse $ClientConnection $Reply ($Method -eq "HEAD")
        } catch {
          # Browser-cancelled requests, read timeouts, etc. only affect this one connection and must not take down the whole dev server.
          [Console]::Error.WriteLine("dev-request-warning=$($_.Exception.GetType().FullName): $($_.Exception.Message)")
        } finally {
          $ClientConnection.Close()
        }
      }
    }
  } finally {
    if ($Listener) {
      if ($Listener.IsListening) { $Listener.Stop() }
      $Listener.Close()
    }
    if ($TcpListener) { $TcpListener.Stop() }
    if ($TempDir -and (Test-Path $TempDir)) { Remove-Item -Recurse -Force $TempDir }
    if ($AssetsTempDir -and (Test-Path $AssetsTempDir)) { Remove-Item -Recurse -Force $AssetsTempDir }
  }
}

function Test-AssetsZip {
  param([string]$Zip)
  if (!$Zip -or !(Test-Path $Zip)) { throw "assets.zip file required" }
  if ((Get-Item $Zip).Length -gt 500MB) { throw "Assets zip exceeds 500MiB compressed hard limit" }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip))
  try {
    $Count = 0
    $PckCount = 0
    [int64]$Total = 0
    if ($Archive.Entries.Count -gt 20000) { throw "Too many asset ZIP entries: max 20000" }
    foreach ($Entry in $Archive.Entries) {
      $Name = $Entry.FullName.TrimStart("./").TrimEnd("/")
      if (!$Name) { continue }
      if ($Name.EndsWith("/")) { continue }
      if ($Name.StartsWith("/") -or $Name.Contains("\") -or $Name.Contains(":") -or $Name -match '(^|/)\.\.(/|$)') {
        throw "Unsafe asset path: $Name"
      }
      if ($Name -notmatch '^(audio|res)/') { throw "Asset must be under audio/ or res/: $Name" }
      if ($Name -match '^audio/' -and $Name -notmatch '\.(mp3|ogg|wav)$') { throw "Only .mp3/.ogg/.wav assets are allowed under audio/: $Name" }
      if ($Name -match '^res/' -and $Name -notmatch '\.(glb|gltf|bin|ktx2|png|jpg|jpeg|webp|json|bundle|hash|pck)$') {
        throw "Only .glb/.gltf/.bin/.ktx2/.png/.jpg/.jpeg/.webp/.json/.bundle/.hash/.pck assets are allowed under res/: $Name"
      }
      if ($Name -match '\.pck$') { $PckCount += 1 }
      if ($Name -match '(^|/)(\.godot|\.git|\.svn|\.hg|__MACOSX)(/|$)' -or $Name -match '(^|/)\.[^/]+$') {
        throw "Forbidden asset path: $Name"
      }
      if ($Entry.Length -gt 32MB) { throw "Asset file exceeds 32MB: $Name" }
      $Count += 1
      $Total += $Entry.Length
      if ($Count -gt 10000) { throw "Too many asset files: max 10000" }
      if ($Total -gt 1024MB) { throw "Assets zip exceeds 1024MiB uncompressed hard limit" }
    }
    if ($Count -eq 0) { throw "assets.zip is empty" }
    if ((Get-Item $Zip).Length -gt 340MB) { [Console]::Error.WriteLine("assets-policy=server allowance required above default limits") }
    Write-Host "assets=ok"
    Write-Host "assets-files=$Count"
    Write-Host "assets-bytes=$Total"
    if ($PckCount -gt 0) {
      Write-Host "assets-pck=$PckCount"
      Write-Host "assets-pck-note=the server deeply verifies that the pck is data-only: no scripts such as .gd/.gdc/.gdns/.cs, no native libraries or encrypted content, and scenes/resources must not reference scripts; a pck containing scripts is rejected as a whole on upload."
    }
  } finally {
    $Archive.Dispose()
  }
}

function Upload-AssetsZip {
  param([string]$Zip)
  Need-Token
  if (!$Zip -or !(Test-Path $Zip)) { throw "assets.zip file required" }
  Test-AssetsZip $Zip | Out-Null
  $Raw = Invoke-ResumableBuildUpload $Zip "assets"
  $Resp = $Raw | ConvertFrom-Json
  Write-Utf8TextNoBom (Join-Path $Root "last-assets.json") ($Resp | ConvertTo-Json -Depth 8)
  $Resp | ConvertTo-Json -Depth 8
  if ($Resp.assetsVersion) {
    if (!(Test-Path $Manifest)) { Write-DefaultManifest }
    Invoke-SchemaPreservingManifestEdit $Manifest {
      $Data = Read-Utf8Text $Manifest | ConvertFrom-Json
      $Data | Add-Member -NotePropertyName assetsVersion -NotePropertyValue $Resp.assetsVersion -Force
      $Data | Add-Member -NotePropertyName assetsBaseUrl -NotePropertyValue $Resp.assetsBaseUrl -Force
      $Data | Add-Member -NotePropertyName assetsManifestUrl -NotePropertyValue $Resp.assetsManifestUrl -Force
      Write-Utf8TextNoBom $Manifest ($Data | ConvertTo-Json -Depth 8)
    }
    Write-Host "Updated $Manifest with audio assets fields."
  }
}

function Assert-SdkNoPending {
  if (Test-Path (Join-Path $ProjectStateDir ".sdk-install-pending")) { throw "SDK_INSTALL_INCOMPLETE: restore backup named in .sdk-install-pending before continuing" }
}

function Show-SdkGuidance {
  Assert-SdkNoPending
  if (!(Test-Path $SdkVersionFile)) { throw "SDK not installed; run builda sdk install" }
  $V = (Read-Utf8Text $SdkVersionFile).Trim()
  if ($V -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid SDK pin" }
  if ([version]$V -lt [version]'0.5.0' -and !(Test-Path (Join-Path $ProjectStateDir "sdk-guidance/$V/SKILL.md"))) { throw "Legacy SDK guidance missing; run builda sdk install to restore the pinned guidance" } else {
    $Dir = Join-Path $ProjectStateDir "sdk-guidance/$V"
    if (!(Test-Path "$Dir/SKILL.md") -or !(Test-Path "$Dir/VERSION") -or (Read-Utf8Text "$Dir/VERSION").Trim() -ne $V) { throw "SDK guidance missing; run builda sdk install to restore pinned version" }
    Write-Host "sdk-guidance=$([System.IO.Path]::GetFullPath("$Dir/SKILL.md"))"
  }
  Write-Host "sdk-action=READ sdk-guidance before coding; reread after SDK upgrade"
}

function Find-SdkRelease {
  $Channel = switch (Get-EngineValue ".") { "h5" { "web/latest.json" }; "unity" { "unity/latest.json" }; default { "latest.json" } }
  try {
    $M = Get-BuildaRemoteJson -Uri "$AgentBase/game-sdk/$Channel"
    if (!($M.schemaVersion -is [int] -or $M.schemaVersion -is [long]) -or $M.schemaVersion -ne 1 -or [string]$M.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$M.minimumCLIVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Write-Host "sdk-discovery=invalid-metadata"; return }
    if ([version]$Version -lt [version]$M.minimumCLIVersion) { Write-Host "sdk-discovery=incompatible (update CLI)" } else { Write-Host "sdk-discovery=available version=$($M.version) (run: builda sdk install)" }
  } catch { Write-Host "sdk-discovery=unavailable-or-not-published (retry next check)" }
}

# Tell a pinned project whether a newer public SDK exists. Hint only: never upgrades, and a network or metadata failure
# prints sdk-latest=unavailable without failing the check.
function Write-SdkLatestHint {
  param([string]$Pin)
  $Channel = switch (Get-EngineValue ".") { "h5" { "web/latest.json" }; "unity" { "unity/latest.json" }; default { "latest.json" } }
  try {
    $M = Get-BuildaRemoteJson -Uri "$AgentBase/game-sdk/$Channel"
    if (!($M.schemaVersion -is [int] -or $M.schemaVersion -is [long]) -or $M.schemaVersion -ne 1 -or [string]$M.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$M.minimumCLIVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "invalid SDK metadata" }
  } catch { Write-Host "sdk-latest=unavailable (retry next check)"; return }
  $Latest = [string]$M.version
  if ($Pin -match '^[0-9]+\.[0-9]+\.[0-9]+$' -and [version]$Pin -ge [version]$Latest) { Write-Host "sdk-latest=current"; return }
  $Changelog = "$AgentBase/game-sdk/releases/$Latest/CHANGELOG.md"
  if ([version]$Version -lt [version]$M.minimumCLIVersion) {
    Write-Host "sdk-latest=$Latest (pinned $Pin; needs CLI >= $($M.minimumCLIVersion): run builda update first; changelog: $Changelog)"
  } else {
    Write-Host "sdk-latest=$Latest (pinned $Pin; changelog: $Changelog; upgrade: builda sdk upgrade)"
  }
  Write-SdkHeadsUp -Pin $Pin -Latest $Latest -Changelog $Changelog
}

# List the versions after the pin (up to latest) whose changelog section has a "Heads-up", i.e. may need game code changes.
function Write-SdkHeadsUp {
  param([string]$Pin, [string]$Latest, [string]$Changelog)
  try { $Text = Get-BuildaRemoteUtf8Text -Uri $Changelog } catch { Write-Host "sdk-heads-up=unknown (changelog unavailable; read it before upgrading)"; return }
  $PinVersion = if ($Pin -match '^[0-9]+\.[0-9]+\.[0-9]+$') { [version]$Pin } else { $null }
  $Hits = New-Object System.Collections.Generic.List[string]
  $Current = $null
  foreach ($Line in ($Text -split "`r?`n")) {
    if ($Line -match '^##\s+([0-9]+\.[0-9]+\.[0-9]+)\b') {
      $Section = [version]$Matches[1]
      $Current = if ((!$PinVersion -or $Section -gt $PinVersion) -and $Section -le [version]$Latest) { $Matches[1] } else { $null }
    } elseif ($Line.StartsWith('## ')) {
      $Current = $null
    } elseif ($Current -and $Line -match ('^###\s+(Heads-up|' + [char]0x5347 + [char]0x7EA7 + [char]0x987B + [char]0x77E5 + ')') -and !$Hits.Contains($Current)) {
      $Hits.Add($Current)
    }
  }
  if ($Hits.Count -gt 0) { Write-Host "sdk-heads-up=$($Hits -join ',') (these versions may need game code changes: read their `"Heads-up`" sections in the changelog before upgrading)" }
}

function Test-SdkArchiveGuidance {
  param([string]$ArchivePath,[string]$SdkVersion)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Z = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $Names = @{}; [long]$Total=0
    foreach ($E in $Z.Entries) {
      $N=$E.FullName; $Total += $E.Length
      if ($N.StartsWith('/') -or $N.Contains('\') -or $N.Contains(':') -or $N -match '(^|/)\.\.(/|$)' -or $Names.ContainsKey($N) -or (($E.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or $Total -gt 32MB) { throw "Unsafe SDK archive" }
      $Names[$N]=$true
    }
    $Required = @('VERSION','SKILL.md')
    if (!$script:SdkLegacy) { $Required += @('md_bundle_size.md','md_cysj_app.md','md_cjk_font.md','md_godot_i18n.md','md_mobile_perf.md','md_persistent_ids.md','md_rankboards.md','md_unity_webgl.md') }
    foreach ($Name in $Required) {
      $E=$Z.GetEntry("guidance/$Name"); if (!$E -or $E.Length -eq 0) { throw "SDK guidance missing: $Name" }
      $Reader=New-Object System.IO.StreamReader($E.Open())
      try { $Body=$Reader.ReadToEnd() } finally { $Reader.Dispose() }
      if ($Name -eq 'VERSION' -and $Body.Trim() -ne $SdkVersion) { throw "SDK guidance version mismatch" }
      foreach ($Match in [regex]::Matches($Body,'\./(md_[a-z0-9_]+\.md)')) { if (!$Names.ContainsKey('guidance/'+$Match.Groups[1].Value)) { throw "SDK guidance reference missing" } }
    }
  } finally { $Z.Dispose() }
}

function Restore-LegacySdkGuidance {
  param([string]$ArchivePath,[object]$Manifest,[string]$TransactionRoot)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Base = "$AgentBase/agent/releases/$($Manifest.version)/"
  $Files = @{ VERSION = "$($Manifest.version)`n" }
  foreach ($Property in $Manifest.artifacts.PSObject.Properties) {
    $Name=$Property.Name; $A=$Property.Value
    if ($Name -ne 'builda-skill.md' -and $Name -notmatch '^md_[a-z0-9_]+\.md$') { continue }
    if ($A.url -ne "$Base$Name" -or [long]$A.size -gt 4MB -or [long]$A.size -le 0 -or [string]$A.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Legacy guidance metadata invalid" }
    $Local=Join-Path $TransactionRoot $Name
    Invoke-BuildaRawDownload -Uri $A.url -Destination $Local
    if ((Get-Item $Local).Length -ne $A.size -or (Get-BuildaFileSha256 $Local) -ne $A.sha256) { throw "Legacy guidance checksum mismatch" }
    $Target=if ($Name -eq 'builda-skill.md') {'SKILL.md'} else {$Name}
    $Files[$Target]=(Read-Utf8Text $Local).Replace($Base,'./')
  }
  if (!$Files.ContainsKey('SKILL.md')) { throw "Legacy SDK guidance not published" }
  foreach ($Name in @($Files.Keys)) {
    foreach ($Doc in @($Files.Keys)) { if ($Doc.StartsWith('md_')) { $Files[$Name]=$Files[$Name].Replace("$AgentBase/agent/$Doc","./$Doc") } }
  }
  $Z=[System.IO.Compression.ZipFile]::Open($ArchivePath,[System.IO.Compression.ZipArchiveMode]::Update)
  try {
    if (@($Z.Entries | Where-Object {$_.FullName.StartsWith('guidance/')}).Count -gt 0) { throw "Unexpected legacy guidance entries" }
    foreach ($Name in $Files.Keys) {
      $E=$Z.CreateEntry("guidance/$Name")
      $W=New-Object System.IO.StreamWriter($E.Open(),(New-Object System.Text.UTF8Encoding($false)))
      try { $W.Write($Files[$Name]) } finally { $W.Dispose() }
    }
  } finally { $Z.Dispose() }
}

function Get-VerifiedSdkArchive {
  param([string]$ChannelPath, [string]$ArtifactName)
  Assert-SdkNoPending
  $script:SdkLegacy = $false
  $Selected = $script:SdkRequestedVersion
  if (!$Selected -and !$script:SdkUpgrade -and (Test-Path $SdkVersionFile)) { $Selected = (Read-Utf8Text $SdkVersionFile).Trim() }
  if ($Selected) {
    if ($Selected -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "SDK version invalid" }
    if ([version]$Selected -lt [version]'0.5.0') {
      $script:SdkLegacy = $true
      $Manifest = Get-BuildaRemoteJson -Uri "$AgentBase/agent/releases/$Selected/manifest.json"
      $Manifest | Add-Member -Force -NotePropertyName schemaVersion -NotePropertyValue 1
      $Manifest | Add-Member -Force -NotePropertyName minimumCLIVersion -NotePropertyValue "0.0.0"
    } else { $Manifest = Get-BuildaRemoteJson -Uri "$AgentBase/game-sdk/releases/$Selected/manifest.json" }
    if ($Manifest.version -ne $Selected) { throw "SDK manifest version mismatch" }
    $Artifact = $Manifest.artifacts.$ArtifactName
    $Meta = [pscustomobject]@{ schemaVersion=$Manifest.schemaVersion; version=$Manifest.version; minimumCLIVersion=$Manifest.minimumCLIVersion; url=$Artifact.url; sha256=$Artifact.sha256; size=$Artifact.size }
  } else { $Meta = Get-BuildaRemoteJson -Uri "$AgentBase/game-sdk/$ChannelPath" }
  if (!($Meta.PSObject.Properties.Name -contains 'schemaVersion') -or !($Meta.schemaVersion -is [int] -or $Meta.schemaVersion -is [long]) -or $Meta.schemaVersion -ne 1) { throw "Unsupported SDK metadata schema." }
  if (!($Meta.PSObject.Properties.Name -contains 'minimumCLIVersion') -or [string]$Meta.minimumCLIVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [version]$Version -lt [version]$Meta.minimumCLIVersion) {
    throw "SDK requires a newer CLI or has unsupported metadata; update CLI first."
  }
  $ExpectedUrl = "$AgentBase/game-sdk/releases/$($Meta.version)/$ArtifactName"
  if ($script:SdkLegacy) { $ExpectedUrl = "$AgentBase/agent/releases/$($Meta.version)/$ArtifactName" }
  if ([string]$Meta.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$Meta.url -ne $ExpectedUrl -or
      [string]$Meta.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [int64]$Meta.size -le 0) {
    throw "SDK metadata invalid."
  }
  $TransactionRoot = Join-Path ([System.IO.Path]::GetFullPath($ProjectStateDir)) (".sdk-install-" + [System.Guid]::NewGuid().ToString("N"))
  $Archive = Join-Path $TransactionRoot $ArtifactName
  try {
    [System.IO.Directory]::CreateDirectory($TransactionRoot) | Out-Null
    Invoke-BuildaRawDownload -Uri $Meta.url -Destination $Archive
    $ActualSize = (Get-Item -LiteralPath $Archive).Length
    $ActualSha = Get-BuildaFileSha256 $Archive
    if ($ActualSize -ne [int64]$Meta.size -or $ActualSha -ne ([string]$Meta.sha256).ToLowerInvariant()) {
      throw "SDK archive size or SHA-256 mismatch."
    }
    if ($script:SdkLegacy) { Restore-LegacySdkGuidance $Archive $Manifest $TransactionRoot }
    Test-SdkArchiveGuidance $Archive ([string]$Meta.version)
    $script:SdkSelectedVersion = [string]$Meta.version
    return @{ Root = $TransactionRoot; Archive = $Archive; Version = [string]$Meta.version }
  } catch {
    Remove-Item -Recurse -Force -LiteralPath $TransactionRoot -ErrorAction SilentlyContinue
    throw
  }
}

function Install-SdkDirectorySet {
  param([string]$TransactionRoot, [object[]]$Mappings)
  $Guidance = Join-Path $TransactionRoot "stage/guidance"
  $WebGuidance = Join-Path $TransactionRoot "stage/web/guidance"
  if (Test-Path $WebGuidance) { Move-Item -LiteralPath $WebGuidance -Destination $Guidance }
  if (!(Test-Path "$Guidance/SKILL.md")) { throw "SDK guidance staging missing" }
  $Mappings = @(@{Source=$Guidance;Destination=(Join-Path $ProjectStateDir "sdk-guidance/$script:SdkSelectedVersion")}) + $Mappings
  Write-Utf8TextNoBom (Join-Path $ProjectStateDir ".sdk-install-pending") $TransactionRoot
  $BackupRoot = Join-Path $TransactionRoot "backup"
  [System.IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
  $Records = New-Object System.Collections.Generic.List[object]
  $OldReceipt = if (Test-Path $SdkVersionFile) { Read-Utf8Text $SdkVersionFile } else { $null }
  try {
    for ($Index = 0; $Index -lt $Mappings.Count; $Index++) {
      $Source = [System.IO.Path]::GetFullPath([string]$Mappings[$Index].Source)
      $Destination = [System.IO.Path]::GetFullPath([string]$Mappings[$Index].Destination)
      if (!(Test-Path -LiteralPath $Source -PathType Container)) { throw "SDK staged directory missing: $Source" }
      $Parent = [System.IO.Path]::GetDirectoryName($Destination)
      if ($Parent) { [System.IO.Directory]::CreateDirectory($Parent) | Out-Null }
      $Backup = Join-Path $BackupRoot ([string]$Index)
      $Record = @{ Destination = $Destination; Backup = $Backup; HadOld = (Test-Path -LiteralPath $Destination); Installed = $false }
      $Records.Add($Record)
      Write-Utf8TextNoBom (Join-Path $TransactionRoot "journal.json") ($Records.ToArray() | ConvertTo-Json -Depth 5)
      if ($Record.HadOld) { [System.IO.Directory]::Move($Destination, $Backup) }
      [System.IO.Directory]::Move($Source, $Destination)
      $Record.Installed = $true
    }
    Write-Utf8TextNoBom (Join-Path $TransactionRoot "sdk-version") "$script:SdkSelectedVersion$([Environment]::NewLine)"
    Move-Item -Force -LiteralPath (Join-Path $TransactionRoot "sdk-version") -Destination $SdkVersionFile
    Remove-Item -Force -LiteralPath (Join-Path $ProjectStateDir ".sdk-install-pending")
  } catch {
    $Failure = $_
    $RollbackErrors = New-Object System.Collections.Generic.List[string]
    for ($Index = $Records.Count - 1; $Index -ge 0; $Index--) {
      $Record = $Records[$Index]
      try {
        if ($Record.Installed -and (Test-Path -LiteralPath $Record.Destination)) {
          Remove-Item -Recurse -Force -LiteralPath $Record.Destination
        }
        if ($Record.HadOld -and (Test-Path -LiteralPath $Record.Backup)) {
          [System.IO.Directory]::Move($Record.Backup, $Record.Destination)
        }
      } catch {
        $RollbackErrors.Add($_.Exception.Message)
      }
    }
    try {
      if ($null -ne $OldReceipt) { Write-Utf8TextNoBom $SdkVersionFile $OldReceipt } elseif (Test-Path $SdkVersionFile) { Remove-Item -Force $SdkVersionFile }
      if ($RollbackErrors.Count -eq 0) { Remove-Item -Force -LiteralPath (Join-Path $ProjectStateDir ".sdk-install-pending") }
    } catch { $RollbackErrors.Add($_.Exception.Message) }
    if ($RollbackErrors.Count -gt 0) {
      throw "BUILDA_SDK_ROLLBACK_FAILED: backup=$BackupRoot errors=$([string]::Join('; ', $RollbackErrors)) original=$($Failure.Exception.Message)"
    }
    throw $Failure
  }
}

# ---- Builda Online: multiplayer deliverables are installed under the same SDK version lock ----
# The base manifest's online block pins the immutable Online manifest of the same version; this CLI only verifies and installs the multiplayer Skill
# and its bundled deploy client .builda-online\bin, then hands installation of the client SDK / Room SDK / Mock to
# `builda-online install`, which likewise reads only that version's immutable snapshot.
$OnlineStateDir = ".builda-online"
$OnlineSkillDir = ".agents/skills/builda-online"

function Test-OnlineWanted {
  return [bool]($script:SdkWithOnline -or (Test-Path (Join-Path $OnlineStateDir "installation.json")) -or (Test-Path "builda.online.json"))
}

function Set-SdkInstallOptions {
  param([string[]]$Arguments, [bool]$AllowVersion)
  $script:SdkRequestedVersion = ""
  $i = 0
  while ($i -lt $Arguments.Count) {
    $Argument = [string]$Arguments[$i]
    if ($Argument -eq "--with-online") { $script:SdkWithOnline = $true }
    elseif ($Argument -eq "--room-language") { $i++; $script:SdkOnlineRoomLanguage = if ($i -lt $Arguments.Count) { [string]$Arguments[$i] } else { "" } }
    elseif ($Argument.StartsWith("--room-language=")) { $script:SdkOnlineRoomLanguage = $Argument.Substring("--room-language=".Length) }
    elseif ($Argument.StartsWith("-")) { throw "Unknown sdk option: $Argument. Usage: builda sdk install [version] [--with-online] [--room-language typescript|rust] | upgrade [--with-online] [--room-language typescript|rust]" }
    elseif ($AllowVersion) { $script:SdkRequestedVersion = $Argument }
    else { throw "sdk upgrade does not take a version" }
    $i++
  }
  if ($script:SdkOnlineRoomLanguage -and $script:SdkOnlineRoomLanguage -notin @("typescript", "rust")) { throw "--room-language must be typescript or rust" }
}

function Test-OnlineSkillArchive {
  param([string]$ArchivePath, [string]$SkillVersion)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Z = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $Names = @{}; [long]$Total = 0
    foreach ($E in $Z.Entries) {
      $N = $E.FullName; $Total += $E.Length
      if ($N.StartsWith('/') -or $N.Contains('\') -or $N.Contains(':') -or $N -match '(^|/)\.\.(/|$)' -or $Names.ContainsKey($N) -or (($E.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or $Total -gt 64MB) { throw "unsafe online skill archive" }
      if (!$N.StartsWith("builda-online/")) { throw "online skill archive must contain a single builda-online/ root" }
      $Names[$N] = $true
    }
    foreach ($Required in @('VERSION', 'SKILL.md', 'bin/builda-online.py', 'bin/builda_online/install.py', 'references/resource-limits.md')) {
      if (!$Names.ContainsKey("builda-online/$Required")) { throw "online skill archive is missing $Required" }
    }
    $Reader = New-Object System.IO.StreamReader($Z.GetEntry("builda-online/VERSION").Open())
    try { $Body = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
    if ($Body.Trim() -ne $SkillVersion) { throw "online skill VERSION does not match the manifest" }
  } finally { $Z.Dispose() }
}

function Set-ProjectDirectoryFromStage {
  param([string]$Source, [string]$Relative)
  $ProjectRoot = [System.IO.Path]::GetFullPath((Get-Location).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  $Target = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Relative)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  if (!$Target.StartsWith($ProjectRoot + [System.IO.Path]::DirectorySeparatorChar)) { throw "refusing to write outside the project" }
  $Parent = Split-Path -Parent $Target
  [System.IO.Directory]::CreateDirectory($Parent) | Out-Null
  $Staged = Join-Path $Parent ("." + (Split-Path -Leaf $Target) + ".builda-new")
  if (Test-Path -LiteralPath $Staged) { Remove-Item -Recurse -Force -LiteralPath $Staged }
  Copy-Item -Recurse -LiteralPath $Source -Destination $Staged
  if (Test-Path -LiteralPath $Target) { Remove-Item -Recurse -Force -LiteralPath $Target }
  Move-Item -LiteralPath $Staged -Destination $Target
}

function Install-OnlineDelivery {
  param([string]$SdkVersion)
  if (!(Test-OnlineWanted)) { return }
  if ([version]$SdkVersion -lt [version]'0.5.0') {
    Write-Host "online=unsupported (Builda SDK $SdkVersion predates Builda Online delivery; run: builda sdk upgrade)"
    return
  }
  $Release = "$AgentBase/online/releases/$SdkVersion/"
  $ManifestUrl = ""
  $Tmp = Join-Path ([System.IO.Path]::GetFullPath($ProjectStateDir)) (".online-install-" + [System.Guid]::NewGuid().ToString("N"))
  try {
    $Manifest = Get-BuildaRemoteJson -Uri "$AgentBase/game-sdk/releases/$SdkVersion/manifest.json"
    if (!($Manifest.PSObject.Properties.Name -contains 'online') -or $null -eq $Manifest.online) {
      Write-Host "online=not-included (Builda SDK $SdkVersion ships no Builda Online delivery)"
      return
    }
    $Online = $Manifest.online
    if ([string]$Online.manifestUrl -ne "$($Release)manifest.json") { throw "base manifest online.manifestUrl is not the same-version snapshot" }
    [System.IO.Directory]::CreateDirectory($Tmp) | Out-Null
    $OnlineManifestPath = Join-Path $Tmp "online-manifest.json"
    Invoke-BuildaRawDownload -Uri ([string]$Online.manifestUrl) -Destination $OnlineManifestPath
    if ((Get-BuildaFileSha256 $OnlineManifestPath) -ne ([string]$Online.sha256).ToLowerInvariant() -or (Get-Item -LiteralPath $OnlineManifestPath).Length -ne [int64]$Online.size) {
      throw "online manifest digest does not match the base manifest"
    }
    $OnlineManifest = Read-Utf8Text $OnlineManifestPath | ConvertFrom-Json
    if ([string]$OnlineManifest.release_id -ne $SdkVersion -or [string]$OnlineManifest.public_base_url -ne "$AgentBase/online") { throw "online manifest release_id/public_base_url mismatch" }
    $Skill = $OnlineManifest.skill
    if ($null -eq $Skill -or !([string]$Skill.download_url).StartsWith($Release) -or [string]$Skill.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "online manifest skill entry invalid" }
    $Archive = Join-Path $Tmp "builda-online-skill.zip"
    Invoke-BuildaRawDownload -Uri ([string]$Skill.download_url) -Destination $Archive
    if ((Get-BuildaFileSha256 $Archive) -ne ([string]$Skill.sha256).ToLowerInvariant()) { throw "online skill archive SHA-256 mismatch" }
    Test-OnlineSkillArchive $Archive ([string]$Skill.version)
    $Stage = Join-Path $Tmp "stage"
    Expand-Archive -Force -Path $Archive -DestinationPath $Stage
    Set-ProjectDirectoryFromStage (Join-Path $Stage "builda-online") $OnlineSkillDir
    Set-ProjectDirectoryFromStage (Join-Path $Stage "builda-online/bin") (Join-Path $OnlineStateDir "bin")
    $ManifestUrl = [string]$Online.manifestUrl
    Write-Host "online-release=$SdkVersion"
    Write-Host "online-skill-version=$($Skill.version)"
    Write-Host "online-skill=$OnlineSkillDir/SKILL.md"
    Write-Host "online-deploy-client=$OnlineStateDir/bin/builda-online.cmd"
  } catch {
    [Console]::Error.WriteLine("online-install=failed (Builda Online skill could not be installed for SDK ${SdkVersion}: $($_.Exception.Message); base SDK is installed)")
    return
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $Tmp -ErrorAction SilentlyContinue
  }
  $InstallerArgs = @("install", "--project-root", ".", "--manifest-url", $ManifestUrl)
  if ($script:SdkOnlineRoomLanguage) { $InstallerArgs += @("--room-language", $script:SdkOnlineRoomLanguage) }
  $Installer = Join-Path $OnlineStateDir "bin/builda-online.cmd"
  $PreviousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = (& $Installer @InstallerArgs 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $InstallerExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorAction
  }
  if ($Output) { Write-Host $Output }
  if ($InstallerExit -eq 0) {
    Write-Host "online-install=ok"
    return
  }
  if ($Output -like "*Cannot determine the Room language*") {
    [Console]::Error.WriteLine("online-install=needs-room-language (ask the user which Room language to use, then run: .\$OnlineStateDir\bin\builda-online.cmd install --room-language typescript|rust)")
  } elseif ($Output -like "*Cannot determine the client engine*") {
    [Console]::Error.WriteLine("online-install=needs-client-sdk (run: .\$OnlineStateDir\bin\builda-online.cmd install --client-sdk godot|h5|cocos|unity)")
  } else {
    [Console]::Error.WriteLine("online-install=failed (fix the error above, then run: .\$OnlineStateDir\bin\builda-online.cmd install)")
  }
}

# Reports how the multiplayer deliverables relate to the SDK version lock; does not install or go online. Newer releases: Write-SdkLatestHint.
function Write-OnlineStatus {
  $Record = Join-Path $OnlineStateDir "installation.json"
  if (!(Test-Path $Record)) { return }
  $Pin = ""
  if (Test-Path $SdkVersionFile) { $Pin = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim() }
  $ReleaseId = ""
  try {
    $Installation = Read-Utf8Text $Record | ConvertFrom-Json
    if ($Installation.PSObject.Properties.Name -contains 'releaseId') { $ReleaseId = [string]$Installation.releaseId }
  } catch { $ReleaseId = "" }
  $PinLabel = if ($Pin) { $Pin } else { "<sdk-version>" }
  if (!$ReleaseId) {
    Write-Host "online-release=unrecorded"
    Write-Host "online-status=unrecorded (run: .\$OnlineStateDir\bin\builda-online.cmd install --manifest-url $AgentBase/online/releases/$PinLabel/manifest.json)"
  } elseif ($Pin -and $ReleaseId -eq $Pin) {
    Write-Host "online-release=$ReleaseId"
    Write-Host "online-status=matches-pin (local multiplayer release equals the SDK pin; not a latest-version check)"
  } else {
    $PinShown = if ($Pin) { $Pin } else { "unknown" }
    Write-Host "online-release=$ReleaseId"
    Write-Host "online-status=outdated (Builda SDK pin is $PinShown; run: .\$OnlineStateDir\bin\builda-online.cmd upgrade)"
  }
}

function Install-WebSdk {
  # HTML5 projects: mock SDK/d.ts/dev-shell/mic worker are installed to $ProjectStateDir/sdk/web/
  $Download = Get-VerifiedSdkArchive "web/latest.json" "builda-sdk-web.zip"
  $Stage = Join-Path $Download.Root "stage/web"
  $Committed = $false
  try {
    Expand-Archive -Force -Path $Download.Archive -DestinationPath $Stage
    if (!(Test-Path (Join-Path $Stage "builda-sdk.js")) -or !(Test-Path (Join-Path $Stage "builda-sdk.d.ts"))) { throw "Web SDK zip layout invalid." }
    $Dst = Join-Path $ProjectStateDir "sdk/web"
    Install-SdkDirectorySet $Download.Root @(@{ Source = $Stage; Destination = $Dst })
    $Committed = $true
  } catch {
    if ($_.Exception.Message -notlike "BUILDA_SDK_ROLLBACK_FAILED:*") {
      Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if ($Committed) { Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue }
  }
  Show-SdkGuidance
  Write-Host "sdk-version=$($Download.Version)"
  Write-Host "sdk-installed=$Dst"
  Write-Host "sdk-engine=h5"
  Write-Host 'sdk-next-1=reference the root-path SDK in the game HTML <head>: <script src="builda-sdk.js"></script> (the built index.html must keep this reference; the zip does not embed the SDK, and the host injects it at runtime per the manifest sdk contract)'
  Write-Host "sdk-next-2=local debugging: builda dev --web <build dir or zip> (the dev server automatically falls back to serving the mock SDK and test shell from $Dst)"
  Write-Host "sdk-next-3=TypeScript type hints: add $Dst/builda-sdk.d.ts to tsconfig include (optional)"
  Install-OnlineDelivery $Download.Version
  try {
    Test-Sdk
  } catch {
    Write-Host "sdk-install=ok"
    Write-Error "sdk-next=fix sdk check errors, then rerun: builda sdk check"
  }
}

function Install-UnitySdk {
  # Unity projects: C# wrapper/jslib go to Assets/Builda/, the Builda WebGL template goes to Assets/WebGLTemplates/
  # (template location mandated by Unity), and the web core mock goes to $ProjectStateDir/sdk/web/ (same as h5).
  # All three locations are owned by the SDK and overwritten wholesale on upgrade.
  $Download = Get-VerifiedSdkArchive "unity/latest.json" "builda-sdk-unity.zip"
  $TmpDir = Join-Path $Download.Root "stage"
  $Committed = $false
  try {
    Expand-Archive -Force -Path $Download.Archive -DestinationPath $TmpDir
    if (!(Test-Path (Join-Path $TmpDir "Assets/Builda")) -or
        !(Test-Path (Join-Path $TmpDir "Assets/WebGLTemplates/Builda")) -or
        !(Test-Path (Join-Path $TmpDir ".builda-agent/sdk/web"))) {
      throw "Unity SDK zip layout invalid."
    }
    $Mappings = @(
      @{ Source = (Join-Path $TmpDir "Assets/Builda"); Destination = "Assets/Builda" },
      @{ Source = (Join-Path $TmpDir "Assets/WebGLTemplates/Builda"); Destination = "Assets/WebGLTemplates/Builda" },
      @{ Source = (Join-Path $TmpDir ".builda-agent/sdk/web"); Destination = (Join-Path $ProjectStateDir "sdk/web") }
    )
    $MicSource = Join-Path $TmpDir "Assets/StreamingAssets/builda-mic"
    if (Test-Path $MicSource) {
      if (Test-Path "Assets/StreamingAssets/builda-mic") {
        Write-Host "sdk-mic=preserved (Assets/StreamingAssets/builda-mic is project-owned; delete it and rerun sdk install to reset to defaults)"
      } else {
        $Mappings += @{ Source = $MicSource; Destination = "Assets/StreamingAssets/builda-mic" }
        Write-Host "sdk-mic=Assets/StreamingAssets/builda-mic"
      }
    }
    Install-SdkDirectorySet $Download.Root $Mappings
    $Committed = $true
  } catch {
    if ($_.Exception.Message -notlike "BUILDA_SDK_ROLLBACK_FAILED:*") {
      Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if ($Committed) { Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue }
  }
  # The BuildaMic analysis Worker is owned by the project (L2 template; the CP may modify the algorithm): upgrades do not overwrite an existing dir;
  # to restore the default, delete Assets\StreamingAssets\builda-mic and rerun sdk install
  Show-SdkGuidance
  Write-Host "sdk-version=$($Download.Version)"
  Write-Host "sdk-installed=Assets/Builda"
  Write-Host "sdk-engine=unity"
  Write-Host "sdk-next-1=Player Settings > Resolution and Presentation > WebGL Template: choose Builda (the template is installed at Assets/WebGLTemplates/Builda/ and already references builda-sdk.js in head)"
  Write-Host "sdk-next-2=Player Settings > Publishing Settings: set Compression Format to Brotli and check Decompression Fallback (recommended), or choose Disabled; builds with compression on but Fallback unchecked are rejected by upload validation"
  Write-Host "sdk-next-3=local debugging: builda dev --web <WebGL build dir or zip> (the dev server automatically falls back to serving the mock SDK and test shell from $ProjectStateDir/sdk/web)"
  Install-OnlineDelivery $Download.Version
  try {
    Test-Sdk
  } catch {
    Write-Host "sdk-install=ok"
    Write-Error "sdk-next=fix sdk check errors, then rerun: builda sdk check"
  }
}

function Install-Sdk {
  if (Test-Path $SdkVersionFile) {
    if (!(Test-Path $SdkVersionFile -PathType Leaf) -or ((Get-Item $SdkVersionFile).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw "SDK pin must be a regular file" }
  }
  # Engine routing: godot installs the addon (existing full flow); h5 installs the web core; unity installs the C# wrapper + template + web core
  if ((Get-EngineValue ".") -eq "h5") {
    Install-WebSdk
    return
  }
  if ((Get-EngineValue ".") -eq "unity") {
    Install-UnitySdk
    return
  }
  if (!(Test-Path "project.godot")) { throw "project.godot missing. Run inside a Godot project root, run: builda sdk init, or use an HTML5 (index.html/package.json at root) or Unity (ProjectSettings/ProjectVersion.txt) project." }
  $Download = Get-VerifiedSdkArchive "latest.json" "builda-sdk.zip"
  $StageRoot = Join-Path $Download.Root "stage"
  $StageAddon = Join-Path $StageRoot "addons/builda"
  $Committed = $false
  try {
    Expand-Archive -Force -Path $Download.Archive -DestinationPath $StageRoot
    if (!(Test-Path (Join-Path $StageAddon "builda.gd")) -or !(Test-Path (Join-Path $StageAddon "plugin.cfg"))) { throw "Godot SDK zip layout invalid." }
    if (Test-Path "addons/builda/mic") {
      Remove-Item -Recurse -Force -LiteralPath (Join-Path $StageAddon "mic") -ErrorAction SilentlyContinue
      Copy-Item -Recurse -Force "addons/builda/mic" (Join-Path $StageAddon "mic")
      Write-Host "sdk-mic=preserved (addons/builda/mic is project-owned; delete it and rerun sdk install to reset to defaults)"
    }
    Install-SdkDirectorySet $Download.Root @(@{ Source = $StageAddon; Destination = "addons/builda" })
    $Committed = $true
  } catch {
    if ($_.Exception.Message -notlike "BUILDA_SDK_ROLLBACK_FAILED:*") {
      Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if ($Committed) { Remove-Item -Recurse -Force -LiteralPath $Download.Root -ErrorAction SilentlyContinue }
  }
  Show-SdkGuidance
  Write-Host "sdk-version=$($Download.Version)"
  Write-Host "sdk-installed=addons/builda"
  Install-BuildaClient
  Set-WebHeadInclude
  Install-OnlineDelivery $Download.Version
  try {
    Test-Sdk
  } catch {
    Write-Host "sdk-install=ok"
    Write-Error "sdk-next=fix sdk check errors, then rerun: builda sdk check"
  }
}

function Install-BuildaClient {
  $Example = Join-Path "addons\builda\examples" "BuildaClient.gd"
  if (!(Test-Path $Example)) { return }
  New-Item -ItemType Directory -Force -Path "scripts" | Out-Null
  $Target = Join-Path "scripts" "BuildaClient.gd"
  if (!(Test-Path $Target)) {
    Copy-Item -Force $Example $Target
    Write-Host "sdk-client=scripts/BuildaClient.gd"
  } else {
    Write-Host "sdk-client=scripts/BuildaClient.gd exists"
  }
  Set-BuildaAutoload
}

function Set-BuildaAutoload {
  if (!(Test-Path "project.godot")) { return }
  $Lines = New-Object System.Collections.Generic.List[string]
  $Lines.AddRange([string[]](Read-Utf8Lines "project.godot"))
  $Result = New-Object System.Collections.Generic.List[string]
  $InAutoload = $false
  $SawAutoload = $false
  $Wrote = $false
  foreach ($Line in $Lines) {
    if ($Line -eq "[autoload]") {
      $InAutoload = $true
      $SawAutoload = $true
      $Result.Add($Line)
      continue
    }
    if ($Line -match '^\[') {
      if ($InAutoload -and !$Wrote) {
        $Result.Add('BuildaClient="*res://scripts/BuildaClient.gd"')
        $Wrote = $true
      }
      $InAutoload = $false
    }
    if ($InAutoload -and $Line -match '^BuildaClient=') {
      if (!$Wrote) {
        $Result.Add('BuildaClient="*res://scripts/BuildaClient.gd"')
        $Wrote = $true
      }
      continue
    }
    $Result.Add($Line)
  }
  if (!$Wrote) {
    if (!$SawAutoload) {
      $Result.Add("")
      $Result.Add("[autoload]")
    }
    $Result.Add('BuildaClient="*res://scripts/BuildaClient.gd"')
  }
  Write-Utf8LinesNoBom "project.godot" $Result
  Write-Host "sdk-autoload=BuildaClient"
}

function Set-WebHeadInclude {
  if (!(Test-Path "export_presets.cfg")) {
    Write-Host "sdk-web-head=export_presets.cfg missing"
    return
  }
  $Path = "export_presets.cfg"
  $Lines = [System.Collections.Generic.List[string]]::new()
  $Lines.AddRange([string[]](Read-Utf8Lines $Path))
  $WebIds = @{}
  $Current = $null
  foreach ($Line in $Lines) {
    if ($Line -match '^\[preset\.(\d+)\]$') {
      $Current = $Matches[1]
      continue
    }
    if ($Line -match '^\[') {
      $Current = $null
      continue
    }
    if ($null -ne $Current -and $Line -eq 'platform="Web"') {
      $WebIds[$Current] = $true
    }
  }
  if ($WebIds.Count -eq 0) {
    Write-Host "sdk-web-head=no web preset"
    return
  }
  $Out = [System.Collections.Generic.List[string]]::new()
  $CurrentSection = $null
  $InWebOptions = $false
  $SeenHead = $false
  $Changed = $false
  $AlreadyOk = $false
  $Injected = 'html/head_include="<script src=\"builda-sdk.js\"></script>"'
  foreach ($Line in $Lines) {
    if ($Line -match '^\[preset\.(\d+)(\.options)?\]$') {
      if ($InWebOptions -and !$SeenHead) {
        $Out.Add($Injected)
        $Changed = $true
      }
      $CurrentSection = $Matches[1]
      $InWebOptions = $WebIds.ContainsKey($CurrentSection) -and ($Matches[2] -eq ".options")
      $SeenHead = $false
      $Out.Add($Line)
      continue
    }
    if ($Line -match '^\[') {
      if ($InWebOptions -and !$SeenHead) {
        $Out.Add($Injected)
        $Changed = $true
      }
      $CurrentSection = $null
      $InWebOptions = $false
      $SeenHead = $false
      $Out.Add($Line)
      continue
    }
    if ($null -ne $CurrentSection -and $WebIds.ContainsKey($CurrentSection) -and !$InWebOptions -and $Line.StartsWith("html/head_include=") -and $Line.Contains("builda-sdk.js")) {
      $Changed = $true
      continue
    }
    if ($InWebOptions -and $Line.StartsWith("html/head_include=")) {
      $SeenHead = $true
      if ($Line.Contains("builda-sdk.js")) {
        $Out.Add($Line.Replace("addons/builda/web/builda-sdk.js", "builda-sdk.js"))
        $AlreadyOk = $true
      } elseif ($Line -eq 'html/head_include=""') {
        $Out.Add($Injected)
        $Changed = $true
      } elseif ($Line.EndsWith('"')) {
        $Out.Add($Line.Substring(0, $Line.Length - 1) + '\n<script src=\"builda-sdk.js\"></script>"')
        $Changed = $true
      } else {
        $Out.Add($Line)
      }
      continue
    }
    $Out.Add($Line)
  }
  if ($InWebOptions -and !$SeenHead) {
    $Out.Add($Injected)
    $Changed = $true
  }
  if ($Changed) {
    Write-Utf8LinesNoBom $Path $Out
    Write-Host "sdk-web-head=builda-sdk.js injected"
  } elseif ($AlreadyOk) {
    Write-Host "sdk-web-head=builda-sdk.js exists"
  } else {
    Write-Host "sdk-web-head=builda-sdk.js exists"
  }
}

function Initialize-SdkProject {
  if (Test-Path "project.godot") {
    Write-Host "project.godot already exists"
    return
  }
  New-Item -ItemType Directory -Force -Path "scenes" | Out-Null
  New-Item -ItemType Directory -Force -Path "scripts" | Out-Null
  $ProjectContent = @'
; Engine configuration file.
; Minimal project skeleton generated by Builda SDK tooling for agent validation.

config_version=5

[application]
config/name="Builda SDK Minimal"
run/main_scene="res://scenes/main.tscn"
'@
  Write-Utf8TextNoBom "project.godot" $ProjectContent
  $SceneContent = @'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/main.gd" id="1_main"]

[node name="Main" type="Node"]
script = ExtResource("1_main")
'@
  Write-Utf8TextNoBom (Join-Path "scenes" "main.tscn") $SceneContent
  $ScriptContent = @'
extends Node

func _ready() -> void:
	if Engine.has_singleton("JavaScriptBridge"):
		print("Builda SDK minimal project loaded")
	else:
		print("Builda SDK minimal project loaded outside Web runtime")
'@
  Write-Utf8TextNoBom (Join-Path "scripts" "main.gd") $ScriptContent
  Write-Host "sdk-init=ok"
  Write-Host "sdk-init-project=project.godot"
  Write-Host "sdk-init-next=builda sdk install && builda sdk smoke"
}

function Test-WebSdk {
  $Dst = Join-Path $ProjectStateDir "sdk/web"
  if (!(Test-Path (Join-Path $Dst "builda-sdk.js"))) { throw "Missing $Dst/builda-sdk.js. Run: builda sdk install" }
  if (!(Test-Path (Join-Path $Dst "builda-sdk.d.ts"))) { throw "Missing $Dst/builda-sdk.d.ts. Run: builda sdk install" }
  if (Test-Path $SdkVersionFile) {
    Write-Host "sdk-version=$((Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim())"
  } else {
    Write-Host "sdk-version=unknown"
    Write-Host "sdk-upgrade-hint=run builda sdk install to record the installed SDK version"
  }
  Test-SdkCompat
  Write-Host "sdk=ok"
  Write-Host "sdk-engine=h5"
  Write-Host "sdk-web=$Dst"
}

function Test-UnitySdk {
  $Dst = Join-Path $ProjectStateDir "sdk/web"
  if (!(Test-Path "Assets/Builda/Runtime/Builda.cs")) { throw "Missing Assets/Builda/Runtime/Builda.cs. Run: builda sdk install" }
  if (!(Test-Path "Assets/Builda/Plugins/WebGL/Builda.jslib")) { throw "Missing Assets/Builda/Plugins/WebGL/Builda.jslib. Run: builda sdk install" }
  if (!(Test-Path "Assets/Builda/Runtime/BuildaMic.cs")) { throw "Missing Assets/Builda/Runtime/BuildaMic.cs. Run: builda sdk install" }
  if (!(Test-Path "Assets/Builda/Plugins/WebGL/BuildaMic.jslib")) { throw "Missing Assets/Builda/Plugins/WebGL/BuildaMic.jslib. Run: builda sdk install" }
  if (!(Test-Path "Assets/WebGLTemplates/Builda/index.html")) { throw "Missing Assets/WebGLTemplates/Builda/index.html. Run: builda sdk install" }
  if ((Read-Utf8Text "Assets/WebGLTemplates/Builda/index.html") -notlike "*builda-sdk.js*") {
    throw "Builda WebGL template lost its builda-sdk.js reference. Run: builda sdk install"
  }
  if (!(Test-Path (Join-Path $Dst "builda-sdk.js"))) { throw "Missing $Dst/builda-sdk.js (mock SDK for builda dev). Run: builda sdk install" }
  if (Test-Path $SdkVersionFile) {
    $InstalledSdkVersion = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim()
    Write-Host "sdk-version=$InstalledSdkVersion"
    $CsLine = Read-Utf8Lines "Assets/Builda/Runtime/Builda.cs" | Where-Object { $_ -match 'SdkVersion = "([^"]*)"' } | Select-Object -First 1
    if ($CsLine -match 'SdkVersion = "([^"]*)"') {
      $CsVersion = $Matches[1]
      if ($InstalledSdkVersion -and $CsVersion -ne $InstalledSdkVersion) {
        throw "SDK version mismatch: $SdkVersionFile=$InstalledSdkVersion but Assets/Builda/Runtime/Builda.cs=$CsVersion. Run: builda sdk install"
      }
    }
  } else {
    Write-Host "sdk-version=unknown"
    Write-Host "sdk-upgrade-hint=run builda sdk install to record the installed SDK version"
  }
  Test-SdkCompat
  # The analysis Worker is owned by the project; if missing, only hint and do not fail (BuildaMic is an optional capability)
  if (Test-Path "Assets/StreamingAssets/builda-mic/builda-mic-worker.js") {
    Write-Host "sdk-mic=Assets/StreamingAssets/builda-mic user-owned"
  } else {
    Write-Host "sdk-mic=missing (rerun builda sdk install to restore the BuildaMic analysis worker)"
  }
  Write-Host "sdk=ok"
  Write-Host "sdk-engine=unity"
  Write-Host "sdk-unity=Assets/Builda"
}

# Get-SdkMockPath: location of the current project's mock SDK (routed by engine; used by smoke;
# h5/unity both go to $ProjectStateDir/sdk/web/, matched automatically when there are no addons)
function Get-SdkMockPath {
  $WebMock = Join-Path $ProjectStateDir "sdk/web/builda-sdk.js"
  if ((Test-Path $WebMock) -and !(Test-Path "addons/builda/web/builda-sdk.js")) { return $WebMock }
  return "addons/builda/web/builda-sdk.js"
}

function Test-Sdk {
  Show-SdkGuidance
  Write-OnlineStatus
  if ((Get-EngineValue ".") -eq "h5") {
    Test-WebSdk
    return
  }
  if ((Get-EngineValue ".") -eq "unity") {
    Test-UnitySdk
    return
  }
  if (!(Test-Path "addons/builda/builda.gd")) { throw "Missing addons/builda/builda.gd. Run: builda sdk install" }
  if (!(Test-Path "addons/builda/web/builda-sdk.js")) { throw "Missing addons/builda/web/builda-sdk.js. Run: builda sdk install" }
  if (!(Test-Path "addons/builda/web/builda-sdk.d.ts")) { throw "Missing addons/builda/web/builda-sdk.d.ts. Run: builda sdk install" }
  $InstalledSdkVersion = ""
  if (Test-Path $SdkVersionFile) {
    $InstalledSdkVersion = (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim()
    Write-Host "sdk-version=$InstalledSdkVersion"
  } else {
    Write-Host "sdk-version=unknown"
    Write-Host "sdk-upgrade-hint=run builda sdk install to record the installed SDK version"
  }
  $PluginVersion = ""
  if (Test-Path "addons/builda/plugin.cfg") {
    $PluginLine = Read-Utf8Lines "addons/builda/plugin.cfg" | Where-Object { $_ -match '^version="([^"]*)"' } | Select-Object -First 1
    if ($PluginLine -match '^version="([^"]*)"') { $PluginVersion = $Matches[1] }
  }
  if ($PluginVersion) {
    Write-Host "sdk-addon-version=$PluginVersion"
    if ($InstalledSdkVersion -and $InstalledSdkVersion -ne $PluginVersion) {
      throw "SDK version mismatch: $SdkVersionFile=$InstalledSdkVersion but addons/builda/plugin.cfg=$PluginVersion. Run: builda sdk install"
    }
  } else {
    Write-Host "sdk-addon-version=unknown"
  }
  if ((Test-Path "project.godot") -and ((Read-Utf8Text "project.godot") -match '(?m)^BuildaClient="\*res://scripts/BuildaClient\.gd"') -and !(Test-Path "scripts/BuildaClient.gd")) {
    throw "Autoload BuildaClient points to missing scripts/BuildaClient.gd. Run: builda sdk install"
  }
  if (Test-Path "scripts/BuildaClient.gd") { Write-Host "sdk-client=scripts/BuildaClient.gd user-owned" } else { Write-Host "sdk-client=missing" }
  Test-SdkCompat
  Write-Host "sdk=ok"
  Write-Host "sdk-addon=addons/builda"
}

function Write-SdkSmokeNextHint {
  param([string]$Engine)
  switch ($Engine) {
    "godot" { Write-Host "sdk-next=export Godot Web build, then run builda dev --web <export directory or zip>" }
    "h5" { Write-Host "sdk-next=run builda dev --web <H5 build directory or zip>" }
    "unity" { Write-Host "sdk-next=build Unity WebGL, then run builda dev --web <WebGL build directory or zip>" }
    default { Write-Host "sdk-next=run builda dev --web <web build directory or zip>" }
  }
  Write-Host "sdk-next-url=?gameId=local-game&builda_mock_player=alice&builda_mock_name=Alice"
}

function Invoke-SdkSmoke {
  Test-Sdk | Out-Null
  $Engine = Get-EngineValue "."
  if (!(Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "sdk-smoke=manual"
    Write-SdkSmokeNextHint $Engine
    Write-Host "Then call Builda.whoami() and Builda.privateKV.set/get/remove."
    return
  }
  $Script = @'
const fs = require("fs");
const vm = require("vm");
const store = new Map();
global.window = {
  location: { search: "?gameId=local-game&builda_mock_player=alice&builda_mock_name=Alice" },
  localStorage: {
    getItem: (key) => store.has(key) ? store.get(key) : null,
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
    key: (i) => Array.from(store.keys())[i] ?? null,
    get length() { return store.size; }
  }
};
global.URLSearchParams = URLSearchParams;
global.fetch = async () => { throw new Error("local mock smoke must not call fetch"); };
vm.runInThisContext(fs.readFileSync(process.env.BUILDA_SMOKE_SDK || "addons/builda/web/builda-sdk.js", "utf8"));
(async () => {
  const who = await window.Builda.whoami();
  if (!who.ok || who.data.id !== "alice") throw new Error("whoami mock failed");
  const save = new TextEncoder().encode(JSON.stringify({ count: 3 }));
  const set = await window.Builda.privateKV.set("wins", save);
  if (!set.ok) throw new Error("privateKV.set mock failed");
  const got = await window.Builda.privateKV.get("wins");
  if (!got.ok || !(got.data instanceof Uint8Array) || JSON.parse(new TextDecoder().decode(got.data)).count !== 3) throw new Error("privateKV.get mock failed");
  const setMany = await window.Builda.privateKV.setMany({ a: new Uint8Array([1]), b: new Uint8Array([2, 2]) });
  if (!setMany.ok) throw new Error("privateKV.setMany mock failed");
  const gotMany = await window.Builda.privateKV.getMany(["a", "b", "absent"]);
  if (!gotMany.ok || gotMany.data.entries.a.length !== 1 || gotMany.data.entries.b.length !== 2 || gotMany.data.entries.absent !== null) throw new Error("privateKV.getMany mock failed");
  const tooBig = await window.Builda.privateKV.set("big", new Uint8Array(32 * 1024 + 1));
  if (tooBig.ok || tooBig.error.code !== "VALUE_TOO_LARGE") throw new Error("privateKV value size limit not enforced");
  const removedMany = await window.Builda.privateKV.removeMany(["a", "b"]);
  if (!removedMany.ok) throw new Error("privateKV.removeMany mock failed");
  const removed = await window.Builda.privateKV.remove("wins");
  if (!removed.ok) throw new Error("privateKV.remove mock failed");
  const missing = await window.Builda.privateKV.get("wins");
  if (!missing.ok || missing.data !== null) throw new Error("privateKV.remove verification failed");
  console.log("sdk-smoke=ok");
  console.log("sdk-mode=local-mock");
  console.log("sdk-smoke-verified=whoami,privateKV.set,privateKV.get,privateKV.setMany,privateKV.getMany,privateKV.removeMany,privateKV.remove");
})().catch((err) => {
  console.error(err && err.stack || err);
  process.exit(1);
});
'@
  $env:BUILDA_SMOKE_SDK = Get-SdkMockPath
  try {
    $Script | node
  } finally {
    Remove-Item Env:BUILDA_SMOKE_SDK -ErrorAction SilentlyContinue
  }
  if ($LASTEXITCODE -ne 0) { throw "sdk smoke failed" }
  Write-SdkSmokeNextHint $Engine
}

function Save-Grant {
  param([string]$Grant)
  if (!$Grant) { throw "empty grant" }
  if ([System.IO.Path]::GetFullPath($AuthDir) -eq $SelfDir) { Write-StateGitignore }
  New-Item -ItemType Directory -Force -Path $AuthDir | Out-Null
  $Grant | Set-Content -Encoding ASCII $TokenPath
  Write-Host "Agent grant saved for 30 minutes."
}

function Save-Refresh {
  param([string]$Refresh)
  if (!$Refresh) { return }
  if ([System.IO.Path]::GetFullPath($AuthDir) -eq $SelfDir) { Write-StateGitignore }
  New-Item -ItemType Directory -Force -Path $AuthDir | Out-Null
  $Refresh | Set-Content -Encoding ASCII $RefreshPath
  Write-Host "Agent authorization saved for 30 days."
}

function Grant-NeedsRefresh {
  if (!(Test-Path $RefreshPath)) { return $false }
  if (!(Test-Path $TokenPath)) { return $true }
  $Age = (Get-Date) - (Get-Item $TokenPath).LastWriteTime
  return $Age.TotalSeconds -ge 1500
}

function Test-GrantFresh {
  if (!(Test-Path $TokenPath)) { return $false }
  $Age = (Get-Date) - (Get-Item $TokenPath).LastWriteTime
  return $Age.TotalSeconds -lt 1500
}

function Test-GrantWithServer {
  if (!(Test-Path $TokenPath)) { return $false }
  $Response = Invoke-BuildaHttpRequest -Method "GET" -Uri "$Base/api/v1/agent/whoami" -Headers @{ Authorization = "Bearer $(Get-Token)" }
  if ($Response.Status -eq 0) {
    throw "AUTH_REFRESH_NETWORK_ERROR: authorization validation transport unavailable (kind=$($Response.Error)); saved authorization was preserved."
  }
  if ($Response.Status -eq 200) { return $true }
  if ($Response.Status -eq 401 -or $Response.Status -eq 403) { return $false }
  throw "AUTH_REFRESH_SERVER_ERROR: authorization validation unavailable (HTTP $($Response.Status)); saved authorization was preserved."
}

function Refresh-Grant {
  if (!(Test-Path $RefreshPath)) { throw "No saved agent authorization." }
  $Refresh = (Read-Utf8Text $RefreshPath).Trim()
  if (!$Refresh) { throw "Empty saved agent authorization." }
  [byte[]]$BodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ refresh_token = $Refresh } | ConvertTo-Json -Compress))
  $Response = Invoke-BuildaHttpRequest -Method "POST" -Uri "$Base/api/v1/agent/auth/refresh" -BodyBytes $BodyBytes -ContentType "application/json"
  if ($Response.Status -eq 0) {
    throw "AUTH_REFRESH_NETWORK_ERROR: transport unavailable (kind=$($Response.Error)); saved authorization was preserved."
  }
  if ($Response.Status -eq 401 -or $Response.Status -eq 403) {
    throw "AUTH_REFRESH_CREDENTIAL_INVALID: saved authorization was rejected; browser authorization is required."
  }
  if ($Response.Status -eq 400 -and ([string]$Response.Body -match '(?i)invalid[_ -]?grant|invalid[_ -]?token|refresh[_ -]?token.*(invalid|expired)')) {
    throw "AUTH_REFRESH_CREDENTIAL_INVALID: saved authorization is invalid or expired; browser authorization is required."
  }
  if (!$Response.IsSuccess) {
    throw "AUTH_REFRESH_SERVER_ERROR: refresh service unavailable (HTTP $($Response.Status)); saved authorization was preserved."
  }
  $Resp = if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { $null } else { [string]$Response.Body | ConvertFrom-Json }
  if (!$Resp -or !$Resp.token) { throw "AUTH_REFRESH_SERVER_ERROR: successful refresh response did not contain a grant; saved authorization was preserved." }
  Save-Grant $Resp.token | Out-Null
  Write-Host "Agent grant refreshed automatically."
}

function Write-AuthStatus {
  Write-Host "auth-dir=$AuthDir"
  if ($env:BUILDA_AUTH_DIR) { Write-Host "auth-store=custom" } else { Write-Host "auth-store=user" }
  if (Test-Path $TokenPath) { Write-Host "grant=present" } else { Write-Host "grant=missing" }
  if (Test-Path $RefreshPath) { Write-Host "agent-authorization=present" } else { Write-Host "agent-authorization=missing" }
}

function Logout-Authorization {
  try {
    foreach ($CredentialPath in @($TokenPath, $RefreshPath)) {
      if (Test-Path $CredentialPath) { Remove-Item -Force -ErrorAction Stop $CredentialPath }
    }
  } catch {
    throw "BUILDA_AUTH_LOGOUT_FAILED: credentials could not be removed from $AuthDir."
  }
  if ((Test-Path $TokenPath) -or (Test-Path $RefreshPath)) {
    throw "BUILDA_AUTH_LOGOUT_FAILED: credentials remain in $AuthDir."
  }
  Write-Host "authorization=logged-out"
  Write-Host "auth-dir=$AuthDir"
}

function Auth-WithPairCode {
  param([string]$Code)
  [byte[]]$BodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ code = $Code } | ConvertTo-Json -Compress))
  $Response = Invoke-BuildaHttpRequest -Method "POST" -Uri "$Base/api/v1/agent/exchange" -BodyBytes $BodyBytes -ContentType "application/json"
  if ($Response.Status -eq 0) {
    throw "AUTH_EXCHANGE_NETWORK_ERROR: pair code exchange transport unavailable (kind=$($Response.Error))."
  }
  if ($Response.Status -eq 400 -or $Response.Status -eq 401 -or $Response.Status -eq 403 -or $Response.Status -eq 404) {
    Write-Host "Pair code exchange failed or expired. Starting browser authorization instead."
    Auth-WithBrowser
    return
  }
  if (!$Response.IsSuccess) { throw "AUTH_EXCHANGE_SERVER_ERROR: pair code exchange unavailable (HTTP $($Response.Status))." }
  $Resp = if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { $null } else { [string]$Response.Body | ConvertFrom-Json }
  if (!$Resp -or !$Resp.token) { throw "AUTH_EXCHANGE_SERVER_ERROR: successful pair code exchange did not contain a grant." }
  Save-Grant $Resp.token
  Save-Refresh $Resp.refresh_token
}

function Auth-WithBrowser {
  $AuthBody = if ($SiteOrigin) { @{ site_origin = $SiteOrigin } | ConvertTo-Json -Compress } else { "{}" }
  $Resp = Invoke-BuildaJsonRequest -Method "POST" -Uri "$Base/api/v1/agent/auth/start" -Body $AuthBody
  if (!$Resp.auth_id -or !$Resp.authorize_url) { throw "Auth start failed." }
  $Interval = if ($Resp.interval) { [int]$Resp.interval } else { 2 }
  $Expires = if ($Resp.expires_in) { [int]$Resp.expires_in } else { 600 }
  $ActivateUrl = if ($Resp.activate_url) { [string]$Resp.activate_url } else { "$Base/activate" }

  Write-Host "I need your BuildaGame permission to upload a draft."
  Write-Host "authorization-url=$($Resp.authorize_url)"
  Write-Host "Opening the browser authorization page..."
  try {
    Start-Process $Resp.authorize_url | Out-Null
  } catch {
    Write-Host "Open this URL in your browser:"
    Write-Host $Resp.authorize_url
  }
  Write-Host "If the browser did not open, visit:"
  Write-Host $Resp.authorize_url
  if ($Resp.user_code) {
    Write-Host "activation-url=$ActivateUrl"
    Write-Host "authorization-code=$($Resp.user_code)"
    Write-Host ""
    Write-Host "On another device, open:"
    Write-Host $ActivateUrl
    Write-Host "Enter code: $($Resp.user_code)"
  }
  Write-Host "Log in or sign up there, click Allow agent, then return here."

  $Elapsed = 0
  while ($Elapsed -lt $Expires) {
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
    $Poll = Invoke-BuildaJsonRequest -Method "GET" -Uri "$Base/api/v1/agent/auth/status?auth_id=$([uri]::EscapeDataString([string]$Resp.auth_id))"
    if ($Poll.status -eq "approved") {
      Save-Grant $Poll.token
      Save-Refresh $Poll.refresh_token
      return
    }
    if ($Poll.status -eq "expired") {
      throw "Authorization expired. Run: builda auth"
    }
    Write-Host -NoNewline "."
  }
  Write-Host ""
  throw "Authorization timed out. Run: builda auth"
}

function Ensure-Authorization {
  param([string]$Code)
  if ((Test-GrantFresh) -and (Test-GrantWithServer)) {
    Write-Host "authorization=ready"
    Write-Host "grant=present"
    if (Test-Path $RefreshPath) { Write-Host "agent-authorization=present" } else { Write-Host "agent-authorization=missing" }
    return
  }
  if (Test-Path $RefreshPath) {
    try {
      Refresh-Grant
      Write-Host "authorization=ready"
      Write-Host "grant=present"
      Write-Host "agent-authorization=present"
      return
    } catch {
      $RefreshError = [string]$_.Exception.Message
      if (!$RefreshError.StartsWith("AUTH_REFRESH_CREDENTIAL_INVALID:")) { throw }
      Write-Host "Saved agent authorization is invalid; starting browser authorization."
    }
  }
  if ($Code) {
    Auth-WithPairCode $Code
  } else {
    Auth-WithBrowser
  }
  Write-Host "authorization=ready"
  Write-Host "grant=present"
  if (Test-Path $RefreshPath) { Write-Host "agent-authorization=present" } else { Write-Host "agent-authorization=missing" }
}

function Invoke-StudioAuth {
  $Ticket = $env:BUILDA_STUDIO_AUTH_TICKET
  if (!$Ticket) { throw "studio-auth requires BUILDA_STUDIO_AUTH_TICKET" }
  New-Item -ItemType Directory -Force -Path $AuthDir | Out-Null
  if (Test-Path $RefreshPath) { throw "studio-auth refuses an auth directory containing a refresh-token; use an isolated Studio HOME" }
  $Resp = Invoke-BuildaJsonRequest -Method "POST" -Uri "$Base/api/v1/agent/auth/studio-exchange" -Body (@{ ticket = $Ticket } | ConvertTo-Json -Compress)
  if (!$Resp.token) { throw "Studio auth exchange did not return a grant." }
  if (!$Resp.refresh_token) { throw "Studio auth exchange did not return a renewal credential." }
  Save-Grant $Resp.token | Out-Null
  Save-Refresh $Resp.refresh_token | Out-Null
  Write-Host "authorization=ready"
  Write-Host "grant=present"
  Write-Host "agent-authorization=present"
  Write-Host "authorization-source=studio"
}

function Get-BundleIdentity {
  param([string]$Path, [string]$Engine)
  $Resolved = (Resolve-Path $Path).Path
  $Stream = [System.IO.File]::OpenRead($Resolved)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Hash = -join ($Hasher.ComputeHash($Stream) | ForEach-Object { $_.ToString("x2") })
  } finally {
    $Hasher.Dispose()
    $Stream.Dispose()
  }
  $NormalizedEngine = $Engine.Trim().ToLowerInvariant()
  if (!$NormalizedEngine) { $NormalizedEngine = "godot" }
  $LegacyStream = [System.IO.File]::OpenRead($Resolved)
  $LegacyHasher = [System.Security.Cryptography.SHA256]::Create()
  $Crypto = [System.Security.Cryptography.CryptoStream]::new(
    [System.IO.Stream]::Null,
    $LegacyHasher,
    [System.Security.Cryptography.CryptoStreamMode]::Write
  )
  try {
    $LegacyStream.CopyTo($Crypto)
    $Suffix = [System.Text.Encoding]::UTF8.GetBytes("`0$NormalizedEngine")
    $Crypto.Write($Suffix, 0, $Suffix.Length)
    $Crypto.FlushFinalBlock()
    $StudioPayloadHash = -join ($LegacyHasher.Hash | ForEach-Object { $_.ToString("x2") })
  } finally {
    $Crypto.Dispose()
    $LegacyHasher.Dispose()
    $LegacyStream.Dispose()
  }
  @{ Size = (Get-Item $Resolved).Length; Sha256 = $Hash; StudioPayloadHash = $StudioPayloadHash; Path = $Resolved }
}

function Get-UploaderPlatform {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    $OsName = "windows"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    $OsName = "darwin"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
    $OsName = "linux"
  } else {
    throw "Unsupported uploader OS."
  }
  $Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  $ArchName = switch ($Architecture) {
    "x64" { "amd64" }
    "arm64" { "arm64" }
    default { throw "Unsupported uploader architecture: $Architecture" }
  }
  $Name = "$OsName-$ArchName"
  if ($Name -notin @("darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64", "windows-amd64", "windows-arm64")) {
    throw "Uploader Helper is not published for $Name."
  }
  @{ OS = $OsName; Arch = $ArchName; Name = $Name }
}

function Install-UploaderHelper {
  $Platform = Get-UploaderPlatform
  $Suffix = if ($Platform.OS -eq "windows") { ".exe" } else { "" }
  $Artifact = "builda-uploader-$($Platform.Name)$Suffix"
  $Sums = Get-BuildaRemoteUtf8Text -Uri "$AgentBase/agent/releases/$Version/SHA256SUMS"
  $Pattern = "(?m)^([0-9a-f]{64})\s{2}$([regex]::Escape($Artifact))\r?$"
  $Match = [regex]::Match($Sums, $Pattern)
  if (!$Match.Success) { throw "Uploader checksum is missing or invalid for $($Platform.Name)." }
  $Expected = $Match.Groups[1].Value
  $Directory = Join-Path $Root "tools/$Expected/$($Platform.Name)"
  $Binary = Join-Path $Directory "builda-uploader$Suffix"
  if ((Test-Path $Binary) -and ((Get-BuildaFileSha256 $Binary) -eq $Expected)) {
    return $Binary
  }
  New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  $Temporary = Join-Path $Directory ".download-$PID"
  Remove-Item -Force -ErrorAction SilentlyContinue $Temporary
  try {
    Invoke-BuildaRawDownload -Uri "$AgentBase/agent/releases/$Version/$Artifact" -Destination $Temporary
    if ((Get-BuildaFileSha256 $Temporary) -ne $Expected) {
      throw "Uploader helper checksum mismatch."
    }
    Move-Item -Force $Temporary $Binary
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $Temporary
  }
  return $Binary
}

function Get-StudioUploadHeaders {
  param([string]$IdempotencyKey)
  $Headers = @{ Authorization = "Bearer $(Get-Token)"; "Idempotency-Key" = $IdempotencyKey }
  if ($env:BUILDA_PUBLISH_OPERATION_ID) {
    if (!$env:BUILDA_PUBLISH_LEASE_ID -or !$env:BUILDA_PUBLISH_ATTEMPT) { throw "missing Studio publish lease" }
    $Headers["X-Builda-Studio-Publish-Id"] = $env:BUILDA_PUBLISH_OPERATION_ID
    $Headers["X-Builda-Publish-Lease-Id"] = $env:BUILDA_PUBLISH_LEASE_ID
    $Headers["X-Builda-Publish-Attempt"] = $env:BUILDA_PUBLISH_ATTEMPT
  }
  return $Headers
}

function Get-UploadIdempotencyKey {
  param([string]$Engine, [string]$GameId, [string]$BundleSha256)
  $Scope = "new"
  if ($GameId) {
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
      $Digest = -join ($Hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($GameId)) | ForEach-Object { $_.ToString("x2") })
    } finally {
      $Hasher.Dispose()
    }
    $Scope = "game-$($Digest.Substring(0, 16))"
  }
  return "build-$Engine-$Scope-$BundleSha256"
}

function Get-DraftIdempotencyKey {
  param([string]$Action, [string]$GameId, [string]$ManifestFile, [bool]$ExistingOnly = $false)
  $PayloadHash = Get-BuildaFileSha256 $ManifestFile
  $Scope = "new"
  if ($GameId) {
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
      $GameHash = -join ($Hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($GameId)) | ForEach-Object { $_.ToString("x2") })
    } finally {
      $Hasher.Dispose()
    }
    $Scope = $GameHash.Substring(0, 16)
  }
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $FingerprintInput = "$Action`0$GameId`0$PayloadHash"
    $Fingerprint = -join ($Hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($FingerprintInput)) | ForEach-Object { $_.ToString("x2") })
  } finally {
    $Hasher.Dispose()
  }
  $Receipt = Join-Path $Root "last-draft-operation-$Fingerprint"
  $Prefix = "draft-$Action-$Scope-$PayloadHash-"
  if ($ExistingOnly) {
    if ($Action -eq "create" -and !$GameId -and !(Test-Path $Receipt)) {
      $PendingOperations = @()
      foreach ($PendingReceipt in @(Get-ChildItem -Path $Root -Filter "last-draft-operation-*" -File -ErrorAction SilentlyContinue)) {
        try { $PendingOperation = (Read-Utf8Text $PendingReceipt.FullName).Trim() } catch { continue }
        if ($PendingOperation -match '^draft-create-new-[0-9a-f]{64}-[0-9a-f]{32}$') {
          $PendingOperations += $PendingOperation
        }
      }
      if ($PendingOperations.Count -eq 1) { return $PendingOperations[0] }
      if ($PendingOperations.Count -gt 1) {
        throw "multiple pending Windows draft operations found; keep the intended receipt and retry"
      }
    }
    for ($Attempt = 0; $Attempt -lt 50; $Attempt++) {
      if (!(Test-Path $Receipt)) { return "" }
      try { $Operation = (Read-Utf8Text $Receipt).Trim() } catch { $Operation = "" }
      if ($Operation -match ("^" + [regex]::Escape($Prefix) + "[0-9a-f]{32}$")) { return $Operation }
      Start-Sleep -Milliseconds 20
    }
    throw "invalid or incomplete draft operation receipt: $Receipt; retry, or remove it if no publish is running"
  }
  $Stream = $null
  try {
    $Stream = [System.IO.File]::Open($Receipt, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  } catch [System.IO.IOException] {
    $Operation = ""
    for ($Attempt = 0; $Attempt -lt 50; $Attempt++) {
      try { $Operation = (Read-Utf8Text $Receipt).Trim() } catch { $Operation = "" }
      if ($Operation -match ("^" + [regex]::Escape($Prefix) + "[0-9a-f]{32}$")) { break }
      Start-Sleep -Milliseconds 20
    }
    if ($Operation -notmatch ("^" + [regex]::Escape($Prefix) + "[0-9a-f]{32}$")) {
      throw "invalid or incomplete draft operation receipt: $Receipt; retry, or remove it if no publish is running"
    }
  }
  if ($Stream) {
    try {
      $Operation = $Prefix + [System.Guid]::NewGuid().ToString("N")
      $Bytes = [System.Text.Encoding]::ASCII.GetBytes("$Operation`n")
      $Stream.Write($Bytes, 0, $Bytes.Length)
      $Stream.Flush($true)
    } finally {
      $Stream.Dispose()
    }
  }
  return $Operation
}

function Complete-DraftIdempotencyKey {
  param([string]$Operation)
  foreach ($Receipt in @(Get-ChildItem -Path $Root -Filter "last-draft-operation-*" -File -ErrorAction SilentlyContinue)) {
    try { $Saved = (Read-Utf8Text $Receipt.FullName).Trim() } catch { continue }
    if ($Saved -eq $Operation) {
      Remove-Item -Force $Receipt.FullName
      return
    }
  }
}

function Invoke-UploadSessionRequest {
  param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body = "")
  [byte[]]$BodyBytes = @()
  if ($Body) { $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body) }
  return Invoke-BuildaAuthenticatedRequest -Method $Method -Uri $Uri -Headers $Headers -BodyBytes $BodyBytes -ContentType "application/json" -AllowHttpFailure
}

function Test-BuildaHttpTimeoutException {
  param([System.Exception]$Exception)
  $Pending = New-Object System.Collections.ArrayList
  $Seen = New-Object System.Collections.ArrayList
  if ($null -ne $Exception) { [void]$Pending.Add($Exception) }
  while ($Pending.Count -gt 0) {
    $Current = $Pending[0]
    $Pending.RemoveAt(0)
    $AlreadySeen = $false
    foreach ($Item in $Seen) {
      if ([object]::ReferenceEquals($Item, $Current)) { $AlreadySeen = $true; break }
    }
    if ($AlreadySeen) { continue }
    [void]$Seen.Add($Current)
    if ($Current -is [System.OperationCanceledException]) { return $true }
    if ($null -ne $Current.InnerException) { [void]$Pending.Add($Current.InnerException) }
    try {
      $BaseException = $Current.GetBaseException()
      if ($null -ne $BaseException -and ![object]::ReferenceEquals($BaseException, $Current)) { [void]$Pending.Add($BaseException) }
    } catch {}
    $ErrorRecordProperty = $Current.PSObject.Properties["ErrorRecord"]
    if ($ErrorRecordProperty -and $null -ne $ErrorRecordProperty.Value -and $null -ne $ErrorRecordProperty.Value.Exception) {
      [void]$Pending.Add($ErrorRecordProperty.Value.Exception)
    }
    $WrappedExceptionProperty = $Current.PSObject.Properties["Exception"]
    if ($WrappedExceptionProperty -and $null -ne $WrappedExceptionProperty.Value -and $WrappedExceptionProperty.Value -is [System.Exception]) {
      [void]$Pending.Add($WrappedExceptionProperty.Value)
    }
  }
  return $false
}

function Invoke-BuildaHttpRequest {
  param(
    [string]$Method,
    [string]$Uri,
    [hashtable]$Headers = @{},
    [byte[]]$BodyBytes = @(),
    [string]$ContentType = "application/json",
    [int]$TimeoutSeconds = 100,
    [switch]$NoRedirect
  )
  Add-Type -AssemblyName System.Net.Http
  $Handler = $null
  $Client = $null
  $Request = $null
  $Response = $null
  try {
    $Handler = New-Object System.Net.Http.HttpClientHandler
    if ($NoRedirect) { $Handler.AllowAutoRedirect = $false }
    $Client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList @(,$Handler)
    $Client.Timeout = if ($TimeoutSeconds -eq -1) { [Threading.Timeout]::InfiniteTimeSpan } else { [TimeSpan]::FromSeconds($TimeoutSeconds) }
    $HttpMethod = New-Object -TypeName System.Net.Http.HttpMethod -ArgumentList @($Method)
    $Request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList @($HttpMethod, [System.Uri]$Uri)
    foreach ($Name in $Headers.Keys) {
      [void]$Request.Headers.TryAddWithoutValidation([string]$Name, [string]$Headers[$Name])
    }
    if ($BodyBytes.Count -gt 0) {
      $Request.Content = New-Object System.Net.Http.ByteArrayContent -ArgumentList @(,$BodyBytes)
      $Request.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue($ContentType)
    }
    $Response = $Client.SendAsync($Request).GetAwaiter().GetResult()
    $ResponseBytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $ResponseBody = [System.Text.Encoding]::UTF8.GetString($ResponseBytes)
    $ResponseHeaders = @{}
    foreach ($Header in $Response.Headers) { $ResponseHeaders[$Header.Key] = [string]::Join(",", $Header.Value) }
    foreach ($Header in $Response.Content.Headers) { $ResponseHeaders[$Header.Key] = [string]::Join(",", $Header.Value) }
    return @{ Status = [int]$Response.StatusCode; Headers = $ResponseHeaders; Body = $ResponseBody; IsSuccess = [bool]$Response.IsSuccessStatusCode; Error = "" }
  } catch {
    $Kind = if (Test-BuildaHttpTimeoutException $_.Exception) { "timeout" } else { "network" }
    return @{ Status = 0; Headers = @{}; Body = ""; IsSuccess = $false; Error = $Kind }
  } finally {
    foreach ($Disposable in @($Response, $Request, $Client, $Handler)) {
      if ($null -ne $Disposable -and $Disposable -is [System.IDisposable]) { $Disposable.Dispose() }
    }
  }
}

function Format-BuildaHttpFailure {
  param([hashtable]$Response)
  if ($Response.Status -eq 0) { return "BUILDA_HTTP_ERROR: kind=$($Response.Error)" }
  $SafeBody = [string]$Response.Body
  $SafeBody = [regex]::Replace($SafeBody, '(?i)("(?:authorization|token|refresh_token|cookie|signature|url)"\s*:\s*)"[^"]*"', '$1"<redacted>"')
  $SafeBody = [regex]::Replace($SafeBody, '(?i)(https://[^\s?"'']+)\?[^\s"'']+', '$1?<redacted>')
  if ($SafeBody.Length -gt 512) { $SafeBody = $SafeBody.Substring(0, 512) }
  return "BUILDA_HTTP_ERROR: status=$($Response.Status) body=$SafeBody"
}

function Invoke-BuildaJsonRequest {
  param([string]$Method, [string]$Uri, [hashtable]$Headers = @{}, [string]$Body = "")
  [byte[]]$BodyBytes = @()
  if ($Body) { $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body) }
  $Response = Invoke-BuildaHttpRequest -Method $Method -Uri $Uri -Headers $Headers -BodyBytes $BodyBytes -ContentType "application/json"
  if (!$Response.IsSuccess) { throw (Format-BuildaHttpFailure $Response) }
  if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { return $null }
  return ([string]$Response.Body | ConvertFrom-Json)
}

# Issue uses a separate authorization audience. Keep these commands out of Show-Usage;
# they are disclosed by an explicit `builda issue --help` or a trusted CLI hint.
function Invoke-BuildaAuthenticatedRequest {
  param(
    [string]$Method,
    [string]$Uri,
    [hashtable]$Headers = @{},
    [byte[]]$BodyBytes = @(),
    [string]$ContentType = "application/json",
    [switch]$AllowHttpFailure
  )
  $RequestHeaders = @{}
  foreach ($Name in $Headers.Keys) { $RequestHeaders[$Name] = $Headers[$Name] }
  $RequestHeaders["Authorization"] = "Bearer $(Get-Token)"
  $Response = Invoke-BuildaHttpRequest -Method $Method -Uri $Uri -Headers $RequestHeaders -BodyBytes $BodyBytes -ContentType $ContentType
  if ($Response.Status -eq 401 -and (Test-Path $RefreshPath)) {
    try {
      Refresh-Grant | Out-Null
      $RequestHeaders["Authorization"] = "Bearer $(Get-Token)"
      $Response = Invoke-BuildaHttpRequest -Method $Method -Uri $Uri -Headers $RequestHeaders -BodyBytes $BodyBytes -ContentType $ContentType
    } catch {
      $RefreshFailure = [string]$_.Exception.Message
      if (!$RefreshFailure.StartsWith("AUTH_REFRESH_CREDENTIAL_INVALID:")) { throw }
    }
  }
  if ($Response.Status -eq 401) { throw "BUILDA_AUTH_REJECTED: authorization was rejected after one refresh" }
  if (!$Response.IsSuccess -and !$AllowHttpFailure) { throw (Format-BuildaHttpFailure $Response) }
  return $Response
}

function Invoke-BuildaCurlUploadWithAuthRetry {
  param([string]$Label, [string[]]$CurlArguments)
  if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe is required for $Label on Windows." }
  $BodyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("builda-curl-" + [System.Guid]::NewGuid().ToString("N") + ".json")
  try {
    for ($Attempt = 0; $Attempt -lt 2; $Attempt++) {
      $Arguments = @("-sS", "-o", $BodyPath, "-w", "%{http_code}") + $CurlArguments + @("-H", "Authorization: Bearer $(Get-Token)")
      $StatusText = & curl.exe @Arguments
      $CurlExitCode = $LASTEXITCODE
      $Body = if (Test-Path $BodyPath) { Read-Utf8Text $BodyPath } else { "" }
      $Status = 0
      [void][int]::TryParse(($StatusText -join "").Trim(), [ref]$Status)
      if ($Status -eq 401 -and $Attempt -eq 0 -and (Test-Path $RefreshPath)) {
        try { Refresh-Grant | Out-Null; continue } catch {
          $RefreshFailure = [string]$_.Exception.Message
          if (!$RefreshFailure.StartsWith("AUTH_REFRESH_CREDENTIAL_INVALID:")) { throw }
        }
      }
      if ($Status -eq 401) { throw "BUILDA_AUTH_REJECTED: authorization was rejected after one refresh" }
      if ($CurlExitCode -ne 0) { throw "BUILDA_HTTP_ERROR: kind=network curlExit=$CurlExitCode" }
      if ($Status -lt 200 -or $Status -ge 300) {
        throw (Format-BuildaHttpFailure @{ Status = $Status; Headers = @{}; Body = $Body; IsSuccess = $false; Error = "" })
      }
      return $Body
    }
  } finally {
    Remove-Item -Force $BodyPath -ErrorAction SilentlyContinue
  }
  throw "BUILDA_AUTH_REJECTED: authorization was rejected after one refresh"
}

function Invoke-DraftRequestWithAuthRetry {
  param([string]$Uri, [hashtable]$Headers, [byte[]]$BodyBytes)
  $Response = Invoke-BuildaAuthenticatedRequest -Method "POST" -Uri $Uri -Headers $Headers -BodyBytes $BodyBytes -ContentType "application/json"
  if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) { return $null }
  return ([string]$Response.Body | ConvertFrom-Json)
}

function New-UploaderConfiguration {
  param(
    [string]$File,
    [string]$AgentVersion,
    [string]$HelperVersion,
    [string]$OS,
    [string]$Architecture,
    [string]$SessionJson
  )
  $TrimmedSession = $SessionJson.Trim()
  if (!$TrimmedSession.StartsWith("{") -or !$TrimmedSession.EndsWith("}")) {
    throw "BUILDA_UPLOADER_CONFIG_INVALID: field=session reason=expected_json_object"
  }
  # Preserve the server's canonical JSON bytes for the session object. Windows PowerShell 5.1
  # may otherwise coerce 64-bit JSON numbers while round-tripping ConvertFrom/ConvertTo-Json.
  $Metadata = @{
    schemaVersion = 1
    file = $File
    agentVersion = $AgentVersion
    helperVersion = $HelperVersion
    os = $OS
    arch = $Architecture
  } | ConvertTo-Json -Compress
  if (!$Metadata.EndsWith("}")) {
    throw "BUILDA_UPLOADER_CONFIG_INVALID: field=metadata reason=encode_failed"
  }
  return $Metadata.Substring(0, $Metadata.Length - 1) + ',"session":' + $TrimmedSession + '}'
}

function Invoke-UploaderHelper {
  param([string]$Binary, [string]$Configuration)
  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = $Binary
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardInput = $true
  $StartInfo.RedirectStandardOutput = $true
  # stderr is intentionally inherited: progress never contaminates the Build DTO on stdout.
  $StartInfo.RedirectStandardError = $false
  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo = $StartInfo
  if (!$Process.Start()) { throw "Failed to start uploader helper." }
  $InputBytes = [System.Text.Encoding]::UTF8.GetBytes("$Configuration`n")
  $InputStream = $Process.StandardInput.BaseStream
  $InputStream.Write($InputBytes, 0, $InputBytes.Length)
  $InputStream.Flush()
  $InputStream.Close()
  $OutputBytes = New-Object System.IO.MemoryStream
  try {
    $Process.StandardOutput.BaseStream.CopyTo($OutputBytes)
    $Output = [System.Text.Encoding]::UTF8.GetString($OutputBytes.ToArray())
  } finally {
    $OutputBytes.Dispose()
  }
  $Process.WaitForExit()
  if ($Process.ExitCode -ne 0) { throw "Uploader helper failed with exit code $($Process.ExitCode)." }
  return $Output.Trim()
}

function Invoke-LegacyBuildUpload {
  param([string]$Zip, [string]$Engine)
  if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe is required for legacy build upload on Windows." }
  $Arguments = @("-X", "POST", "$Base/api/v1/uploads/build")
  if ($env:BUILDA_PUBLISH_OPERATION_ID) {
    $Headers = Get-StudioUploadHeaders $env:BUILDA_PUBLISH_OPERATION_ID
    $Arguments += @(
      "-H", "Idempotency-Key: $($Headers['Idempotency-Key'])",
      "-H", "X-Builda-Studio-Publish-Id: $($Headers['X-Builda-Studio-Publish-Id'])",
      "-H", "X-Builda-Publish-Lease-Id: $($Headers['X-Builda-Publish-Lease-Id'])",
      "-H", "X-Builda-Publish-Attempt: $($Headers['X-Builda-Publish-Attempt'])"
    )
  }
  $Arguments += @("-F", "file=@$Zip", "-F", "engine=$Engine")
  return Invoke-BuildaCurlUploadWithAuthRetry -Label "build upload" -CurlArguments $Arguments
}

function Format-UploadSessionDate {
  param($Value)
  try {
    if ($null -eq $Value -or [int64]$Value -le 0) { return "unknown" }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value).ToString("o")
  }
  catch { return "unknown" }
}

function Format-UploadRecovery {
  param([string]$Body, [switch]$Blocked, [string]$GameId, [string]$Purpose = "build")
  $ScopePrefix = if ($Purpose -eq "assets") { "assets " } else { "" }
  try { $Data = $Body | ConvertFrom-Json } catch { return }
  if ($Blocked -and $Data.errorCode -ne "upload_session_quota_exceeded" -and $Data.msg -ne "upload session quota exceeded") { return }
  if ($Blocked) {
    switch ($Data.quota.reason) {
      "game_active_session" { "This game already has an active upload (limit: 1)." }
      "owner_active_limit" { "Your account has reached the active upload limit (3 across all games)." }
      default { "Check active uploads with: .\.builda-agent\builda.cmd $($ScopePrefix)upload-list --all (requires a server with recovery support)." }
    }
    "Retry the original unchanged ZIP to resume. Rebuilding a ZIP may create a different upload."
    if ($Data.requestId) { "Request ID: $($Data.requestId)" }
  }
  $Sessions = if ($Blocked) { @($Data.quota.sessions) } else { @($Data.sessions) }
  if (!$Blocked -and !($Sessions | Where-Object { $_ })) {
    "No active uploads in this scope."
    if ($GameId) { "Run $($ScopePrefix)upload-list --all to see uploads for your other games." }
  }
  foreach ($Session in $Sessions) {
    if (!$Session -or $Session.id -notmatch "^[a-zA-Z0-9_-]+$") { continue }
    $CommandPrefix = if ($Session.purpose -eq "assets") { "assets " } else { "" }
    $Game = if ($Session.gameId) { $Session.gameId } else { "(new game)" }
    "Session: $($Session.id)  game=$Game  status=$($Session.status)  size=$($Session.expectedSize) bytes"
    "  Created: $(Format-UploadSessionDate $Session.createdAt)  Last activity: $(Format-UploadSessionDate $Session.lastActivityAt)  Expires: $(Format-UploadSessionDate $Session.expiresAt)"
    "  Inspect progress: .\.builda-agent\builda.cmd $($CommandPrefix)upload-status $($Session.id)"
    if ($Session.canCancel -eq $true) { "  To abandon this upload: .\.builda-agent\builda.cmd $($CommandPrefix)upload-cancel $($Session.id)" }
    else { "  Cancellation is currently unavailable; inspect status before retrying." }
  }
  if ($Sessions | Where-Object { $_ }) { "No uploads were canceled. After explicitly canceling an abandoned upload, retry the original upload command." }
}

function Get-ActiveUploadSessions {
  param([string[]]$Options, [string]$Purpose = "build")
  foreach ($Option in $Options) {
    if ($Option -notin @("--all", "--json")) { throw "Usage: builda upload-list [--all] [--json]" }
  }
  $GameId = ""
  $Uri = "$Base/api/v1/uploads/$Purpose/sessions"
  if ($Options -notcontains "--all") {
    $GameId = Get-ProjectGameId
    if ($GameId) { $Uri += "?gameId=$([Uri]::EscapeDataString($GameId))" }
  }
  $Response = Invoke-UploadSessionRequest -Method "GET" -Uri $Uri -Headers @{}
  if ($Response.Status -ne 200) { throw "list upload sessions failed (server recovery support required): $(Format-BuildaHttpFailure $Response)" }
  if ($Options -contains "--json") { $Response.Body }
  else { Format-UploadRecovery -Body $Response.Body -GameId $GameId -Purpose $Purpose }
}

function Invoke-ResumableBuildUpload {
  param([string]$Zip, [string]$Engine)
  $Purpose = if ($Engine -eq "assets") { "assets" } else { "build" }
  if ($Purpose -eq "assets" -and $env:BUILDA_PUBLISH_OPERATION_ID) { throw "Assets upload cannot use a Studio publish operation." }
  $Identity = Get-BundleIdentity $Zip $Engine
  $GameId = Get-ProjectGameId
  $Idempotency = if ($env:BUILDA_PUBLISH_OPERATION_ID) {
    $env:BUILDA_PUBLISH_OPERATION_ID
  } else {
    Get-UploadIdempotencyKey $Engine $GameId $Identity.Sha256
  }
  $Headers = Get-StudioUploadHeaders $Idempotency
  $RequestPayload = @{
    engine = $Engine; gameId = $GameId; expectedSize = $Identity.Size
    expectedSha256 = $Identity.Sha256; idempotencyKey = $Idempotency
  }
  if ($env:BUILDA_PUBLISH_OPERATION_ID) { $RequestPayload["studioPayloadHash"] = $Identity.StudioPayloadHash }
  if ($Purpose -eq "assets") { $RequestPayload.Remove("engine") }
  $RequestBody = $RequestPayload | ConvertTo-Json -Compress
  $Response = Invoke-UploadSessionRequest -Method Post -Uri "$Base/api/v1/uploads/$Purpose/sessions" -Headers $Headers -Body $RequestBody
  if ($Response.Status -in @(404, 405)) {
    if ($Purpose -eq "assets") { throw "Server does not support assets upload sessions; update the backend before retrying." }
    if ($Identity.Size -le 209715200) {
      Write-Error "upload-session=unsupported; falling back to the legacy <=200MiB upload" -ErrorAction Continue
      $LegacyResult = Invoke-LegacyBuildUpload $Identity.Path $Engine
      return $LegacyResult
    }
    throw "This server does not support resumable upload, and the bundle exceeds the legacy 200MiB limit."
  }
  if ($Response.Status -notin @(200, 201)) {
    if ($Response.Status -eq 409) {
      foreach ($Line in @(Format-UploadRecovery -Body $Response.Body -Blocked -Purpose $Purpose)) { [Console]::Error.WriteLine($Line) }
    }
    throw "create upload session failed: $(Format-BuildaHttpFailure $Response)"
  }
  $Session = $Response.Body | ConvertFrom-Json
  if ($Session.status -eq "ready" -and $Session.result) {
    return ($Session.result | ConvertTo-Json -Depth 8 -Compress)
  }
  if ($Session.status -notin @("created", "uploading", "uploaded", "validating", "promoting", "retry_wait")) {
    throw "Upload session cannot continue: status=$($Session.status)"
  }
  $Platform = Get-UploaderPlatform
  $Helper = Install-UploaderHelper
  $Configuration = New-UploaderConfiguration -File $Identity.Path -AgentVersion $Version -HelperVersion $Version -OS $Platform.OS -Architecture $Platform.Arch -SessionJson ([string]$Response.Body)
  $HelperResult = Invoke-UploaderHelper $Helper $Configuration
  return $HelperResult
}

function Get-UploadSessionStatus {
  param([string]$SessionId, [string]$Purpose = "build")
  if (!$SessionId) { throw "Usage: builda upload-status <session>" }
  $Idempotency = if ($Purpose -ne "assets" -and $env:BUILDA_PUBLISH_OPERATION_ID) { $env:BUILDA_PUBLISH_OPERATION_ID } else { "inspect-$SessionId" }
  $Response = Invoke-UploadSessionRequest -Method Post -Uri "$Base/api/v1/uploads/$Purpose/sessions/$SessionId/inspect" -Headers $(if ($Purpose -eq "assets") { @{} } else { Get-StudioUploadHeaders $Idempotency })
  if ($Response.Status -ne 200) { throw "query upload session failed: HTTP $($Response.Status): $($Response.Body)" }
  $Session = $Response.Body | ConvertFrom-Json
  [int64]$UploadedBytes = 0
  foreach ($Part in @($Session.parts)) { $UploadedBytes += [int64]$Part.size }
  $Result = [ordered]@{
    id = $Session.id; gameId = $Session.gameId; createdAt = $Session.createdAt
    lastActivityAt = $Session.lastActivityAt; status = $Session.status; engine = $Session.engine
    expectedSize = $Session.expectedSize; uploadedBytes = $UploadedBytes
    effectiveLimitBytes = $Session.effectiveLimitBytes; expiresAt = $Session.expiresAt
  }
  if ($Session.errorCode) { $Result["errorCode"] = $Session.errorCode }
  if ($Session.errorMessage) { $Result["errorMessage"] = $Session.errorMessage }
  if ($Session.result) { $Result["result"] = $Session.result }
  $Result | ConvertTo-Json -Depth 10 -Compress
}

function Cancel-UploadSession {
  param([string]$SessionId, [string]$Purpose = "build")
  if (!$SessionId) { throw "Usage: builda upload-cancel <session>" }
  $Idempotency = if ($Purpose -ne "assets" -and $env:BUILDA_PUBLISH_OPERATION_ID) { $env:BUILDA_PUBLISH_OPERATION_ID } else { "cancel-$SessionId" }
  $Headers = if ($Purpose -eq "assets") { @{} } else { Get-StudioUploadHeaders $Idempotency }
  $Response = Invoke-UploadSessionRequest -Method Post -Uri "$Base/api/v1/uploads/$Purpose/sessions/$SessionId/cancel" -Headers $Headers
  if ($Response.Status -ne 204) { throw "cancel upload session failed: HTTP $($Response.Status): $($Response.Body)" }
}

# ── builda gen: AI-generated assets (ADR 0047) ─────────────────────────────────────────
# Same contract as the Unix CLI: stdout is stable key=value lines (or a single object with --json), progress goes to stderr, exit codes see Show-GenUsage.
# The source of truth is the Builda platform; the local .builda-agent/gen/ is only a deletable ledger (gitignored), used to resume the original task on rerun.
$GenDir = Join-Path $Root "gen"
$GenDefaultWait = 100
$script:GenTaskId = ""
$script:GenOutArg = ""
$script:GenJson = $false
$script:GenResult = New-Object System.Collections.ArrayList
$GenCli = ".\.builda-agent\builda.cmd"
# Top-up path relayed verbatim to the user when Credits run out (user-facing text; the agent must not rewrite it).
$GenTopupHint = "In the Builda App, create an AI game, then tap the top-right button 3 times in a row to open the Credits page and top up"

function Show-GenUsage {
  @'
builda gen — generate game assets with Builda AI. Every successful generation consumes the user's Builda Credits
(charged after completion by actual usage; failed or rejected tasks cost nothing).

Usage:
  builda gen audio   --prompt <text> [-o <file|dir/>] [--ref <image>]             [common options]
  builda gen music   --prompt <text> [--title <text>] [--lyrics <text>|--lyrics-file <path>] [--instrumental]
                     [--duration <seconds>] [--count <n>] [-o <file|dir/>] [common options]
  builda gen image   --prompt <text> [-o <file|dir/>] [--ref <image>]... [--aspect-ratio 16:9]
                     [--count 1..4] [--background auto|transparent|opaque]      [common options]
  builda gen model3d --prompt <text> [-o <file|dir/>] [--ref <image>]... [--faces <n>] [common options]
    common options: [--model <id>] [--wait <dur>|--no-wait] [--max-energy <n>] [--dry-run] [--new] [--force] [--json]
  builda gen wait <task> [-o <file|dir/>] [--wait <dur>] [--force] [--json]
  builda gen status <task> [--json]
  builda gen download <task> [-o <file|dir/>] [--force] [--json]
  builda gen list [--limit <n>] [--json]           Tasks started from this project (local ledger).
  builda gen balance [--json]                      Energy balance.
  builda gen usage [--limit <n>] [--type all|income|expense] [--json]
  Audio model options: --duration <seconds> --count <n> --loop --prompt-influence <0..1>
  Music/audio limits and supported options depend on the selected model.
  builda gen models [audio|music|image|model3d] [--json] Models, prices and limits.

Examples:
  builda gen audio --prompt "0.4 second crisp 8-bit jump sound, fast attack, no reverb" -o assets/sfx/jump.mp3
  builda gen audio --prompt "calm forest ambience loop, birds, light wind, about 20 seconds" -o assets/bgm/ --dry-run
  builda gen image --prompt "pixel-art treasure chest icon, front view" --background transparent -o assets/ui/chest.png
  builda gen model3d --prompt "low-poly wooden treasure chest, game asset" --faces 8000 -o assets/models/chest.glb --no-wait
  builda gen audio --prompt "0.4 second crisp 8-bit jump sound, fast attack, no reverb" -o assets/sfx/jump.mp3 --new --force

Behaviour:
  Rerunning the same command resumes the same task and never charges twice; it returns the existing result.
  --new asks for a different take: it is charged every time it succeeds, so pair it with --force or a new -o
        (an existing target is refused before submitting, nothing charged).
  -o must stay inside the project; next= lines are only ever runnable commands, explanations are in hint=.
  --wait defaults to 100s; if the task is still running the command exits 6 and prints next=builda gen wait ...
  model3d can take up to 45 minutes: prefer --no-wait, then run the printed next= command later.
  Multiple outputs: images become <name>.png, <name>-2.png ...; model3d saves <name>.glb (extra files, if any, get a -<kind> suffix).
  Energy: energy-estimate is an upper bound (audio is priced per second of actual length); energy-cost is final.
  Durations: 90, 90s, 5m, 1h. Default output dir: builda-gen/<type>/.

Exit codes:
  0 done (files written)  2 invalid usage/params  3 authorization needed  4 not enough energy / over --max-energy
  5 task failed or content rejected (no charge)  6 still running after --wait  7 download/verify failed
  8 output file exists (use --force or another -o)  9 temporarily unavailable (retry the same command later)
  1 other error  130 interrupted (the task keeps running; resume with builda gen wait)
'@ | Write-Host
}

function Add-GenResult {
  param([string]$Key, [AllowEmptyString()][string]$Value)
  [void]$script:GenResult.Add(@($Key, $Value))
  if (!$script:GenJson) { Write-Host "$Key=$Value" }
}

function ConvertTo-GenCamel {
  param([string]$Key)
  return [regex]::Replace($Key, '-([a-z])', { param($m) $m.Groups[1].Value.ToUpper() })
}

# ConvertTo-GenParamsObject "k=v;k=v" -> object, numeric values converted to integers.
function ConvertTo-GenParamsObject {
  param([string]$Value)
  $Out = [ordered]@{}
  foreach ($Kv in ($Value -split ";" | Where-Object { $_ })) {
    $Pair = $Kv.Split("=", 2)
    $N = 0L
    if ($Pair[0] -in @("lyrics64", "title64")) { $Out[$Pair[0].Substring(0,$Pair[0].Length-2)] = $script:Utf8NoBom.GetString([Convert]::FromBase64String($Pair[1])); continue }
    if ($Pair[0] -in @("duration", "promptInfluence")) { $Out[$Pair[0]] = [double]::Parse($Pair[1], [Globalization.CultureInfo]::InvariantCulture); continue }
    if ($Pair[0] -in @("loop", "instrumental")) { $Out[$Pair[0]] = $Pair[1] -eq "true"; continue }
    $Out[$Pair[0]] = if ($Pair[1] -match '^-?\d+$' -and [long]::TryParse($Pair[1], [ref]$N)) { $N } else { $Pair[1] }
  }
  return $Out
}

function Exit-Gen {
  param([int]$Code = 0)
  if ($script:GenJson) {
    $Obj = [ordered]@{}
    foreach ($Pair in $script:GenResult) {
      $Key = ConvertTo-GenCamel $Pair[0]
      $Value = $Pair[1]
      $Number = 0L
      $Typed = if ($Value -match '^-?\d+$' -and [long]::TryParse($Value, [ref]$Number)) { $Number } else { $Value }
      # Make JSON types directly usable: yes/no -> boolean, running -> array, params -> object.
      if ($Key -in @("reused", "charged", "newGeneration", "newIgnored", "energySettled") -and $Value -in @("yes", "no")) { $Typed = ($Value -eq "yes") }
      elseif ($Key -eq "running") { $Typed = @($Value -split "," | Where-Object { $_ }) }
      elseif ($Key -eq "params") { $Typed = ConvertTo-GenParamsObject $Value }
      if ($Key -in @("file", "md5", "dimensions")) {
        $ListKey = if ($Key -eq "dimensions") { $Key } else { $Key + "s" }
        if (!$Obj.Contains($ListKey)) { $Obj[$ListKey] = New-Object System.Collections.ArrayList }
        [void]$Obj[$ListKey].Add($Typed)
      } elseif ($Obj.Contains($Key) -and $Key -eq "hint") {
        $Obj[$Key] = [string]$Obj[$Key] + "; " + $Typed  # hint is always a single string
      } else {
        $Obj[$Key] = $Typed
      }
    }
    Write-Host ($Obj | ConvertTo-Json -Depth 5 -Compress)
  }
  exit $Code
}

# Usage: Stop-Gen <exit> <error> [hint] [next]. hint= is an explanation; next= only holds commands that can be run verbatim (omitted if none).
# When a generation command fails before any task exists, always include charged=no: nothing submitted, nothing charged.
function Stop-Gen {
  param([int]$Code, [string]$ErrorKey, [string]$Hint = "", [string]$Next = "")
  if ($script:GenIsGenerate -and !$script:GenTaskId) { Add-GenResultOnce "charged" "no" }
  Add-GenResult "error" $ErrorKey
  if ($Hint) { Add-GenResult "hint" $Hint }
  if ($Next) { Add-GenResult "next" $Next }
  Exit-Gen $Code
}

function Add-GenResultOnce {
  param([string]$Key, [string]$Value)
  foreach ($Pair in $script:GenResult) { if ($Pair[0] -eq $Key) { return } }
  Add-GenResult $Key $Value
}

# Format-GenArg makes next= paste-and-run: safe characters as-is, others wrapped in double quotes (UTF-8 preserved).
function Format-GenArg {
  param([string]$Value)
  if ($Value -match '^[A-Za-z0-9._/:@+\\-]+$') { return $Value }
  return '"' + $Value.Replace('"', '\"') + '"'
}

# Get-GenRetryHint gives retry advice by stage: before a task exists, state clearly "no task created, not charged"; only when a task exists suggest resuming it.
function Get-GenRetryHint {
  if (!$script:GenTaskId) { return "no task was created and nothing was charged; wait about a minute, then run the same command again" }
  return "the task is still on the platform (no double charge); wait about a minute, then run next"
}

# Get-GenRetryNext gives a runnable resume-wait command when a task exists; before a task exists there is no command to give (just rerun as-is).
function Get-GenRetryNext {
  if ($script:GenTaskId) { return (Get-GenNextWait) }
  return ""
}

# Stop-GenParam: unified format for local parameter errors: param / allowed / charged=no, consistent with platform limits validation.
function Stop-GenParam {
  param([string]$Param, [string]$Allowed, [string]$ErrorKey = "invalid-params", [string]$Hint = "")
  Add-GenResult "param" $Param
  Add-GenResult "allowed" $Allowed
  if (!$Hint) {
    $Hint = if ($script:GenIsGenerate) { "fix $Param (allowed: $Allowed) and run again; nothing was submitted or charged" } else { "fix $Param (allowed: $Allowed) and run again" }
  }
  Stop-Gen 2 $ErrorKey $Hint
}

# Get-GenValue gets a flag's value; a missing value or a value that looks like an option (-o --json, --prompt --dry-run) exits as a parameter error;
# never submit (and charge) with misaligned arguments. For values that really start with -, use the --opt=value form.
function Get-GenValue {
  param([string[]]$Arguments, [int]$Index)
  $Flag = $Arguments[$Index]
  if ($Index + 1 -ge $Arguments.Count) { Stop-GenParam $Flag "a value" "missing-value" "$Flag needs a value" }
  if ($Arguments[$Index + 1].StartsWith("-")) {
    Stop-GenParam $Flag "a value (for a value starting with -, use $Flag=<value>)" "value-looks-like-option" "the value of $Flag looks like another option"
  }
  return $Arguments[$Index + 1]
}

# Assert-GenOut: outputs must stay inside the project: reject absolute paths, .. escaping the project, and toolchain and Git dirs.
function Assert-GenOut {
  if (!$script:GenOutArg) { return }
  $Parts = New-Object System.Collections.ArrayList
  foreach ($Seg in ($script:GenOutArg -split '[\\/]')) {
    if ($Seg -eq "" -or $Seg -eq ".") { continue }
    if ($Seg -eq ".." -and $Parts.Count -gt 0 -and $Parts[$Parts.Count - 1] -ne "..") { $Parts.RemoveAt($Parts.Count - 1); continue }
    [void]$Parts.Add($Seg)
  }
  $First = if ($Parts.Count -gt 0) { ([string]$Parts[0]).ToLowerInvariant() } else { "" }
  $Invalid = [System.IO.Path]::IsPathRooted($script:GenOutArg) -or $script:GenOutArg.StartsWith("~") -or $Parts.Count -eq 0 -or
    $First -in @("..", ".builda-agent", ".git")
  # PowerShell 5.1 cannot reliably resolve symlink targets: reject any existing path segment that is a symlink/junction, ensuring it stays inside the project.
  $Probe = (Get-Location).Path
  foreach ($Seg in $Parts) {
    if ($Invalid) { break }
    $Probe = Join-Path $Probe $Seg
    $Item = Get-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
    if (!$Item) { break }
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $Invalid = $true }
  }
  if ($Invalid) {
    Stop-GenParam "-o" "a relative path inside the project (not .builda-agent/ or .git/, no symlinks)" "invalid-output"
  }
}

# Get-GenOutConflict returns existing files that new output would overwrite (empty string if none); in dir mode file names include the task id, so no conflict.
function Get-GenOutConflict {
  param([string]$GenType, [int]$Count = 1)
  $Out = $script:GenOutArg
  if (!$Out -or $Out.EndsWith("/") -or $Out.EndsWith("\") -or (Test-Path -LiteralPath $Out -PathType Container)) { return "" }
  $Ext = [System.IO.Path]::GetExtension($Out)
  $BasePath = if ($Ext) { $Out.Substring(0, $Out.Length - $Ext.Length) } else { $Out }
  $Candidates = New-Object System.Collections.ArrayList
  [void]$Candidates.Add($Out)
  switch ($GenType) {
    "audio" { [void]$Candidates.Add("$BasePath.mp3") }
    "image" {
      [void]$Candidates.Add("$BasePath.png")
      for ($n = 2; $n -le $Count; $n++) { [void]$Candidates.Add("$BasePath-$n.png") }
    }
    "model3d" { [void]$Candidates.Add("$BasePath.glb") }
  }
  if ($GenType -in @("audio", "music")) {
    foreach ($Fmt in @("mp3", "m4a")) {
      [void]$Candidates.Add("$BasePath.$Fmt")
      for ($n = 2; $n -le $Count; $n++) { [void]$Candidates.Add("$BasePath-$n.$Fmt") }
    }
  }
  if ($GenType -eq "music") {
    $Directory = [System.IO.Path]::GetDirectoryName($BasePath)
    if (!$Directory) { $Directory = "." }
    if (Test-Path -LiteralPath $Directory -PathType Container) {
      $Pattern = "^" + [regex]::Escape([System.IO.Path]::GetFileName($BasePath)) + '-\d+\.(mp3|m4a)$'
      foreach ($File in (Get-ChildItem -LiteralPath $Directory)) { if ($File.Name -match $Pattern) { [void]$Candidates.Add($File.FullName) } }
    }
  }
  foreach ($C in $Candidates) { if (Test-Path -LiteralPath $C) { return [string]$C } }
  return ""
}

# Get-GenTypeParams validates type-specific params and returns normalized extra ("k=v;k=v" sorted by key, byte-identical to the Unix CLI).
function Get-GenTypeParams {
  param([string]$GenType, [string]$Aspect, [string]$Count, [string]$Background, [string]$Faces)
  $Parts = New-Object System.Collections.ArrayList
  switch ($GenType) {
    { $_ -in @("audio", "music") } {
      if ($Aspect) { Stop-GenParam "--aspect-ratio" "image only" "option-not-supported" }
      if ($Count) { [void]$Parts.Add("count=$Count") }
      if ($Background) { Stop-GenParam "--background" "image only" "option-not-supported" }
      if ($Faces) { Stop-GenParam "--faces" "model3d only" "option-not-supported" }
    }
    "image" {
      if ($Faces) { Stop-GenParam "--faces" "model3d only" "option-not-supported" }
      if ($Aspect -and $Aspect -notmatch '^\d+:\d+$') { Stop-GenParam "--aspect-ratio" "W:H, see gen models image" }
      if ($Background -and $Background -cnotin @("auto", "transparent", "opaque")) { Stop-GenParam "--background" "auto,transparent,opaque" }
      if ($Aspect) { [void]$Parts.Add("aspectRatio=$Aspect") }
      if ($Background) { [void]$Parts.Add("backgroundMode=$Background") }
      if ($Count) { [void]$Parts.Add("count=$Count") }
    }
    "model3d" {
      if ($Aspect) { Stop-GenParam "--aspect-ratio" "image only" "option-not-supported" }
      if ($Count) { Stop-GenParam "--count" "image only" "option-not-supported" }
      if ($Background) { Stop-GenParam "--background" "image only" "option-not-supported" }
      if ($Faces) { [void]$Parts.Add("targetFaces=$Faces") }
    }
  }
  return ($Parts -join ";")
}

function Write-GenProgress { param([string]$Text) [Console]::Error.WriteLine("gen| $Text") }

function Get-GenSha256 {
  param([string]$Text)
  $Sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = $Sha.ComputeHash($script:Utf8NoBom.GetBytes($Text))
    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally { $Sha.Dispose() }
}

# Same approach as Get-BuildaFileSha256: stream-compute directly with .NET, without relying on PowerShell module auto-loading.
function Get-GenFileMd5 {
  param([string]$Path)
  $FullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $Stream = $null
  $Hasher = $null
  try {
    $Stream = [System.IO.File]::Open($FullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $Hasher = [System.Security.Cryptography.MD5]::Create()
    [byte[]]$Digest = $Hasher.ComputeHash($Stream)
    return -join ($Digest | ForEach-Object { $_.ToString("x2") })
  } finally {
    if ($Hasher -is [System.IDisposable]) { $Hasher.Dispose() }
    if ($Stream -is [System.IDisposable]) { $Stream.Dispose() }
  }
}

function ConvertTo-GenSafeTask { param([string]$TaskId) return [regex]::Replace($TaskId, '[^A-Za-z0-9_.-]', '_') }

function Read-GenJsonFile {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) { return $null }
  try { return (Read-Utf8Text $Path | ConvertFrom-Json) } catch { return $null }
}

function Write-GenJsonFile {
  param([string]$Path, $Value)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Tmp = "$Path.tmp"
  Write-Utf8TextNoBom $Tmp (($Value | ConvertTo-Json -Depth 6 -Compress) + "`n")
  Move-Item -Force -LiteralPath $Tmp -Destination $Path
}

function Update-GenLedgerTask {
  param([string]$TaskId, [hashtable]$Fields)
  $Path = Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask $TaskId) + ".json")
  $Record = [ordered]@{ taskId = $TaskId; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
  $Existing = Read-GenJsonFile $Path
  if ($Existing) { foreach ($P in $Existing.PSObject.Properties) { $Record[$P.Name] = $P.Value } }
  foreach ($K in $Fields.Keys) {
    if ($K -eq "files") {
      $Merged = New-Object System.Collections.ArrayList
      foreach ($F in @($Record["files"]) + @($Fields[$K])) { if ($F -and !$Merged.Contains([string]$F)) { [void]$Merged.Add([string]$F) } }
      $Record[$K] = @($Merged)
    } elseif ($K -eq "status" -and [string]$Record["status"] -in @("done", "failed") -and [string]$Fields[$K] -notin @("done", "failed")) {
      # Status only moves forward: done/failed tasks never revert to pending/running on rerun or timeout (used to tell whether this run is a reuse).
      continue
    } else {
      $Record[$K] = $Fields[$K]
    }
  }
  $Record["updatedAt"] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  Write-GenJsonFile $Path $Record
}

function Get-GenLedgerOut {
  param([string]$TaskId)
  $Record = Read-GenJsonFile (Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask $TaskId) + ".json"))
  if ($Record -and $Record.out) { return [string]$Record.out }
  return ""
}

function Set-GenRequestDone {
  param([string]$TaskId)
  $Dir = Join-Path $GenDir "requests"
  if (!(Test-Path -LiteralPath $Dir)) { return }
  foreach ($File in Get-ChildItem -LiteralPath $Dir -Filter "*.json") {
    $R = Read-GenJsonFile $File.FullName
    if ($R -and $R.taskId -eq $TaskId -and !$R.done) {
      Write-GenJsonFile $File.FullName ([ordered]@{ nonce = [string]$R.nonce; done = $true; taskId = $TaskId; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
    }
  }
}

function ConvertFrom-GenDuration {
  param([string]$Raw)
  $Mult = 1
  $N = $Raw
  if ($Raw -match '^(\d+)h$') { $N = $Matches[1]; $Mult = 3600 }
  elseif ($Raw -match '^(\d+)m$') { $N = $Matches[1]; $Mult = 60 }
  elseif ($Raw -match '^(\d+)s$') { $N = $Matches[1] }
  if ($N -notmatch '^\d+$') { Stop-GenParam "--wait" "90, 90s, 5m, 1h" "invalid-duration" }
  return [int]$N * $Mult
}

function Get-GenNextWait {
  $Cmd = "$GenCli gen wait $script:GenTaskId"
  if ($script:GenOutArg) { $Cmd = "$Cmd -o $(Format-GenArg $script:GenOutArg)" }
  return $Cmd
}

function Assert-GenAuth {
  if (Grant-NeedsRefresh) { try { Refresh-Grant | Out-Null } catch {} }
  if (!(Test-Path $TokenPath) -and (Test-Path $RefreshPath)) { try { Refresh-Grant | Out-Null } catch {} }
  if (!(Test-Path $TokenPath)) { Stop-Gen 3 "auth-required" "authorize first (the user approves in the browser), then rerun this command" "$GenCli auth" }
}

# Invoke-GenApi returns the parsed object on success; on failure exits per contract (same code table as Unix gen_fail_body).
function Invoke-GenApi {
  param([string]$Method, [string]$Path, [byte[]]$BodyBytes = @(), [string]$ContentType = "application/json")
  try {
    $Response = Invoke-BuildaAuthenticatedRequest -Method $Method -Uri "$Base$Path" -BodyBytes $BodyBytes -ContentType $ContentType -AllowHttpFailure
  } catch {
    if ([string]$_.Exception.Message -like "BUILDA_AUTH_REJECTED*") { Stop-Gen 3 "auth-required" "authorize first (the user approves in the browser), then rerun this command" "$GenCli auth" }
    Stop-Gen 9 "network-error" "check the network; $(Get-GenRetryHint)" (Get-GenRetryNext)
  }
  # Every server response carries X-Request-Id: print it to the user/agent on error so feedback can locate backend logs directly.
  $script:GenRequestId = ""
  if ($Response.Headers) { foreach ($K in @($Response.Headers.Keys)) { if ($K -ieq "X-Request-Id") { $script:GenRequestId = [string]$Response.Headers[$K] } } }
  if ($Response.Status -eq 0) { Stop-Gen 9 "network-error" "check the network; $(Get-GenRetryHint)" (Get-GenRetryNext) }
  $Body = $null
  if (![string]::IsNullOrWhiteSpace([string]$Response.Body)) { try { $Body = [string]$Response.Body | ConvertFrom-Json } catch {} }
  if ($Response.IsSuccess) { return $Body }
  Stop-GenForResponse $Response.Status $Body
}

function Stop-GenForResponse {
  param([int]$Status, $Body)
  $Code = if ($Body -and $null -ne $Body.code) { [string]$Body.code } else { "" }
  $Msg = if ($Body -and $Body.msg) { [string]$Body.msg } else { "" }
  # The platform embeds its own reqId in message: split it out and give it separately to avoid confusion with Builda's request-id.
  $PlatformReq = ""
  if ($Msg -match '\s*reqId=(\S+)') { $PlatformReq = $Matches[1]; $Msg = ($Msg -replace '\s*reqId=\S+', '').Trim() }
  if ($Msg) { Add-GenResult "message" $Msg }
  if ($Code) { Add-GenResult "code" $Code }
  # request-id is the ID to give when reporting issues; platform-request-id is the platform's internal ID, for reconciliation only.
  if ($script:GenRequestId) { Add-GenResult "request-id" $script:GenRequestId }
  if ($PlatformReq) { Add-GenResult "platform-request-id" $PlatformReq }
  switch ($Code) {
    "140006" {
      Add-GenResult "energy-topup" $GenTopupHint
      Stop-Gen 4 "insufficient-energy" "tell the user their Builda Credits are not enough and relay the energy-topup steps to them without changing them; do not retry or split the request"
    }
    "140007" { Stop-Gen 5 "content-rejected" "rewrite the prompt without sensitive content and run again; if it fails again, ask the user" }
    "140101" { Stop-Gen 1 "not-available" "this model or generation type is not open for this account yet" "$GenCli gen models" }
    { $_ -in @("140102", "10003") } {
      $Why = if ($Msg) { $Msg } else { "see gen models for limits" }
      Stop-Gen 2 "invalid-params" "the platform rejected a parameter: $Why; fix it and run again"
    }
    "140104" {
      $Running = if ($Body.runningTaskIds) { @($Body.runningTaskIds) -join "," } else { "" }
      Add-GenResult "running" $Running
      Stop-Gen 9 "too-many-running" "too many tasks are running; wait for one to finish first" "$GenCli gen wait $(($Running -split ',')[0])"
    }
    { $_ -in @("140103", "140110") } { Stop-Gen 9 "busy" (Get-GenRetryHint) (Get-GenRetryNext) }
    "140105" { Stop-Gen 1 "request-conflict" "the same request id was used with different parameters; rerun with --new" }
    "140106" { Stop-Gen 1 "task-not-found" "check the task id" "$GenCli gen list" }
    "140107" { Stop-Gen 1 "account-unavailable" "the Builda account is restricted; ask the user to check the Builda App" }
    "140109" { Stop-GenParam "--ref" "png,jpg,webp up to 10 MiB" "reference-unavailable" }
    "200461" {
      if (!($Body -and $Body.retriable)) {
        Stop-Gen 1 "service-unavailable" "this capability is not configured on the Builda side right now (retrying will not help); if you used --ref, try without it, otherwise report to the user"
      }
    }
    "200460" { Stop-Gen 3 "platform-account-missing" "ask the user to sign out on the Builda website and sign in again by QR code, then re-authorize" "$GenCli auth --force" }
  }
  if (($Body -and $Body.retriable) -or $Status -ge 500) {
    Stop-Gen 9 "unavailable" (Get-GenRetryHint) (Get-GenRetryNext)
  }
  Stop-Gen 1 "http-$Status" "unexpected server response; report it to the user with the request-id"
}

function Get-GenJsonBytes { param($Value) return $script:Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Depth 6 -Compress)) }

function Invoke-GenGenerate {
  param([string]$GenType, [string[]]$Arguments)
  $Prompt = ""; $Model = ""; $WaitS = $GenDefaultWait; $NoWait = $false; $MaxEnergy = ""; $DryRun = $false
  $New = $false; $Force = $false; $Refs = New-Object System.Collections.ArrayList
  $Aspect = ""; $Count = ""; $Background = ""; $Faces = ""; $WaitGiven = $false
  $Media = @{}
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $A = $Arguments[$i]
    switch -Regex ($A) {
      '^(-p|--prompt)$' { $Prompt = Get-GenValue $Arguments $i; $i++; continue }
      '^--prompt=' { $Prompt = $A.Substring(9); continue }
      '^(-o|--out)$' { $script:GenOutArg = Get-GenValue $Arguments $i; $i++; continue }
      '^--out=' { $script:GenOutArg = $A.Substring(6); continue }
      '^--ref$' { [void]$Refs.Add((Get-GenValue $Arguments $i)); $i++; continue }
      '^--ref=' { [void]$Refs.Add($A.Substring(6)); continue }
      '^--model$' { $Model = Get-GenValue $Arguments $i; $i++; continue }
      '^--model=' { $Model = $A.Substring(8); continue }
      '^--wait$' { $WaitS = ConvertFrom-GenDuration (Get-GenValue $Arguments $i); $WaitGiven = $true; $i++; continue }
      '^--wait=' { $WaitS = ConvertFrom-GenDuration $A.Substring(7); $WaitGiven = $true; continue }
      '^--no-wait$' { $NoWait = $true; continue }
      '^--aspect-ratio$' { $Aspect = Get-GenValue $Arguments $i; $i++; continue }
      '^--aspect-ratio=' { $Aspect = $A.Substring(15); continue }
      '^--count$' { $Count = Get-GenValue $Arguments $i; $i++; continue }
      '^--count=' { $Count = $A.Substring(8); continue }
      '^--background$' { $Background = Get-GenValue $Arguments $i; $i++; continue }
      '^--background=' { $Background = $A.Substring(13); continue }
      '^--faces$' { $Faces = Get-GenValue $Arguments $i; $i++; continue }
      '^--faces=' { $Faces = $A.Substring(8); continue }
      '^--(title|lyrics|lyrics-file|duration|prompt-influence)(=|$)' {
        $Key = $A.Substring(2)
        if ($Key.Contains("=")) { $Pair = $Key.Split("=",2); $Key = $Pair[0]; $Value = $Pair[1] }
        else { $Value = Get-GenValue $Arguments $i; $i++ }
        if ($Key -in @("title", "lyrics", "lyrics-file")) {
          if ($GenType -ne "music") { Stop-GenParam $A "music only" }
          if ($Key -eq "lyrics-file") {
            if (!(Test-Path -LiteralPath $Value -PathType Leaf)) { Stop-GenParam $A "existing UTF-8 file" }
            try { $Value = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Value).Path, (New-Object System.Text.UTF8Encoding($false, $true))) }
            catch { Stop-GenParam $A "valid UTF-8 file" }
            $Key = "lyrics"
          }
          $Value = [Convert]::ToBase64String($script:Utf8NoBom.GetBytes($Value)); $Key += "64"
        } else {
          if ($GenType -notin @("audio", "music")) { Stop-GenParam $A "audio or music only" }
          if ($Value -notmatch '^[0-9]+([.][0-9]+)?$') { Stop-GenParam $A "nonnegative decimal" }
          if ($Key -eq "prompt-influence") {
            if ($GenType -ne "audio") { Stop-GenParam $A "audio only" }
            $Key = "promptInfluence"
          }
        }
        $Media[$Key] = $Value; continue
      }
      '^--(instrumental|loop)$' {
        $Key = $A.Substring(2)
        if (($Key -eq "instrumental" -and $GenType -ne "music") -or ($Key -eq "loop" -and $GenType -ne "audio")) { Stop-GenParam $A "instrumental: music; loop: audio" }
        $Media[$Key] = "true"; continue
      }
      '^--max-energy$' { $MaxEnergy = Get-GenValue $Arguments $i; $i++; continue }
      '^--max-energy=' { $MaxEnergy = $A.Substring(13); continue }
      '^--dry-run$' { $DryRun = $true; continue }
      '^--new$' { $New = $true; continue }
      '^--force$' { $Force = $true; continue }
      '^--json$' { $script:GenJson = $true; continue }
      '^(-h|--help)$' { Show-GenUsage; Exit-Gen 0 }
      default { Stop-GenParam $A "see gen --help" "unknown-option" "unknown option $A" }
    }
  }
  Assert-GenOut
  if ($WaitGiven -and $NoWait) { Stop-GenParam "--no-wait" "either --wait <dur> or --no-wait, not both" "conflicting-options" }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { Stop-GenParam "--prompt" "non-empty text describing the $GenType" "prompt-required" }
  if ($MaxEnergy -and $MaxEnergy -notmatch '^\d+$') { Stop-GenParam "--max-energy" "a whole number" "invalid-max-energy" }
  $Extra = Get-GenTypeParams $GenType $Aspect $Count $Background $Faces
  if ($Media.Count) {
    foreach ($Kv in ($Extra -split ";" | Where-Object { $_ })) { $Pair = $Kv.Split("=", 2); $Media[$Pair[0]] = $Pair[1] }
    $Extra = (($Media.Keys | Sort-Object -CaseSensitive | ForEach-Object { "$_=$($Media[$_])" }) -join ";")
  }
  $MaxRefs = if ($GenType -eq "music") { 0 } elseif ($GenType -eq "audio") { 1 } else { 4 }
  if ($Refs.Count -gt $MaxRefs) { Stop-GenParam "--ref" "<= $MaxRefs images" }
  $CountN = 1
  if ($Count -match '^\d+$') { $CountN = [int]$Count }
  foreach ($F in $Refs) {
    if (!(Test-Path -LiteralPath $F -PathType Leaf)) { Stop-GenParam "--ref" "an existing png/jpg/webp file" "reference-not-found" "reference file not found: $F" }
    # Detect by file content (file header) rather than extension: a fake png is caught locally without uploading.
    $RefItem = Get-Item -LiteralPath $F
    if ($RefItem.Length -gt 10MB -or !(Get-GenImageKind $F)) {
      Stop-GenParam "--ref" "png,jpg,webp image content up to 10 MiB" "reference-invalid" "not a png/jpg/webp image (checked by file content) or larger than 10 MiB: $F"
    }
  }
  Assert-GenAuth
  if ($DryRun) {
    # dry-run reaches the same verdict as a real submission: when a new charge would occur and the target file exists, likewise reject with 8.
    $Fresh = Test-GenRequestFresh $GenType $Model $Prompt $New $Extra $Refs.Count
    Assert-GenNoConflict $GenType $CountN $Force $Fresh
  }
  Invoke-GenBudget $GenType $Model $DryRun $MaxEnergy $CountN $Extra $Refs.Count $Prompt.Length
  $RefIds = New-Object System.Collections.ArrayList
  foreach ($F in $Refs) {
    Write-GenProgress "step=upload-ref file=$F"
    $R = Invoke-GenApi "POST" "/api/v1/agent/gen/references" ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $F).Path)) "application/octet-stream"
    if (!$R -or !$R.refId) { Stop-Gen 1 "reference-upload-failed" "the reference image upload returned no id; report it to the user with the request-id" }
    [void]$RefIds.Add([string]$R.refId)
  }
  $script:GenFromGenerate = $true
  Invoke-GenSubmit $GenType $Model $Prompt $New $Force $Extra $CountN @($RefIds)
  if ($NoWait) {
    Add-GenResult "status" "pending"
    Add-GenResult "next" (Get-GenNextWait)
    Exit-Gen 0
  }
  Wait-GenTask $GenType $WaitS $Force
}

# Test-GenRequestFresh: whether this request would incur a new charge: no record, finished with --new, or the last same-param request failed -> new request.
# With reference images the refId cannot be predicted locally, so treat as a new request.
function Test-GenRequestFresh {
  param([string]$GenType, [string]$Model, [string]$Prompt, [bool]$New, [string]$Extra, [int]$RefCount)
  if ($RefCount -gt 0) { return $true }
  $Fields = @("builda-gen-v1", $GenType, $Model, $Prompt, "")
  if ($Extra) { $Fields += $Extra }
  $State = Read-GenJsonFile (Join-Path (Join-Path $GenDir "requests") "$(Get-GenSha256 ($Fields -join "`0")).json")
  if (!$State) { return $true }
  if (!$State.done) { return $false }
  if ($New) { return $true }
  $Rec = Read-GenJsonFile (Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask ([string]$State.taskId)) + ".json"))
  return ($Rec -and $Rec.status -eq "failed")
}

# Assert-GenNoConflict: when a new charge would occur, check target files first and reject before submitting on conflict (reporting the actual conflicting files).
function Assert-GenNoConflict {
  param([string]$GenType, [int]$Count, [bool]$Force, [bool]$Fresh)
  if (!$Fresh -or $Force) { return }
  $Hit = Get-GenOutConflict $GenType $Count
  if ($Hit) {
    Stop-Gen 8 "output-exists" "$(Format-GenArg $Hit) already exists; pass another -o, or add --force if the user agrees to overwrite (nothing was submitted or charged)"
  }
}

# Get-GenImageKind identifies png/jpg/webp by file header; returns an empty string if not an image.
function Get-GenImageKind {
  param([string]$Path)
  $Stream = [System.IO.File]::OpenRead($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  try { $Head = New-Object byte[] 12; $Read = $Stream.Read($Head, 0, 12) } finally { $Stream.Dispose() }
  if ($Read -lt 4) { return "" }
  if ($Head[0] -eq 0x89 -and $Head[1] -eq 0x50 -and $Head[2] -eq 0x4E -and $Head[3] -eq 0x47) { return "png" }
  if ($Head[0] -eq 0xFF -and $Head[1] -eq 0xD8 -and $Head[2] -eq 0xFF) { return "jpg" }
  if ($Read -ge 12 -and [System.Text.Encoding]::ASCII.GetString($Head, 0, 4) -eq "RIFF" -and [System.Text.Encoding]::ASCII.GetString($Head, 8, 4) -eq "WEBP") { return "webp" }
  return ""
}

# Assert-GenLimits validates before submitting using the limits returned by platform gen models; out-of-range prints param/allowed and exits with a parameter error.
function Assert-GenLimits {
  param($Pick, [string]$Extra, [int]$RefCount, [int]$PromptLen)
  $Lim = $Pick.limits
  if (!$Lim) { $Lim = [pscustomobject]@{} }
  $Params = @{}
  foreach ($Kv in ($Extra -split ";" | Where-Object { $_ })) { $Pair = $Kv.Split("=", 2); $Params[$Pair[0]] = $Pair[1] }
  $Bad = $null
  function Test-Range([string]$Value, $Lo, $Hi, [string]$Param) {
    $Allowed = if ($null -ne $Lo -or $null -ne $Hi) { "$Lo..$Hi" } else { "a whole number" }
    $V = 0L
    if ($Value -notmatch '^-?\d+$' -or ![long]::TryParse($Value, [ref]$V)) { return @($Param, $Allowed, "$Param $Value is not a whole number") }
    if (($null -ne $Lo -and $V -lt [long]$Lo) -or ($null -ne $Hi -and $V -gt [long]$Hi) -or $V -le 0) { return @($Param, $Allowed, "$Param $V is out of range") }
    return $null
  }
  if ($Lim.promptMaxLen -and $PromptLen -gt [long]$Lim.promptMaxLen) { $Bad = @("--prompt", "<= $($Lim.promptMaxLen) chars", "prompt is $PromptLen chars") }
  elseif ($null -ne $Lim.referenceMax -and $RefCount -gt [long]$Lim.referenceMax) { $Bad = @("--ref", "<= $($Lim.referenceMax) images", "$RefCount reference images given") }
  elseif ($Params.ContainsKey("count")) { $Bad = Test-Range $Params["count"] $Lim.countMin $Lim.countMax "--count" }
  if (!$Bad -and $Params.ContainsKey("aspectRatio") -and $Lim.aspectRatios -and ($Params["aspectRatio"] -notin @($Lim.aspectRatios))) {
    $Bad = @("--aspect-ratio", (@($Lim.aspectRatios) -join ","), "aspect ratio $($Params["aspectRatio"]) is not supported")
  }
  if (!$Bad -and $Params.ContainsKey("backgroundMode") -and $Lim.backgroundModes -and ($Params["backgroundMode"] -notin @($Lim.backgroundModes))) {
    $Bad = @("--background", (@($Lim.backgroundModes) -join ","), "background $($Params["backgroundMode"]) is not supported")
  }
  if (!$Bad -and $Params.ContainsKey("targetFaces")) { $Bad = Test-Range $Params["targetFaces"] $Lim.targetFacesMin $Lim.targetFacesMax "--faces" }
  if (!$Bad -and $Params["backgroundMode"] -eq "transparent" -and [System.IO.Path]::GetExtension($script:GenOutArg).ToLowerInvariant() -in @(".jpg", ".jpeg")) {
    $Bad = @("-o", ".png, .webp or a directory", "jpg cannot store a transparent background")
  }
  foreach ($Key in @("lyrics", "title")) {
    if ($Params.ContainsKey($Key + "64")) {
      $Text = $script:Utf8NoBom.GetString([Convert]::FromBase64String($Params[$Key + "64"]))
      $Limit = $Lim.($Key + "MaxLen")
      if ($Limit -and $Text.Length -gt $Limit) { $Bad = @("--$Key", "<= $Limit chars", "text is too long") }
      if ($Key -eq "lyrics" -and ![string]::IsNullOrWhiteSpace($Text) -and $Params["instrumental"] -eq "true") { $Bad = @("--lyrics", "empty with --instrumental", "instrumental music cannot have lyrics") }
    }
  }
  foreach ($Key in @("duration", "promptInfluence")) {
    if (!$Params.ContainsKey($Key)) { continue }
    $V = [double]::Parse($Params[$Key], [Globalization.CultureInfo]::InvariantCulture)
    $Lo = if ($Key -eq "duration") { $Lim.targetDurationMinSec } else { 0 }
    $Hi = if ($Key -eq "duration") { $Lim.targetDurationMaxSec } else { 1 }
    $Flag = if ($Key -eq "duration") { "--duration" } else { "--prompt-influence" }
    if ([double]::IsInfinity($V) -or [double]::IsNaN($V)) { $Bad = @($Flag, "finite number", "invalid number") }
    elseif ($Key -eq "duration" -and !$Hi) { $Bad = @($Flag, "model with target duration support", "unsupported parameter") }
    elseif (!($Key -eq "duration" -and $V -eq 0) -and ($V -lt $Lo -or $V -gt $Hi)) { $Bad = @($Flag, "$Lo..$Hi", "out of range") }
    elseif ($Key -eq "duration" -and $Pick.model -eq "lyria-3.5" -and $V -ne [Math]::Floor($V)) { $Bad = @($Flag, "whole seconds", "FlowMusic requires integer duration") }
  }
  if ($Params.ContainsKey("loop") -and !$Lim.supportsLoop) { $Bad = @("--loop", "supported model", "unsupported parameter") }
  if ($Params.ContainsKey("promptInfluence") -and !$Lim.supportsPromptInfluence) { $Bad = @("--prompt-influence", "supported model", "unsupported parameter") }
  if ($Pick.model -eq "seed-audio-1.0" -and $Params.ContainsKey("count")) { $Bad = @("--count", "model with count support", "unsupported parameter") }
  if ($Bad) {
    Add-GenResult "message" $Bad[2]
    Stop-GenParam $Bad[0] $Bad[1]
  }
}

function Invoke-GenBudget {
  param([string]$GenType, [string]$Model, [bool]$DryRun, [string]$MaxEnergy, [int]$Count = 1, [string]$Extra = "", [int]$RefCount = 0, [int]$PromptLen = 0)
  # Before every generation, validate locally against platform limits: dry-run and real submission reach the same verdict, and out-of-range params never get submitted.
  # dry-run reports the balance first: even if the model is not available, the agent learns both "not available" and "balance" in one go.
  $BalanceValue = 0L
  if ($DryRun) {
    $Balance = Invoke-GenApi "GET" "/api/v1/agent/gen/balance"
    $BalanceValue = if ($null -ne $Balance.energy) { [long]$Balance.energy } else { 0L }
    Add-GenResult "energy-balance" ([string]$BalanceValue)
  }
  $Models = Invoke-GenApi "GET" "/api/v1/agent/gen/models?genType=$GenType"
  $TypeModels = @()
  foreach ($G in @($Models.groups)) { if ($G.genType -eq $GenType) { $TypeModels = @($G.models | Where-Object { $_ }) } }
  if ($TypeModels.Count -eq 0) {
    Add-GenResult "message" "genType not open: no $GenType model is available for this account yet (same as submit error 140101)"
    Stop-Gen 1 "not-available" "the platform has not opened $GenType generation for this account yet" "$GenCli gen models"
  }
  $Pick = $null
  if ($Model) {
    $Pick = $TypeModels | Where-Object { $_.model -eq $Model } | Select-Object -First 1
    # Model name misspelled or a model of another type used: report as a parameter error so the agent does not think the platform has not enabled it.
    if (!$Pick) {
      Add-GenResult "message" "model $Model is not available for $GenType"
      Stop-GenParam "--model" (@($TypeModels | ForEach-Object { $_.model }) -join ",")
    }
  } else {
    $Pick = $TypeModels | Where-Object { $_.isDefault } | Select-Object -First 1
    if (!$Pick) { $Pick = $TypeModels[0] }
  }
  if ($GenType -in @("music", "audio") -and $RefCount -gt [int]$Pick.limits.referenceMax) { Stop-GenParam "--ref" "<= $([int]$Pick.limits.referenceMax) images" }
  Assert-GenLimits $Pick $Extra $RefCount $PromptLen
  $Est = if ($Pick.estimatedMax) { [long]$Pick.estimatedMax } elseif ($Pick.pricing.maxCost) { [long]$Pick.pricing.maxCost } else { [long]$Pick.pricing.unitCost }
  if ($GenType -in @("image", "audio", "music") -and $Pick.pricing.mode -in @("count", "second") -and $Pick.pricing.unitCost) {
    $Unit = if ($Pick.pricing.unitCount) { [long]$Pick.pricing.unitCount } else { 1L }
    $Units = $Count
    if ($Pick.pricing.mode -eq "second") {
      $DurationLimit = if ($Pick.limits.maxDurationSec) { [long]$Pick.limits.maxDurationSec } else { 1L }
      $Units *= $DurationLimit
    }
    $Est = [long][Math]::Ceiling(([long]$Pick.pricing.unitCost * $Units) / $Unit)
    $Est = [Math]::Max($Est, [long]$Pick.pricing.minCost)
    if ($Pick.pricing.maxCost) { $Est = [Math]::Min($Est, [long]$Pick.pricing.maxCost) }
  }
  if (!$DryRun -and !$MaxEnergy) { return }
  if ($DryRun) {
    Add-GenResult "model" ([string]$Pick.model)
    Add-GenResult "energy-estimate" ([string]$Est)
    Add-GenResult "status" "dry-run"
    if ($MaxEnergy -and $Est -gt [long]$MaxEnergy) {
      Stop-Gen 4 "over-budget" "the estimate exceeds --max-energy $MaxEnergy; ask the user before raising it"
    }
    if ($BalanceValue -lt $Est) {
      Add-GenResult "energy-topup" $GenTopupHint
      Stop-Gen 4 "insufficient-energy" "the balance is below this estimate; relay the energy-topup steps to the user without changing them before generating"
    }
    Exit-Gen 0
  }
  if ($Est -gt [long]$MaxEnergy) {
    Add-GenResult "energy-estimate" ([string]$Est)
    Stop-Gen 4 "over-budget" "the estimate exceeds --max-energy $MaxEnergy; ask the user before raising it"
  }
}

function Invoke-GenSubmit {
  param([string]$GenType, [string]$Model, [string]$Prompt, [bool]$New, [bool]$Force, [string]$Extra, [int]$Count, [string[]]$RefIds)
  # Derivation rules byte-identical to the Unix CLI: NUL-separated plain strings; type-specific params appended only when non-empty (audio consistent with 0.4.74).
  $Fields = @("builda-gen-v1", $GenType, $Model, $Prompt, ($RefIds -join ","))
  if ($Extra) { $Fields += $Extra }
  $BaseId = Get-GenSha256 ($Fields -join "`0")
  $StatePath = Join-Path (Join-Path $GenDir "requests") "$BaseId.json"
  $State = Read-GenJsonFile $StatePath
  $Nonce = ""; $Done = $false; $PrevTask = ""; $Reused = $false; $Fresh = !$State
  if ($State) { $Nonce = [string]$State.nonce; $Done = [bool]$State.done; $PrevTask = [string]$State.taskId }
  $PrevFailed = $false
  if ($State -and $Done) {
    $PrevRec = Read-GenJsonFile (Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask $PrevTask) + ".json"))
    $PrevFailed = [bool]($PrevRec -and $PrevRec.status -eq "failed")
  }
  if (($New -or $PrevFailed) -and (!$State -or $Done)) {
    # --new, or the last same-param request failed (failures are not charged): derive a new nonce and resubmit instead of reusing the failed result.
    $Nonce = [System.Guid]::NewGuid().ToString("N")
    $Done = $false
    $Fresh = $true
    if ($PrevFailed) { Add-GenResult "hint" "the previous identical request failed (not charged); submitted it again as a new generation" }
  } elseif ($State -and $New) {
    # A same-param request is still in progress: --new has no effect; resume the original task and say so explicitly.
    Add-GenResult "new-ignored" "yes"
    Add-GenResult "hint" "the identical earlier request (task $PrevTask) is still running, so --new was not applied and this run continues it; run --new again after it finishes for another take"
    Write-GenProgress "--new ignored: the identical earlier request is still running"
  } elseif ($State) {
    $Reused = $true
  }
  $RequestId = Get-GenSha256 ("builda-gen-req-v1`0$BaseId`0$Nonce")
  $Params = [ordered]@{ prompt = $Prompt }
  foreach ($Kv in ($Extra -split ";" | Where-Object { $_ })) {
    $Pair = $Kv.Split("=", 2)
    $Key = $Pair[0]; $Value = $Pair[1]
    if ($Key -in @("lyrics64", "title64")) { $Params[$Key.Substring(0, $Key.Length - 2)] = $script:Utf8NoBom.GetString([Convert]::FromBase64String($Value)) }
    elseif ($Key -in @("duration", "promptInfluence")) { $Params[$Key] = [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture) }
    elseif ($Key -in @("instrumental", "loop")) { $Params[$Key] = $Value -eq "true" }
    else { $Params[$Key] = if ($Key -in @("count", "targetFaces")) { [int]$Value } else { $Value } }
  }
  if ($RefIds.Count -gt 0) { $Params["referenceIds"] = @($RefIds) }
  $Body = [ordered]@{ requestId = $RequestId; genType = $GenType }
  if ($Model) { $Body["model"] = $Model }
  $Body[$GenType] = $Params
  # Requests that would incur a new charge check target files first: reject before submitting on conflict; never charge first and then report the file exists.
  Assert-GenNoConflict $GenType $Count $Force $Fresh
  Write-GenProgress "step=submit type=$GenType"
  $Resp = Invoke-GenApi "POST" "/api/v1/agent/gen/tasks" (Get-GenJsonBytes $Body)
  if (!$Resp -or !$Resp.taskId) { Stop-Gen 1 "submit-failed" "the platform returned no task id; report it to the user with the request-id" }
  $Resubmitted = $false
  if ($Resp.status -eq "failed" -and !$New) {
    # The platform replayed a failed same-param task (when the local ledger is missing): failures are not charged; automatically resubmit once with a new nonce.
    Add-GenResult "hint" "the platform returned an earlier failed attempt of this request (not charged); submitted it again as a new generation"
    $Nonce = [System.Guid]::NewGuid().ToString("N")
    $Body["requestId"] = Get-GenSha256 ("builda-gen-req-v1`0$BaseId`0$Nonce")
    $Resp = Invoke-GenApi "POST" "/api/v1/agent/gen/tasks" (Get-GenJsonBytes $Body)
    if (!$Resp -or !$Resp.taskId) { Stop-Gen 1 "submit-failed" "the platform returned no task id; report it to the user with the request-id" }
    $Fresh = $true
    $Resubmitted = $true
  }
  $script:GenTaskId = [string]$Resp.taskId
  Write-GenJsonFile $StatePath ([ordered]@{ nonce = $Nonce; done = $Done; taskId = $script:GenTaskId; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
  $Status = if ($Resp.status) { [string]$Resp.status } else { "pending" }
  Update-GenLedgerTask $script:GenTaskId @{ genType = $GenType; model = $Model; prompt = $Prompt; out = $script:GenOutArg; status = $Status; params = $Extra }
  Add-GenResult "task" $script:GenTaskId
  if ($Fresh -and ($New -or $PrevFailed -or $Resubmitted)) {
    # new-generation=yes: a new generation was submitted; charged only on success, not on failure or moderation rejection.
    Write-GenProgress "submitted as a new generation; it is charged only if it succeeds"
    Add-GenResult "new-generation" "yes"
  }
  $script:GenSubmitStatus = $Status
  if ($Reused -and $PrevTask -eq $script:GenTaskId) {
    Add-GenResult "reused" "yes"
    $script:GenReusedEmitted = $true
    Write-GenProgress "same request as before: using task $script:GenTaskId (no new charge)"
  }
  $Est = if ($null -ne $Resp.estimatedEnergy) { [string]$Resp.estimatedEnergy } else { "0" }
  Add-GenResult "energy-estimate" $Est
}

# Wait-GenTask polls with a cap; done -> download; failed -> 5; timeout -> 6. On Ctrl-C, finally prints the resume-wait command.
function Wait-GenTask {
  param([string]$GenType, [int]$WaitS, [bool]$Force)
  $Start = Get-Date
  $Interval = 2; $MaxInterval = 5
  if ($GenType -eq "model3d") { $Interval = 5; $MaxInterval = 30 }
  $LastBeat = Get-Date
  $Finished = $false
  try {
    while ($true) {
      $Task = Invoke-GenApi "GET" "/api/v1/agent/gen/tasks/$script:GenTaskId"
      $Status = [string]$Task.status
      if ($Status -eq "done") { $Finished = $true; Complete-GenTask $GenType $Task $Force }
      if ($Status -eq "failed") { $Finished = $true; Stop-GenFailedTask $Task }
      $Elapsed = [int]((Get-Date) - $Start).TotalSeconds
      if ($Elapsed -ge $WaitS) {
        $Finished = $true
        Update-GenLedgerTask $script:GenTaskId @{ status = "running" }
        Add-GenResult "status" "running"
        Add-GenResult "hint" "still generating; run next to keep waiting (no new charge)"
        Add-GenResult "next" (Get-GenNextWait)
        Exit-Gen 6
      }
      if (((Get-Date) - $LastBeat).TotalSeconds -ge 30) {
        Write-GenProgress "status=$Status elapsed=${Elapsed}s"
        $LastBeat = Get-Date
      }
      Start-Sleep -Seconds $Interval
      $Interval = [Math]::Min($MaxInterval, [int]($Interval * 3 / 2))
    }
  } finally {
    if (!$Finished) {
      Write-GenProgress "interrupted: only the local wait stopped; the task keeps running and is charged if it succeeds"
      Write-GenProgress "next=$(Get-GenNextWait)"
    }
  }
}

function Stop-GenFailedTask {
  param($Task)
  $Code = if ($Task.failCode) { [string]$Task.failCode } else { "unknown" }
  Update-GenLedgerTask $script:GenTaskId @{ status = "failed"; energyCost = 0 }
  Set-GenRequestDone $script:GenTaskId
  Add-GenResult "status" "failed"
  Add-GenResult "fail-code" $Code
  if ($Task.failReason) { Add-GenResult "fail-reason" ([string]$Task.failReason) }
  Add-GenResult "energy-cost" "0"
  if ($Code -eq "content_violation") {
    Stop-Gen 5 "content-rejected" "rewrite the prompt without sensitive content and run again (a changed prompt is a new request); if it fails again, ask the user"
  }
  Stop-Gen 5 "task-failed" "no Credits were charged; running the same command again submits a fresh attempt automatically; if it fails again, report to the user (it may also be a content rejection the platform did not label)"
}

function Get-GenOutputPlan {
  param($Task, [string]$GenType)
  $Out = $script:GenOutArg
  if (!$Out) { $Out = "builda-gen/$GenType/" }
  $AsDir = $Out.EndsWith("/") -or $Out.EndsWith("\") -or (Test-Path -LiteralPath $Out -PathType Container)
  $Short = [regex]::Replace($script:GenTaskId, '[^A-Za-z0-9]', '')
  $Short = if ($Short.Length -gt 8) { $Short.Substring($Short.Length - 8).ToLowerInvariant() } elseif ($Short) { $Short.ToLowerInvariant() } else { "task" }
  $Out = [regex]::Replace($Out, '(^|[\\/])\.(?=[\\/])', '$1')
  $BasePath = ""; $Ext = ""
  if (!$AsDir) {
    $Ext = [System.IO.Path]::GetExtension($Out)
    $BasePath = if ($Ext) { $Out.Substring(0, $Out.Length - $Ext.Length) } else { $Out }
  }
  $Plan = New-Object System.Collections.ArrayList
  $Index = 0
  $FirstKind = ""
  foreach ($O in @($Task.outputs)) { if ($O -and $O.url) { $FirstKind = [regex]::Replace(([string]$O.kind).ToLowerInvariant(), '[^a-z0-9]', ''); break } }
  foreach ($O in @($Task.outputs)) {
    if (!$O -or !$O.url) { continue }
    $Fmt = if ($O.format) { ([string]$O.format).ToLowerInvariant() } else { ([System.IO.Path]::GetExtension(([string]$O.url).Split("?")[0])).TrimStart(".").ToLowerInvariant() }
    if (!$Fmt) { $Fmt = "bin" }
    $Kind = [regex]::Replace(([string]$O.kind).ToLowerInvariant(), '[^a-z0-9]', '')
    # Same-kind outputs (multiple images) by index, different-kind outputs (3D preview image) by kind: hero.png/hero-2.png, chest.glb/chest-preview.png
    $Suffix = if ($Index -eq 0) { "" } elseif ($Kind -and $Kind -ne $FirstKind) { "-$Kind" } else { "-$($Index + 1)" }
    if ($AsDir) {
      $Dest = Join-Path $Out "$GenType-$Short$Suffix.$Fmt"
    } else {
      $Dest = "$BasePath$Suffix.$Fmt"
    }
    $Dims = if ($O.width -and $O.height) { "$($O.width)x$($O.height)" } else { "" }
    [void]$Plan.Add(@{ Url = [string]$O.url; Md5 = ([string]$O.md5).ToLowerInvariant(); Dest = $Dest; Dims = $Dims })
    $Index++
  }
  return ,$Plan
}

function Complete-GenTask {
  param([string]$GenType, $Task, [bool]$Force)
  # The task is done and settled on the platform: record the ledger and report cost first, then handle the local download.
  $Cost = if ($null -ne $Task.energyCost) { [long]$Task.energyCost } else { 0 }
  $PriorRecord = Read-GenJsonFile (Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask $script:GenTaskId) + ".json"))
  $Prior = if ($PriorRecord) { [string]$PriorRecord.status } else { "" }
  Update-GenLedgerTask $script:GenTaskId @{ status = "done"; energyCost = $Cost; model = [string]$Task.model }
  Set-GenRequestDone $script:GenTaskId
  Add-GenResult "status" "done"
  # This delivery is a previously completed task (local ledger or platform replay shows done): explicitly mark it as an old result and when it was generated.
  $Earlier = ($Prior -eq "done") -or ($script:GenSubmitStatus -eq "done")
  $Created = ""
  if ($Earlier) {
    $Ts = if ($Task.createAt) { [long]$Task.createAt } elseif ($PriorRecord -and $PriorRecord.createdAt) { [long]$PriorRecord.createdAt * 1000 } else { 0L }
    if ($Ts -gt 0) {
      if ($Ts -lt 100000000000) { $Ts = $Ts * 1000 }
      $Created = [DateTimeOffset]::FromUnixTimeMilliseconds($Ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
    }
    if (!$script:GenReusedEmitted) { Add-GenResult "reused" "yes" }
    if ($Created) { Add-GenResult "reused-from" $Created }
  }
  if ($Earlier) {
    # The task was already completed and settled: this run is only a reuse/re-download, cost for this run is 0, and the original task's cost is given separately.
    Add-GenResult "energy-cost" "0"
    Add-GenResult "task-energy-cost" ([string]$Cost)
  } else {
    Add-GenResult "energy-cost" ([string]$Cost)
  }
  $Plan = Get-GenOutputPlan $Task $GenType
  if ($Plan.Count -eq 0) { Stop-Gen 7 "no-output" "the task finished without files" "$GenCli gen status $script:GenTaskId" }
  $Files = New-Object System.Collections.ArrayList
  foreach ($Item in $Plan) {
    [void]$Files.Add((Save-GenOutput $Item.Url $Item.Md5 $Item.Dest $Force $Item.Dims))
  }
  Update-GenLedgerTask $script:GenTaskId @{ files = @($Files) }
  if (!$Task.energySettled) { Add-GenResult "energy-settled" "no" }
  try {
    $B = Invoke-BuildaAuthenticatedRequest -Method "GET" -Uri "$Base/api/v1/agent/gen/balance" -AllowHttpFailure
    if ($B.IsSuccess) {
      $Left = [string](([string]$B.Body | ConvertFrom-Json).energy)
      Add-GenResult "energy-balance" $Left
      if (!$Left -or $Left -eq "0") { Add-GenResult "energy-topup" $GenTopupHint }
    }
  } catch {}
  if ($Earlier -and $script:GenFromGenerate) {
    # After the platform fixes an issue, the same request still hits the old task: use hint to state clearly that this is an old result (next= holds only commands, not explanations).
    $When = if ($Created) { $Created } else { "an earlier time" }
    Add-GenResult "hint" "this is the earlier result generated at $When (no new charge); tell the user it is not a new generation, and if they want a fresh one, rerun with --new (charged)"
  }
  Exit-Gen 0
}

# Save-GenOutput writes atomically: same-dir .part -> md5 check -> replace; an existing file with identical content counts as success. CDN downloads carry no auth header.
function Save-GenOutput {
  param([string]$Url, [string]$Md5, [string]$Dest, [bool]$Force, [string]$Dims = "")
  if (Test-Path -LiteralPath $Dest -PathType Leaf) {
    if ($Md5 -and (Get-GenFileMd5 $Dest) -eq $Md5) {
      Add-GenResult "file" $Dest
      Add-GenResult "md5" $Md5
      if ($Dims) { Add-GenResult "dimensions" $Dims }
      Write-GenRenameNote $Dest
      return $Dest
    }
    if (!$Force) { Stop-Gen 8 "output-exists" "$Dest already exists with different content; pass another -o or add --force" }
  }
  $Dir = Split-Path -Parent $Dest
  if (!$Dir) { $Dir = "." }
  # Local write problems (dir cannot be created, read-only) are reported separately as write-failed: re-downloading will not fix them, so the agent must not be led into a retry loop.
  try { New-Item -ItemType Directory -Force -Path $Dir -ErrorAction Stop | Out-Null } catch {
    Stop-Gen 1 "write-failed" "cannot create directory $Dir (check the path and permissions); the task is done and will not be charged again: fix the path, then run gen download $script:GenTaskId -o <a writable path>"
  }
  $Part = Join-Path $Dir (".{0}.part" -f (Split-Path -Leaf $Dest))
  # Before downloading, confirm the dir is writable: a read-only dir reports write-failed and must not masquerade as a retryable download failure.
  try { [System.IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Part), [byte[]]@()) } catch {
    Stop-Gen 1 "write-failed" "cannot write into $Dir (read-only); the task is done and will not be charged again: fix the permissions, then run gen download $script:GenTaskId -o <a writable path>"
  }
  Write-GenProgress "step=download file=$Dest"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Part | Out-Null
  } catch {
    Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
    if ($_.Exception -is [System.IO.IOException] -or $_.Exception -is [System.UnauthorizedAccessException]) {
      Stop-Gen 1 "write-failed" "cannot write into $Dir (read-only or disk full); the task is done and will not be charged again: fix the path or permissions, then run gen download $script:GenTaskId -o <a writable path>"
    }
    Stop-Gen 7 "download-failed" "the download failed; the task is done and is not charged again" "$GenCli gen download $script:GenTaskId -o $(Format-GenArg $Dest)"
  }
  $Got = Get-GenFileMd5 $Part
  if ($Md5 -and $Got -ne $Md5) {
    Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
    Stop-Gen 7 "checksum-mismatch" "the downloaded file failed its checksum; download it again" "$GenCli gen download $script:GenTaskId -o $(Format-GenArg $Dest)"
  }
  # The extension follows the file content: correct it when the platform's format metadata does not match (engines may decode by extension).
  $Planned = [System.IO.Path]::GetExtension($Dest).TrimStart(".").ToLowerInvariant()
  $Real = Get-GenSniffedExt $Part $Planned
  if ($Real -ne $Planned) {
    $Dest = $Dest.Substring(0, $Dest.Length - $Planned.Length) + $Real
    if ((Test-Path -LiteralPath $Dest -PathType Leaf) -and (Get-GenFileMd5 $Dest) -ne $Got -and !$Force) {
      Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
      Stop-Gen 8 "output-exists" "$Dest already exists with different content; pass another -o or add --force"
    }
  }
  Move-Item -Force -LiteralPath $Part -Destination $Dest
  Add-GenResult "file" $Dest
  Add-GenResult "md5" $Got
  if ($Dims) { Add-GenResult "dimensions" $Dims }
  Write-GenRenameNote $Dest
  return $Dest
}

# Write-GenRenameNote: explicitly tell the user when the actual file extension differs from what -o requested (corrected by content or platform format), so code does not hardcode a wrong file name.
function Write-GenRenameNote {
  param([string]$Final)
  if ($script:GenRenameNoted) { return }
  $Out = $script:GenOutArg
  if (!$Out -or $Out.EndsWith("/") -or $Out.EndsWith("\") -or (Test-Path -LiteralPath $Out -PathType Container)) { return }
  $Want = [System.IO.Path]::GetExtension($Out).TrimStart(".").ToLowerInvariant()
  if (!$Want -or $Want -eq [System.IO.Path]::GetExtension($Final).TrimStart(".").ToLowerInvariant()) { return }
  $script:GenRenameNoted = $true
  Add-GenResult "requested-file" $Out
  Write-GenProgress "warning: saved as $Final instead of $Out to match the real file format"
}

# Get-GenSniffedExt corrects extensions only among image formats by file header (the platform once labeled PNG as jpg).
function Get-GenSniffedExt {
  param([string]$Path, [string]$Planned)
  if ($Planned -notin @("png", "jpg", "jpeg", "webp")) { return $Planned }
  $Stream = [System.IO.File]::OpenRead($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  try { $Head = New-Object byte[] 12; [void]$Stream.Read($Head, 0, 12) } finally { $Stream.Dispose() }
  $Real = ""
  if ($Head[0] -eq 0x89 -and $Head[1] -eq 0x50 -and $Head[2] -eq 0x4E -and $Head[3] -eq 0x47) { $Real = "png" }
  elseif ($Head[0] -eq 0xFF -and $Head[1] -eq 0xD8 -and $Head[2] -eq 0xFF) { $Real = "jpg" }
  elseif ([System.Text.Encoding]::ASCII.GetString($Head, 0, 4) -eq "RIFF" -and [System.Text.Encoding]::ASCII.GetString($Head, 8, 4) -eq "WEBP") { $Real = "webp" }
  if (!$Real -or $Real -eq $Planned -or ($Planned -eq "jpeg" -and $Real -eq "jpg")) { return $Planned }
  return $Real
}

function Invoke-GenTaskCommand {
  param([string]$Sub, [string[]]$Arguments)
  $WaitS = $GenDefaultWait; $Force = $false
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $A = $Arguments[$i]
    switch -Regex ($A) {
      '^(-o|--out)$' { $script:GenOutArg = Get-GenValue $Arguments $i; $i++; continue }
      '^--out=' { $script:GenOutArg = $A.Substring(6); continue }
      '^--wait$' { $WaitS = ConvertFrom-GenDuration (Get-GenValue $Arguments $i); $i++; continue }
      '^--wait=' { $WaitS = ConvertFrom-GenDuration $A.Substring(7); continue }
      '^--force$' { $Force = $true; continue }
      '^--json$' { $script:GenJson = $true; continue }
      '^(-h|--help)$' { Show-GenUsage; Exit-Gen 0 }
      '^-' { Stop-GenParam $A "see gen --help" "unknown-option" "unknown option $A" }
      default {
        if ($script:GenTaskId) { Stop-GenParam "task" "a single task id" "unexpected-argument" }
        $script:GenTaskId = $A
      }
    }
  }
  if (!$script:GenTaskId) { Stop-Gen 2 "task-required" "pass the task id" "$GenCli gen list" }
  if ($script:GenTaskId -notmatch '^[A-Za-z0-9_:.-]{1,128}$') { Stop-Gen 2 "invalid-task-id" "task ids look like the task= value printed when generating" "$GenCli gen list" }
  Assert-GenOut
  if (!$script:GenOutArg) { $script:GenOutArg = Get-GenLedgerOut $script:GenTaskId }
  Assert-GenAuth
  Add-GenResult "task" $script:GenTaskId
  $Task = Invoke-GenApi "GET" "/api/v1/agent/gen/tasks/$script:GenTaskId"
  $GenType = if ($Task.genType) { [string]$Task.genType } else { "audio" }
  switch ($Sub) {
    "wait" { Wait-GenTask $GenType $WaitS $Force }
    "download" {
      if ($Task.status -eq "done") { Complete-GenTask $GenType $Task $Force }
      if ($Task.status -eq "failed") { Stop-GenFailedTask $Task }
      Add-GenResult "status" "running"
      Stop-Gen 6 "not-finished" "the task is still generating" (Get-GenNextWait)
    }
    "status" {
      $St = if ($Task.status -eq "processing") { "running" } else { [string]$Task.status }
      Add-GenResult "status" $St
      Add-GenResult "type" $GenType
      Add-GenResult "model" ([string]$Task.model)
      $LedgerRecord = Read-GenJsonFile (Join-Path (Join-Path $GenDir "tasks") ((ConvertTo-GenSafeTask $script:GenTaskId) + ".json"))
      if ($LedgerRecord -and $LedgerRecord.params) { Add-GenResult "params" ([string]$LedgerRecord.params) }
      Add-GenResult "energy-estimate" ([string]$Task.estimatedEnergy)
      # An in-progress task is not settled yet: do not output energy-cost, so it is not read as "free".
      if ($St -in @("done", "failed")) { Add-GenResult "energy-cost" ([string]$Task.energyCost) }
      if ($Task.failCode) { Add-GenResult "fail-code" ([string]$Task.failCode) }
      if ($Task.failReason) { Add-GenResult "fail-reason" ([string]$Task.failReason) }
      Exit-Gen 0
    }
  }
}

function Invoke-GenInfoCommand {
  param([string]$Sub, [string[]]$Arguments)
  $Limit = "20"; $Type = ""; $GenType = ""
  for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $A = $Arguments[$i]
    $Opt = $A.Split("=", 2)[0]
    # Each subcommand accepts only its own options; unrelated options error out instead of being silently ignored.
    if ($Opt -eq "--json") { $script:GenJson = $true; continue }
    if ($Opt -in @("-h", "--help")) { Show-GenUsage; Exit-Gen 0 }
    if ($Opt -eq "--limit" -and $Sub -in @("list", "usage")) {
      if ($A -eq $Opt) { $Limit = Get-GenValue $Arguments $i; $i++ } else { $Limit = $A.Substring(8) }
      continue
    }
    if ($Opt -eq "--type" -and $Sub -eq "usage") {
      if ($A -eq $Opt) { $Type = Get-GenValue $Arguments $i; $i++ } else { $Type = $A.Substring(7) }
      continue
    }
    if ($A.StartsWith("-")) { Stop-GenParam $A "see gen --help" "unknown-option" "$A is not an option of gen $Sub" }
    if ($Sub -in @("list", "models")) {
      if ($A -notin @("audio", "music", "image", "model3d")) { Stop-GenParam "type" "audio,music,image,model3d" "invalid-type" "unknown generation type: $A" }
      $GenType = $A
      continue
    }
    Stop-GenParam $A "see gen --help" "unexpected-argument" "gen $Sub takes no argument $A"
  }
  if ($Limit -notmatch '^[1-9]\d*$') { Stop-GenParam "--limit" "a positive whole number" "invalid-limit" }
  if ($Sub -eq "usage") {
    if ([int]$Limit -gt 50) { Stop-GenParam "--limit" "1..50" "invalid-limit" }
    if ($Type -and $Type -notin @("all", "income", "expense")) { Stop-GenParam "--type" "all,income,expense" "invalid-type" }
  }
  if ($Sub -eq "list") { Write-GenLedgerList ([int]$Limit) $GenType; exit 0 }
  Assert-GenAuth
  switch ($Sub) {
    "balance" {
      $B = Invoke-GenApi "GET" "/api/v1/agent/gen/balance"
      Add-GenResult "energy-balance" ([string]$B.energy)
      if (!$B.energy -or [long]$B.energy -le 0) { Add-GenResult "energy-topup" $GenTopupHint }
      Add-GenResult "energy-total-income" ([string]$B.totalIncome)
      Add-GenResult "energy-total-expend" ([string]$B.totalExpend)
      Exit-Gen 0
    }
    "models" {
      $M = Invoke-GenApi "GET" "/api/v1/agent/gen/models?genType=$GenType"
      if ($script:GenJson) { Write-Host ($M | ConvertTo-Json -Depth 8 -Compress); exit 0 }
      if (@($M.groups).Count -eq 0) {
        Write-Host "models=0"
        Write-Host "reason=the platform has not opened any generation type for this account yet (not a CLI or configuration error on your side)"
      }
      foreach ($G in @($M.groups)) {
        foreach ($X in @($G.models)) {
          $Default = if ($X.isDefault) { "yes" } else { "no" }
          $Unit = if ($X.pricing.unitCount) { $X.pricing.unitCount } else { 1 }
          $Limits = if ($X.limits) { (@($X.limits.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ",") } else { "" }
          $Support = if ($G.genType -in @("audio", "music", "image", "model3d")) { "yes" } else { "no" }
          Write-Host ("type={0} cli-support={9} model={1} default={2} price={3}/{4}{5} max-cost={6} name={7} limits={8}" -f $G.genType, $X.model, $Default, $X.pricing.unitCost, $Unit, $X.pricing.mode, $(if ($X.estimatedMax) { $X.estimatedMax } else { $X.pricing.maxCost }), ($X.displayName | ConvertTo-Json -Compress), $Limits, $Support)
        }
      }
      exit 0
    }
    "usage" {
      $U = Invoke-GenApi "GET" "/api/v1/agent/gen/transactions?size=$Limit&type=$Type"
      if ($script:GenJson) { Write-Host ($U | ConvertTo-Json -Depth 8 -Compress); exit 0 }
      if (@($U.list).Count -eq 0) { Write-Host "transactions=0" }
      foreach ($T in @($U.list)) {
        $Ms = [long]$T.createAt
        $When = if ($Ms -gt 100000000000) { [DateTimeOffset]::FromUnixTimeMilliseconds($Ms) } else { [DateTimeOffset]::FromUnixTimeSeconds($Ms) }
        $TaskText = if ($T.taskId) { $T.taskId } else { "-" }
        $TypeText = if ($T.genType) { $T.genType } else { "-" }
        # source distinguishes whether this transaction was initiated by Builda (generation API caller=platform); consumption by the same account in the App is marked app/other.
        $Source = if ($T.caller -eq "platform") { "builda" } elseif ($T.caller) { $T.caller } else { "app/other" }
        Write-Host ("time={0} change={1} balance-after={2} source={6} type={3} task={4} reason={5}" -f $When.ToLocalTime().ToString("yyyy-MM-dd HH:mm"), $T.change, $T.balanceAfter, $TypeText, $TaskText, ($T.reason | ConvertTo-Json -Compress), $Source)
      }
      $More = if ($U.noMore -eq $false) { "yes" } else { "no" }
      Write-Host "more=$More"
      exit 0
    }
  }
}

function Write-GenLedgerList {
  param([int]$Limit, [string]$GenType = "")
  $Dir = Join-Path $GenDir "tasks"
  $Records = @()
  if (Test-Path -LiteralPath $Dir) {
    $Records = @(Get-ChildItem -LiteralPath $Dir -Filter "*.json" | ForEach-Object { Read-GenJsonFile $_.FullName } | Where-Object { $_ -and (!$GenType -or $_.genType -eq $GenType) } | Sort-Object -Property createdAt -Descending | Select-Object -First $Limit)
  }
  if ($script:GenJson) {
    $Items = @($Records | ForEach-Object {
      $Row = [ordered]@{}
      foreach ($P in $_.PSObject.Properties) { $Row[$P.Name] = if ($P.Name -eq "params" -and $P.Value -is [string]) { ConvertTo-GenParamsObject $P.Value } else { $P.Value } }
      $Row
    })
    Write-Host (ConvertTo-Json -InputObject @($Items) -Depth 6 -Compress)
    return
  }
  if ($Records.Count -eq 0) { Write-Host "tasks=0"; return }
  foreach ($R in $Records) {
    $P = ([string]$R.prompt).Replace("`n", " ")
    if ($P.Length -gt 60) { $P = $P.Substring(0, 60) + "…" }
    $ModelText = if ($R.model) { $R.model } else { "-" }
    $ParamsText = if ($R.params) { " params=$($R.params)" } else { "" }
    Write-Host ("task={0} type={1} model={6} status={2} energy-cost={3}{7} files={4} prompt={5}" -f $R.taskId, $R.genType, $R.status, $R.energyCost, (@($R.files) -join ","), ($P | ConvertTo-Json -Compress), $ModelText, $ParamsText)
  }
}

function Invoke-Gen {
  param([string[]]$Arguments)
  $Sub = if ($Arguments.Count -gt 0) { $Arguments[0] } else { "" }
  # --json takes effect before parsing any argument: parameter errors also output JSON, regardless of argument order.
  if ($Arguments -contains "--json") { $script:GenJson = $true }
  [string[]]$Tail = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
  switch ($Sub) {
    { $_ -in @("audio", "music", "image", "model3d") } { $script:GenIsGenerate = $true; Invoke-GenGenerate $Sub $Tail }
    { $_ -in @("speech", "video") } { Stop-Gen 1 "not-supported-by-cli" "this toolchain version cannot generate $Sub yet; update the toolchain, and if it is still unsupported the capability has not been released" "$GenCli check" }
    { $_ -in @("wait", "status", "download") } { Invoke-GenTaskCommand $Sub $Tail }
    { $_ -in @("list", "balance", "models", "usage") } { Invoke-GenInfoCommand $Sub $Tail }
    { $_ -in @("", "-h", "--help", "help") } { Show-GenUsage; Exit-Gen 0 }
    default { Stop-Gen 2 "unknown-command" "unknown gen command: $Sub" "$GenCli gen --help" }
  }
}

$Cmd = if ($args.Count -gt 0) { $args[0] } else { "" }
[string[]]$Rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
if ($Cmd -notin @("", "-h", "--help", "help", "version", "--version", "-v")) {
  Require-ProjectContext -OriginalArgs $args
}
Invoke-LegacyAuthMigrate
if ($Cmd -notin @("version","--version","-v","help","--help","-h","","diagnostics")) { Assert-SdkNoPending }
if ($Cmd -ne "studio-auth" -and $Cmd -ne "diagnostics") { Maybe-SelfUpdate -OriginalArgs $args }

# Project the fixed envelope scalars before parsing; never deserialize storage maps.
function Read-DiagnosticsEnvelope {
  param([string]$Raw)
  if ($null -eq ('Builda.DiagnosticEnvelope' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Text.RegularExpressions;
namespace Builda {
 public static class DiagnosticEnvelope {
  static readonly Regex Number = new Regex(@"\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?",RegexOptions.CultureInvariant);
  static int Space(string s,int i) {while(i<s.Length&&" \t\r\n".IndexOf(s[i])>=0)i++;return i;}
  static int StringEnd(string s,int i) {
   for(i++;i<s.Length;i++) {
    if(s[i]=='"')return i+1;
    if(s[i]=='\\') {
     if(++i>=s.Length)break;
     if(s[i]=='u') {for(int n=0;n<4;n++)if(++i>=s.Length||!Uri.IsHexDigit(s[i]))throw new FormatException();}
     else if("\"\\/bfnrt".IndexOf(s[i])<0)throw new FormatException();
    }
    else if(s[i]<32)throw new FormatException();
   }
   throw new FormatException();
  }
  // Validate and skip JSON syntax without interpreting any object's member names.
  static int ValueEnd(string s,int i) {
   i=Space(s,i);if(i>=s.Length)throw new FormatException();
   if(s[i]=='"')return StringEnd(s,i);
   if(s[i]=='{'||s[i]=='[') {
    bool obj=s[i]=='{';char end=obj?'}':']';i=Space(s,i+1);
    if(i<s.Length&&s[i]==end)return i+1;
    while(i<s.Length) {
     if(obj) {
      if(s[i]!='"')throw new FormatException();
      i=Space(s,StringEnd(s,i));if(i>=s.Length||s[i++]!=':')throw new FormatException();
     }
     i=Space(s,ValueEnd(s,i));if(i>=s.Length)throw new FormatException();
     if(s[i]==end)return i+1;
     if(s[i++]!=',')throw new FormatException();
     i=Space(s,i);if(i>=s.Length||s[i]==end)throw new FormatException();
    }
    throw new FormatException();
   }
   foreach(string literal in new[]{"null","true","false"})
    if(i+literal.Length<=s.Length&&string.CompareOrdinal(s,i,literal,0,literal.Length)==0)return i+literal.Length;
   // Match must start at the current offset, including when nested in data.
   var number=Number.Match(s,i);
   if(!number.Success)throw new FormatException();
   return i+number.Length;
  }
  public static string Project(string raw) {
   int i=Space(raw,0);if(i>=raw.Length||raw[i++]!='{')throw new FormatException();
   var output=new StringBuilder("{");bool first=true;bool ended=false;
   while((i=Space(raw,i))<raw.Length) {
    if(raw[i]=='}') {i++;ended=true;break;}
    if(raw[i]!='"')throw new FormatException();
    int keyStart=i;i=StringEnd(raw,i);string key=raw.Substring(keyStart,i-keyStart);
    i=Space(raw,i);if(i>=raw.Length||raw[i++]!=':')throw new FormatException();
    i=Space(raw,i);int start=i;i=ValueEnd(raw,i);
    if(key=="\"code\""||key=="\"message\""||key=="\"token\"") {
     if(!first)output.Append(',');first=false;
     output.Append(key).Append(':').Append(raw,start,i-start);
    }
    i=Space(raw,i);if(i>=raw.Length)throw new FormatException();
    if(raw[i]=='}') {i++;ended=true;break;}
    if(raw[i++]!=',')throw new FormatException();
    i=Space(raw,i);if(i>=raw.Length||raw[i]=='}')throw new FormatException();
   }
   if(!ended||Space(raw,i)!=raw.Length)throw new FormatException();
   return output.Append('}').ToString();
  }
 }
}
'@
  }
  # Only fixed scalar metadata reaches ConvertFrom-Json; data stays original JSON.
  return ([Builda.DiagnosticEnvelope]::Project($Raw) | ConvertFrom-Json)
}

function Invoke-Diagnostics {
  param([string[]]$Arguments)
  try {
    if ($Arguments.Count -lt 2 -or $Arguments[0] -notin @('private-kv','player-data')) { throw 'Usage: builda diagnostics <private-kv|player-data> <data|logs> --role-id <id> --json' }
    $Source = $Arguments[0]
    $Kind = $Arguments[1]
    if ($Kind -notin @('data','logs')) { throw 'invalid query kind' }
    $Values = @{}; $Keys = @(); $JsonOutput = $false
    for ($I = 2; $I -lt $Arguments.Count; $I++) {
      $Name = $Arguments[$I]
      if ($Name -eq '--json') { $JsonOutput = $true; continue }
      if ($Name -notin @('--role-id','--game-id','--key','--cursor','--from','--to','--operation','--ctx-id','--limit','--bundle-version') -or $I+1 -ge $Arguments.Count) { throw 'invalid diagnostics argument' }
      $I++; if ($Name -eq '--key') { $Keys += $Arguments[$I] } else { if ($Values.ContainsKey($Name)) { throw 'duplicate diagnostics argument' }; $Values[$Name] = $Arguments[$I] }
    }
    if (!$JsonOutput -or ($Source -ne 'runtime-errors' -and !$Values['--role-id'])) { throw '--role-id and --json required' }
    if ($Source -ne 'runtime-errors' -and ($Values.ContainsKey('--bundle-version') -or ($Values.ContainsKey('--limit') -and !($Source -eq 'player-data' -and $Kind -eq 'logs')))) { throw 'invalid runtime error filter' }
    $Game = Get-ProjectGameId
    if (!$Game) { throw 'gameBindingUnavailable: project binding required' }
    if ($Values['--game-id']) { $Game = $Values['--game-id'] }
    $Params = @{}
    if ($Source -eq 'runtime-errors') {
      if ($Kind -ne 'logs' -or $Keys.Count) { throw 'runtime-errors supports logs only' }
      foreach ($Flag in @('--cursor','--from','--to','--operation','--ctx-id')) { if ($Values.ContainsKey($Flag)) { throw 'invalid runtime error parameter' } }
      $Limit = 50
      if ($Values.ContainsKey('--limit')) {
        if ($Values['--limit'] -notmatch '^[1-9][0-9]{0,2}$') { throw 'invalid limit' }
        $Limit = [int]$Values['--limit']; if ($Limit -gt 200) { throw 'invalid limit' }
      }
      $Params['limit'] = $Limit
      if ($Values.ContainsKey('--role-id')) { $Params['roleId']=$Values['--role-id'] }
      if ($Values.ContainsKey('--bundle-version')) { $Params['bundleVersion']=$Values['--bundle-version'] }
    } elseif ($Kind -eq 'data') {
      foreach ($Flag in @('--cursor','--from','--to','--operation','--ctx-id')) { if ($Values.ContainsKey($Flag)) { throw 'invalid data parameter' } }
      $Params['keys'] = @($Keys)
    } else {
      if (!$Values['--from'] -or !$Values['--to'] -or $Keys.Count -gt 1) { throw 'logs requires from/to and at most one key' }
      $FieldMap = @{'--cursor'='cursor';'--from'='from';'--to'='to';'--operation'='operation';'--ctx-id'='ctxId'}
      foreach ($Flag in $FieldMap.Keys) { if ($Values.ContainsKey($Flag)) { $Params[$FieldMap[$Flag]] = $Values[$Flag] } }
      if ($Keys.Count) { $Params['key'] = $Keys[0] }
      if ($Source -eq 'player-data') {
        if ($Keys.Count -or $Values.ContainsKey('--cursor') -or $Values['--operation'] -eq 'clear') { throw 'invalid player-data log parameter' }
        $Limit=50
        if ($Values.ContainsKey('--limit')) {
          if ($Values['--limit'] -notmatch '^[1-9][0-9]{0,2}$') { throw 'invalid limit' }
          $Limit=[int]$Values['--limit']; if ($Limit -gt 200) { throw 'invalid limit' }
        }
        $Params['limit']=$Limit
      }
    }
    # Normal authorization persists only the existing parent credential. The
    # diagnostic grant is never printed or written to a file.
    Ensure-Authorization *>&1 | ForEach-Object { [Console]::Error.WriteLine([string]$_) }
    $GrantBody = [Text.Encoding]::UTF8.GetBytes((@{gameId=$Game} | ConvertTo-Json -Compress))
    $RequestObject = @{gameId=$Game;kind=$Kind}
    if ($Source -ne 'runtime-errors') { $RequestObject['roleId']=$Values['--role-id'] }
    if ($Kind -eq 'data') { $RequestObject['dataParams']=$Params } else { $RequestObject['logsParams']=$Params }
    $Request = $RequestObject | ConvertTo-Json -Depth 12 -Compress
    for ($Attempt=0; $Attempt -lt 2; $Attempt++) {
      $GrantResponse = Invoke-BuildaHttpRequest -Headers @{Authorization="Bearer $(Get-Token)"} -NoRedirect -TimeoutSeconds -1 -Method POST -Uri "$Base/api/v1/agent/diagnostics/grant" -BodyBytes $GrantBody
      $Grant = Read-DiagnosticsEnvelope ([string]$GrantResponse.Body)
      if (!$GrantResponse.IsSuccess -or !$Grant.token) {
        if (($Grant.code -isnot [int] -and $Grant.code -isnot [long]) -or $Grant.code -eq 0 -or $Grant.PSObject.Properties.Name -contains 'token') { throw 'invalid diagnostics grant response' }
        Write-Output ([string]$GrantResponse.Body); exit 1
      }
      $Response = Invoke-BuildaHttpRequest -Method POST -Uri "$Base/api/v1/agent/diagnostics/$Source/query" -NoRedirect -TimeoutSeconds -1 -Headers @{Authorization="Bearer $($Grant.token)"} -ContentType 'application/json' -BodyBytes ([Text.Encoding]::UTF8.GetBytes($Request))
      $Result = Read-DiagnosticsEnvelope ([string]$Response.Body)
      if ($Result.message -eq 'diagnosticGrantExpired' -and $Attempt -eq 0) { continue }
      if (($Result.code -isnot [int] -and $Result.code -isnot [long]) -or $Result.PSObject.Properties.Name -contains 'token' -or (!$Response.IsSuccess -and $Result.code -eq 0)) { throw 'invalid diagnostics response' }
      Write-Output ([string]$Response.Body)
      if ($Result.code -eq 0 -and $Response.IsSuccess) { exit 0 }; exit 1
    }
  } catch {
    throw 'BUILDA_DIAGNOSTICS_FAILED: check binding, authorization and API availability'
  }
}


switch ($Cmd) {
  "studio-auth" {
    Invoke-StudioAuth
  }
  "auth" {
    $AuthArg = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    if ($AuthArg -eq "status") {
      Write-AuthStatus
    } elseif ($AuthArg -eq "logout") {
      Logout-Authorization
    } elseif ($AuthArg -eq "--force") {
      Auth-WithBrowser
      Write-Host "authorization=ready"
      Write-Host "grant=present"
      Write-Host "agent-authorization=present"
    } else {
      $Code = if ($AuthArg) { $AuthArg } else { $PairCode }
      Ensure-Authorization $Code
    }
  }
  "check" {
    if ($Rest.Count -eq 2 -and $Rest[0] -eq "--agent" -and $Rest[1] -eq "--quiet") {
      $FeedbackCli = Join-Path $PSScriptRoot 'builda-feedback.ps1'
      if (Test-Path $FeedbackCli) {
        & $FeedbackCli check --agent --quiet
        exit $LASTEXITCODE
      }
      break
    }
    Check-SelfUpdate
    Sync-ProjectRegistrations *> $null
    Write-Host "project-registrations=ensured"
    Write-Host "BUILDA_BASE=$Base"
    Write-Host "BUILDA_AGENT_BASE=$AgentBase"
    if (Test-Path $TokenPath) { Write-Host "grant=present" } else { Write-Host "grant=missing" }
    if (Test-Path $RefreshPath) { Write-Host "agent-authorization=present" } else { Write-Host "agent-authorization=missing" }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) { Write-Host "curl=ok" } else { Write-Host "curl=missing" }
    $CheckEngine = Get-EngineValue '.'
    Write-Host "engine=$CheckEngine"
    Write-SkillTopics -Engine $CheckEngine
    if (Test-Path $ProjectFile) {
      $ProjectGameId = Get-ProjectGameId
      if ($ProjectGameId) { Write-Host "project-game-id=$ProjectGameId" } else { Write-Host "project-game-id=invalid" }
      Write-Host "project-state-dir=$(Split-Path -Parent $ProjectFile)"
    } elseif (Test-Path $LegacyProjectFile) {
      $ProjectGameId = Get-ProjectGameId
      if ($ProjectGameId) { Write-Host "project-game-id=$ProjectGameId" } else { Write-Host "project-game-id=invalid" }
      Write-Host "project-binding=$ProjectFile"
      Write-Host "project-state-dir=$(Split-Path -Parent $ProjectFile)"
    } else {
      # No bound game is a normal state (e.g. only using builda gen to generate assets): give a neutral hint and skip Cloud State checks that depend on game identity.
      Write-Host "project-game-id=none"
      Write-Host "project-game-note=not bound to a Builda game yet; normal when only using builda gen, publishing binds it"
    }
    if (Get-ProjectGameId) {
      try { Get-CloudAdvisories @("--no-auth-prompt") } catch { Write-Host "cloud-advisories=unavailable" }
    } else {
      Write-Host "cloud-advisories=skipped (no bound game)"
    }
  }
  "update" {
    $Remote = Get-BuildaRemoteJson -Uri "$AgentBase/agent/version"
    if (!$Remote.version) { throw "remote Agent version is missing" }
    Update-BuildaTool -NewVersion $Remote.version
  }
  "sync-project" {
    Write-Host "Agent registrations:"
    Sync-ProjectRegistrations
  }
  "engine" {
    $Sub = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    switch ($Sub) {
      "detect" {
        $Dir = if ($Rest.Count -gt 1) { $Rest[1] } else { "." }
        Invoke-EngineDetect $Dir
      }
      { $_ -in @("", "-h", "--help", "help") } {
        Write-Host "Usage: builda engine detect [dir]"
      }
      default {
        Write-Error "Unknown engine command: $Sub"
        Write-Host "Usage: builda engine detect [dir]"
        exit 1
      }
    }
  }
  "version" {
    Write-Host $Version
  }
  "--version" {
    Write-Host $Version
  }
  "-v" {
    Write-Host $Version
  }
  "new-manifest" {
    Write-DefaultManifest
  }
  "dev" {
    Invoke-DevServer -DevArgs $Rest
  }
  "bundle-pack" {
    if ($Rest.Count -ne 2) { throw "Usage: builda bundle-pack <build-directory> <output.zip>" }
    New-BundleZip $Rest[0] $Rest[1]
  }
  "bundle-check" {
    if ($Rest.Count -lt 1) { throw "zip file required" }
    $WebViewCompat = $false
    $Engine = ""
    $ZipArg = ""
    for ($I = 0; $I -lt $Rest.Count; $I++) {
      switch -Regex ($Rest[$I]) {
        "^--webview-compatible$" { $WebViewCompat = $true }
        "^--engine$" {
          $I++
          if ($I -ge $Rest.Count) { throw "Usage: builda bundle-check [--engine godot|h5|unity] [--webview-compatible] <zip>" }
          $Engine = $Rest[$I]
        }
        "^--engine=(.*)$" { $Engine = $Matches[1] }
        default { $ZipArg = $Rest[$I] }
      }
    }
    if (!$ZipArg) { throw "zip file required" }
    if ($env:BUILDA_WEBVIEW_COMPAT -eq "1") { $WebViewCompat = $true }
    Test-BundleZip $ZipArg $WebViewCompat $Engine
  }
  "assets" {
    $Sub = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    switch ($Sub) {
      "check" {
        if ($Rest.Count -lt 2) { throw "Usage: builda assets check <zip>" }
        Test-AssetsZip $Rest[1]
      }
      "upload" {
        if ($Rest.Count -lt 2) { throw "Usage: builda assets upload <zip>" }
        Upload-AssetsZip $Rest[1]
      }
      "upload-list" { Need-Token; Get-ActiveUploadSessions -Options @($Rest | Select-Object -Skip 1) -Purpose "assets" }
      "upload-status" { Need-Token; if ($Rest.Count -lt 2) { throw "session ID required" }; Get-UploadSessionStatus $Rest[1] "assets" }
      "upload-cancel" { Need-Token; if ($Rest.Count -lt 2) { throw "session ID required" }; Cancel-UploadSession $Rest[1] "assets" }
      { $_ -in @("", "-h", "--help", "help") } {
        Write-Host "Usage: builda assets check <zip> | upload <zip> | upload-list [--all] [--json] | upload-status <session> | upload-cancel <session>"
      }
      default {
        Write-Error "Unknown assets command: $Sub"
        Write-Host "Usage: builda assets check <zip> | upload <zip> | upload-list [--all] [--json] | upload-status <session> | upload-cancel <session>"
        exit 1
      }
    }
  }
  "sdk" {
    $Sub = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    switch ($Sub) {
      "init" { Initialize-SdkProject }
      "install" { Set-SdkInstallOptions -Arguments @($Rest | Select-Object -Skip 1) -AllowVersion $true; Install-Sdk }
      "upgrade" { $script:SdkUpgrade = $true; Set-SdkInstallOptions -Arguments @($Rest | Select-Object -Skip 1) -AllowVersion $false; Install-Sdk }
      "check" {
        Test-Sdk
        if (Test-Path $SdkVersionFile) { Write-SdkLatestHint -Pin (Read-Utf8Lines $SdkVersionFile | Select-Object -First 1).Trim() }
      }
      "smoke" { Invoke-SdkSmoke }
      { $_ -in @("", "-h", "--help", "help") } {
        Write-Host "Usage: builda sdk init | install [version] [--with-online] | upgrade [--with-online] | check | smoke"
      }
      default {
        Write-Error "Unknown sdk command: $Sub"
        Write-Host "Usage: builda sdk init | install [version] [--with-online] | upgrade [--with-online] | check | smoke"
        exit 1
      }
    }
  }
  "diagnostics" {
    Invoke-Diagnostics -Arguments $Rest
  }
  "cloud-advisories" {
    Invoke-CloudAdvisories $Rest
  }
  "upload-build" {
    Need-Token
    if ($Rest.Count -lt 1 -or !(Test-Path $Rest[0])) { throw "zip file required" }
    if (Test-Path $Manifest) { Assert-ObjectSchemasManifest $Manifest }
    $Engine = if (Test-Path $Manifest) { Get-ObjectSchemaManifestEngine $Manifest } else { Get-ManifestEngine }
    Test-BundleZip $Rest[0] $false $Engine | Out-Null
    $Zip = (Resolve-Path $Rest[0]).Path
    $Raw = Invoke-ResumableBuildUpload $Zip $Engine
    $Resp = $Raw | ConvertFrom-Json
    Write-Utf8TextNoBom (Join-Path $Root "last-build.json") ($Resp | ConvertTo-Json -Depth 8)
    $Resp | ConvertTo-Json -Depth 8
    if ($Resp.prefix) {
      if (!(Test-Path $Manifest)) { Write-DefaultManifest }
      Initialize-ObjectSchemas
      $OriginalManifest = Read-Utf8Text $Manifest
      $SchemaArray = [BuildaObjectSchemas]::SchemaArray($OriginalManifest)
      $ManifestWithoutSchemas = if ($SchemaArray -eq "[]") { $OriginalManifest } else { [BuildaObjectSchemas]::StripSchemas($OriginalManifest) }
      $Data = $ManifestWithoutSchemas | ConvertFrom-Json
      $BuildEntry = if ($Resp.entry) { $Resp.entry } else { "index.html" }
      foreach ($Field in @{
        buildPrefix = $Resp.prefix
        buildEntry = $BuildEntry
        buildSize = $(if ($Resp.size) { $Resp.size } else { 0 })
        bundleUrl = $(if ($Resp.bundleUrl) { $Resp.bundleUrl } else { "" })
        bundleMd5 = $(if ($Resp.bundleMd5) { $Resp.bundleMd5 } else { "" })
        bundleVersion = $(if ($Resp.bundleVersion) { $Resp.bundleVersion } else { $Resp.prefix })
        bundleEntry = $(if ($Resp.bundleEntry) { $Resp.bundleEntry } else { $BuildEntry })
        bundleSize = $(if ($Resp.bundleSize) { $Resp.bundleSize } else { 0 })
      }.GetEnumerator()) {
        $Data | Add-Member -NotePropertyName $Field.Key -NotePropertyValue $Field.Value -Force
      }
      $UpdatedManifest = $Data | ConvertTo-Json -Depth 16
      if ($SchemaArray -ne "[]") { $UpdatedManifest = [BuildaObjectSchemas]::MergeSchemas($OriginalManifest, $UpdatedManifest) }
      Write-SchemaAtomicText $Manifest $UpdatedManifest
      if ($env:BUILDA_SCHEMA_STAGING -eq "1") {
        # Schema publish writes the frozen copy; the user manifest changes only when publish completes.
        Write-Host "Staged build and H5 Bundle fields for this publish; your manifest is updated when publish completes."
      } else {
        Write-Host "Updated $Manifest with build and H5 Bundle fields."
      }
    }
  }
  "upload-list" {
    Need-Token
    Get-ActiveUploadSessions -Options $Rest
  }
  "upload-status" {
    Need-Token
    $SessionId = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    Get-UploadSessionStatus $SessionId
  }
  "upload-cancel" {
    Need-Token
    $SessionId = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    Cancel-UploadSession $SessionId
  }
  "gen" {
    Invoke-Gen $Rest
  }
  "schemas" {
    $Sub = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
    switch ($Sub) {
      "upload" {
        $File = if ($Rest.Count -gt 1) { $Rest[1] } else { $Manifest }
        if (!(Test-Path $File)) { throw "manifest not found: $File" }
        Invoke-ObjectSchemaPublish "schemas" $File (Get-ProjectGameId) ""
      }
      { $_ -in @("", "-h", "--help", "help") } {
        Write-Host "Usage: builda schemas upload [manifest]"
      }
      default { throw "Unknown schemas command: $Sub" }
    }
  }
  "publish" {
    $VerboseOutput = $Rest -contains "--verbose"
    [string[]]$PublishArgs = @($Rest | Where-Object { $_ -ne "--verbose" })
    $Zip = if ($PublishArgs.Count -gt 0) { $PublishArgs[0] } else { "" }
    $File = if ($PublishArgs.Count -gt 1) { $PublishArgs[1] } else { $Manifest }
    if ($Zip -eq "-h" -or $Zip -eq "--help" -or $Zip -eq "help") {
      Write-Host "Usage: builda publish [build.zip] [manifest] [--verbose]"
      return
    }
    if (!(Test-Path $File)) { throw "manifest not found: $File" }
    if ((Get-ObjectSchemaMode $File) -eq "active") {
      Invoke-ObjectSchemaPublish "publish" $File (Get-ProjectGameId) $Zip
      return
    }
    Sync-OnlineCompatibilityRevision $File
    Invoke-DraftPreflight $File
    if ($Zip) {
      if (!(Test-Path $Zip)) { throw "build zip not found: $Zip" }
      $PreviousManifest = $env:BUILDA_MANIFEST
      try {
        $env:BUILDA_MANIFEST = [System.IO.Path]::GetFullPath($File)
        $UploadOutput = & $PSCommandPath upload-build $Zip
        $UploadSucceeded = $?
      } finally {
        if ($null -eq $PreviousManifest) { Remove-Item Env:BUILDA_MANIFEST -ErrorAction SilentlyContinue } else { $env:BUILDA_MANIFEST = $PreviousManifest }
      }
      if (!$UploadSucceeded) { throw "build upload failed" }
      if ($VerboseOutput -and $null -ne $UploadOutput) { $UploadOutput | Write-Output }
    }
    Set-ManifestSdkVersion $File
    $GameId = Get-ProjectGameId
    $PendingCreate = if ($env:BUILDA_PUBLISH_OPERATION_ID) { "" } else { Get-DraftIdempotencyKey "create" "" $File $true }
    if ($PendingCreate) {
      if ($VerboseOutput) { & $PSCommandPath create-draft $File --verbose } else { & $PSCommandPath create-draft $File }
    } elseif ($GameId) {
      if ($VerboseOutput) { & $PSCommandPath update-draft $GameId $File --verbose } else { & $PSCommandPath update-draft $GameId $File }
    } else {
      if ($VerboseOutput) { & $PSCommandPath create-draft $File --verbose } else { & $PSCommandPath create-draft $File }
    }
    $DraftSucceeded = $?
    if (!$DraftSucceeded) { throw "draft sync failed" }
  }
  "create-draft" {
    $VerboseOutput = $Rest -contains "--verbose"
    [string[]]$DraftArgs = @($Rest | Where-Object { $_ -ne "--verbose" })
    $File = if ($DraftArgs.Count -gt 0) { $DraftArgs[0] } else { $Manifest }
    if ($File -eq "-h" -or $File -eq "--help" -or $File -eq "help") {
      Write-Host "Usage: builda create-draft [manifest] [--verbose]"
      return
    }
    if (!(Test-Path $File)) { throw "manifest not found: $File" }
    if ((Get-ObjectSchemaMode $File) -eq "active") {
      Invoke-ObjectSchemaPublish "create-draft" $File "" ""
      return
    }
    Sync-OnlineCompatibilityRevision $File
    Invoke-DraftPreflight $File
    Set-ManifestSdkVersion $File
    Need-Token
    Migrate-LegacyProjectFile
    $Operation = ""
    if (!$env:BUILDA_PUBLISH_OPERATION_ID) {
      $Operation = Get-DraftIdempotencyKey "create" "" $File $true
    }
    if (Test-Path $ProjectFile) {
      $ExistingId = Get-ProjectGameId
      if ($ExistingId -and !$Operation) { throw "$ProjectFile already binds this project to $ExistingId. Use: builda update-draft" }
    }
    Write-PublishPreflight "create" "new-game"
    $Headers = if ($env:BUILDA_PUBLISH_OPERATION_ID) {
      Get-StudioUploadHeaders $env:BUILDA_PUBLISH_OPERATION_ID
    } else {
      if (!$Operation) { $Operation = Get-DraftIdempotencyKey "create" "" $File }
      @{
        Authorization = "Bearer $(Get-Token)"
        "Idempotency-Key" = $Operation
      }
    }
    [byte[]]$BodyBytes = ConvertTo-ManifestRequestBytes $File
    $Resp = Invoke-DraftRequestWithAuthRetry -Uri (Get-CmdUrl "game/create") -Headers $Headers -BodyBytes $BodyBytes
    Assert-CmdResponseOk $Resp "create draft"
    Write-Utf8TextNoBom (Join-Path $Root "last-draft.json") ($Resp | ConvertTo-Json -Depth 8)
    $GameId = $Resp.body.game.id
    $VersionId = if ($Resp.body.game.versionId) { $Resp.body.game.versionId } else { $Resp.body.game.draftVersionId }
    if (!$GameId -or !$VersionId) { throw "BUILDA_DRAFT_RESPONSE_INVALID: create draft response is missing gameId or versionId; retry with the preserved operation receipt." }
    if ($GameId) {
      $GameId | Set-Content -Encoding ASCII (Join-Path $Root "last-game-id")
      $GameId | Set-Content -Encoding ASCII (Join-Path $Root "last-draft-id")
    }
    if ($VersionId) { $VersionId | Set-Content -Encoding ASCII (Join-Path $Root "last-version-id") }
    Write-ProjectGame $GameId (Get-ManifestTitle $File) $VersionId
    if (!$env:BUILDA_PUBLISH_OPERATION_ID) { Complete-DraftIdempotencyKey $Operation }
    $ManifestData = Read-Utf8Text $File | ConvertFrom-Json
    Write-Host "sync=ok gameId=$GameId versionId=$VersionId bundleVersion=$($ManifestData.bundleVersion) orientation=$($ManifestData.orientation) clientDraft=ready publicRelease=pending_user_action"
    if ($VerboseOutput) { $Resp | ConvertTo-Json -Depth 8 }
  }
  "update-draft" {
    $VerboseOutput = $Rest -contains "--verbose"
    [string[]]$DraftArgs = @($Rest | Where-Object { $_ -ne "--verbose" })
    $Id = if ($DraftArgs.Count -gt 0) { $DraftArgs[0] } else { "" }
    if ($Id -eq "-h" -or $Id -eq "--help" -or $Id -eq "help") {
      Write-Host "Usage: builda update-draft [game_id] [manifest] [--verbose]"
      return
    }
    $File = if ($DraftArgs.Count -gt 1) { $DraftArgs[1] } else { $Manifest }
    if ($Id -and (Test-Path $Id)) {
      $File = $Id
      $Id = ""
    }
    if (!$Id) { $Id = Get-ProjectGameId }
    $LastGameId = Join-Path $Root "last-game-id"
    if (!$Id -and (Test-Path $LastGameId)) {
      $WeakId = (Read-Utf8Text $LastGameId).Trim()
      throw "No $ProjectFile in this project. Last global game id is $WeakId, but it may belong to another project. Pass the intended id explicitly once: builda update-draft $WeakId"
    }
    if (!$Id) { throw "game id required. Put $ProjectStateDir/game.json in this project or pass game id explicitly." }
    if (!(Test-Path $File)) { throw "manifest not found: $File" }
    if ((Get-ObjectSchemaMode $File) -eq "active") {
      Invoke-ObjectSchemaPublish "update-draft" $File $Id ""
      return
    }
    Sync-OnlineCompatibilityRevision $File
    Invoke-DraftPreflight $File
    Set-ManifestSdkVersion $File
    Need-Token
    Write-PublishPreflight "update" $Id
    $Data = Read-Utf8Text $File | ConvertFrom-Json
    $Data = Remove-DeprecatedDisplayFields $Data
    $Data | Add-Member -NotePropertyName id -NotePropertyValue $Id -Force
    $Body = $Data | ConvertTo-Json -Depth 8
    $BodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Body)
    $Operation = ""
    $Headers = if ($env:BUILDA_PUBLISH_OPERATION_ID) {
      Get-StudioUploadHeaders $env:BUILDA_PUBLISH_OPERATION_ID
    } else {
      $Operation = Get-DraftIdempotencyKey "update" $Id $File
      @{
        Authorization = "Bearer $(Get-Token)"
        "Idempotency-Key" = $Operation
      }
    }
    $Resp = Invoke-DraftRequestWithAuthRetry -Uri (Get-CmdUrl "game/updatedraft") -Headers $Headers -BodyBytes $BodyBytes
    Assert-CmdResponseOk $Resp "update draft"
    Write-Utf8TextNoBom (Join-Path $Root "last-draft.json") ($Resp | ConvertTo-Json -Depth 8)
    $GameId = $Resp.body.game.id
    $VersionId = if ($Resp.body.game.versionId) { $Resp.body.game.versionId } else { $Resp.body.game.draftVersionId }
    if (!$GameId) { $GameId = $Id }
    if (!$VersionId) { throw "BUILDA_DRAFT_RESPONSE_INVALID: update draft response is missing versionId; retry with the preserved operation receipt." }
    if ($GameId) {
      $GameId | Set-Content -Encoding ASCII (Join-Path $Root "last-game-id")
      $GameId | Set-Content -Encoding ASCII (Join-Path $Root "last-draft-id")
    }
    if ($VersionId) { $VersionId | Set-Content -Encoding ASCII (Join-Path $Root "last-version-id") }
    Write-ProjectGame $GameId (Get-ManifestTitle $File) $VersionId
    if (!$env:BUILDA_PUBLISH_OPERATION_ID) { Complete-DraftIdempotencyKey $Operation }
    $ManifestData = Read-Utf8Text $File | ConvertFrom-Json
    Write-Host "sync=ok gameId=$GameId versionId=$VersionId bundleVersion=$($ManifestData.bundleVersion) orientation=$($ManifestData.orientation) clientDraft=ready publicRelease=pending_user_action"
    if ($VerboseOutput) { $Resp | ConvertTo-Json -Depth 8 }
  }
  "status" {
    Write-Host "root=$Root"
    if (Test-Path $TokenPath) { Write-Host "grant=present" } else { Write-Host "grant=missing" }
    if (Test-Path $RefreshPath) { Write-Host "agent-authorization=present" } else { Write-Host "agent-authorization=missing" }
    if (Test-Path $TokenPath) {
      try { Write-ActingIdentity } catch { Write-Host "identity=unavailable" }
    } else {
      Write-Host "identity=unavailable"
    }
    if (Test-Path $Manifest) { Write-Host "manifest=$Manifest" }
    if (Test-Path $ProjectFile) {
      $ProjectGameId = Get-ProjectGameId
      if ($ProjectGameId) { Write-Host "project-game-id=$ProjectGameId" } else { Write-Host "project-game-id=invalid" }
      Write-Host "project-binding=$ProjectFile"
      Write-Host "project-state-dir=$(Split-Path -Parent $ProjectFile)"
    }
    $LastBuild = Join-Path $Root "last-build.json"
    if (Test-Path $LastBuild) { Write-Host "last-build=$LastBuild" }
    $LastAssets = Join-Path $Root "last-assets.json"
    if (Test-Path $LastAssets) { Write-Host "last-assets=$LastAssets" }
    $LastGameId = Join-Path $Root "last-game-id"
    if (Test-Path $LastGameId) { Write-Host "last-game-id=$((Read-Utf8Text $LastGameId).Trim()) (weak receipt, not project identity)" }
    $LastVersionId = Join-Path $Root "last-version-id"
    if (Test-Path $LastVersionId) { Write-Host "last-version-id=$((Read-Utf8Text $LastVersionId).Trim())" }
  }
  "uninstall" {
    Invoke-Uninstall $Rest
  }
  "whoami" {
    Write-ActingIdentity
  }
  { $_ -in @("", "-h", "--help", "help") } {
    Show-Usage
  }
  default {
    Write-Error "Unknown command: $Cmd"
    Show-Usage
    exit 1
  }
}
