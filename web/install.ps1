# Windows PowerShell 5.1 standalone bootstrap. No JDK commands are invoked.
$ErrorActionPreference = 'Stop'

function Write-InstallerMessage([string]$Message) { [Console]::Error.WriteLine("jvm installer: $Message") }
function Stop-Installer([string]$Message, [int]$Code = 1) {
    $exception = New-Object Exception $Message
    $exception.Data['InstallerCode'] = $Code
    throw $exception
}
function Test-ToolVersion([string]$Value) { return $Value -cmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' }
function Get-ToolHash([string]$File) {
    $stream = [IO.File]::OpenRead($File)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Test-PlainFile([string]$File) {
    if (-not [IO.File]::Exists($File)) { return $false }
    return -not ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Assert-SafeRoot([string]$Value) {
    if ($Value -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or $Value -match '[;\r\n\t]') {
        Stop-Installer "Expected an absolute native path without semicolons or line breaks: $Value"
    }
}
function Assert-NoReparse([string]$File) {
    if (Test-Path -LiteralPath $File) {
        if ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Installer "Reparse point conflict: $File" }
    }
}
function Get-Download([string]$Url, [string]$File) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($i = 0; $i -lt 10; $i++) {
        if (([Uri]$Url).Scheme -cne 'https') { Stop-Installer 'HTTPS is required, including redirects' }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 45000
        $request.ReadWriteTimeout = 45000
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $Url = ([Uri]::new([Uri]$Url, $response.Headers['Location'])).AbsoluteUri
                continue
            }
            if ($status -ne 200) { Stop-Installer "HTTP $status for $Url" }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Create($File)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            if ((Get-Item -LiteralPath $File).Length -eq 0) { Stop-Installer "Empty download: $Url" }
            return
        } finally { $response.Dispose() }
    }
    Stop-Installer 'Too many HTTPS redirects'
}
function Read-ToolChecksums([string]$File) {
    $result = @{}
    $lines = [IO.File]::ReadAllLines($File)
    if ($lines.Count -ne 3) { Stop-Installer 'SHA256SUMS must contain exactly three entries' }
    foreach ($line in $lines) {
        if ($line -cnotmatch '\A([0-9a-fA-F]{64})  (jvm|jvm\.ps1|jvm\.cmd)\z') { Stop-Installer 'Invalid SHA256SUMS entry' }
        $name = $Matches[2]; $digest = $Matches[1].ToLowerInvariant()
        if ($result.ContainsKey($name)) { Stop-Installer 'Duplicate SHA256SUMS entry' }
        $result[$name] = $digest
    }
    return $result
}
function Read-ToolRecord([string]$File, [string]$Destination) {
    if (-not (Test-PlainFile $File)) { Stop-Installer "Unsafe ownership record: $File" }
    $lines = [IO.File]::ReadAllLines($File)
    if ($lines.Count -ne 6 -or $lines[0] -cne 'jvm-tool-v1' -or -not (Test-ToolVersion $lines[1]) -or $lines[2] -cne $Destination) {
        Stop-Installer 'Invalid ownership record or destination mismatch'
    }
    $result = @{}
    foreach ($line in $lines[3..5]) {
        if ($line -cnotmatch '\A([0-9a-f]{64})  (jvm|jvm\.ps1|jvm\.cmd)\z' -or $result.ContainsKey($Matches[2])) { Stop-Installer 'Invalid ownership hashes' }
        $result[$Matches[2]] = $Matches[1]
    }
    return $result
}
function Write-ToolRecord([string]$File, [string]$Version, [string]$Destination, [hashtable]$Hashes) {
    $lines = @('jvm-tool-v1', $Version, $Destination)
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { $lines += "$($Hashes[$name])  $name" }
    [IO.File]::WriteAllText($File, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}
function Remove-ToolStage([string]$Stage) {
    Assert-NoReparse $Stage
    if (-not (Test-Path -LiteralPath $Stage)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Stage -Force)) {
        if ($entry.Name -cnotin @('jvm', 'jvm.ps1', 'jvm.cmd') -or -not (Test-PlainFile $entry.FullName)) { Stop-Installer "Unrecognized staging material: $($entry.FullName)" }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Stage -Force)) { [IO.File]::Delete($entry.FullName) }
    [IO.Directory]::Delete($Stage)
}
function Restore-ToolTransaction([string]$State, [string]$Destination) {
    $tx = Join-Path $State 'transaction'
    Assert-NoReparse $tx
    if (-not (Test-Path -LiteralPath $tx)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $tx -Force)) {
        if ($entry.Name -cnotin @('new-record', 'old-record', 'old-jvm', 'old-jvm.ps1', 'old-jvm.cmd', 'ready', 'stage-name') -or -not (Test-PlainFile $entry.FullName)) {
            Stop-Installer "Unrecognized recovery material: $($entry.FullName); inspect manually"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $tx 'stage-name')) {
        if (-not (Test-PlainFile (Join-Path $tx 'stage-name'))) { Stop-Installer 'Unsafe staging journal' }
        $stageName = [IO.File]::ReadAllText((Join-Path $tx 'stage-name'))
        if ($stageName -cnotmatch '\A\.jvm-next-[a-f0-9]{32}\z') { Stop-Installer 'Invalid staging journal' }
        $stage = Join-Path $Destination $stageName
        Remove-ToolStage $stage
    }
    if (Test-Path -LiteralPath (Join-Path $tx 'ready')) {
        $new = Read-ToolRecord (Join-Path $tx 'new-record') $Destination
        $old = $null
        if (Test-Path -LiteralPath (Join-Path $tx 'old-record')) { $old = Read-ToolRecord (Join-Path $tx 'old-record') $Destination }
        # Verify every backup before restoring any member; recovery is repeatable.
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            Assert-NoReparse $file
            if ((Test-Path -LiteralPath $file) -and -not (Test-PlainFile $file)) { Stop-Installer "Unsafe recovery destination: $file" }
            if ($old) {
                $backup = Join-Path $tx "old-$name"
                if (-not (Test-PlainFile $backup) -or (Get-ToolHash $backup) -cne $old[$name]) { Stop-Installer "Damaged recovery material at $tx; inspect manually" }
            } elseif ((Test-Path -LiteralPath $file) -and (Get-ToolHash $file) -cne $new[$name]) { Stop-Installer "Unknown recovery destination: $file" }
        }
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            if ($old) {
                if (-not (Test-PlainFile $file) -or (Get-ToolHash $file) -cne $old[$name]) { [IO.File]::Copy((Join-Path $tx "old-$name"), $file, $true) }
            }
            elseif (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
        }
        if ($old) { [IO.File]::Copy((Join-Path $tx 'old-record'), (Join-Path $State 'record'), $true) }
        elseif (Test-Path -LiteralPath (Join-Path $State 'record')) { [IO.File]::Delete((Join-Path $State 'record')) }
        Write-InstallerMessage 'Recovered interrupted tool publication.'
    }
    Remove-Item -LiteralPath $tx -Recurse -Force
}
function Publish-Tool([string]$Work, [string]$State, [string]$Destination, [string]$Version, [hashtable]$Hashes) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    [IO.Directory]::CreateDirectory($State) | Out-Null
    Assert-NoReparse $State; Assert-NoReparse $Destination
    Assert-NoReparse (Join-Path $State 'lock')
    try { $lock = [IO.File]::Open((Join-Path $State 'lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Stop-Installer 'Another installer holds the lock, or the lock is inaccessible; retry after it exits' }
    $tx = Join-Path $State 'transaction'
    try {
        Restore-ToolTransaction $State $Destination
        $record = Join-Path $State 'record'
        $old = $null
        Assert-NoReparse $record
        if (Test-Path -LiteralPath $record) { $old = Read-ToolRecord $record $Destination }
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            if ($old) {
                if (-not (Test-PlainFile $file) -or (Get-ToolHash $file) -cne $old[$name]) { Stop-Installer "Owned file missing or locally modified: $file. Restore it or move the payload and ownership record aside before retrying." }
            } elseif (Test-Path -LiteralPath $file) { Stop-Installer "Unowned destination conflict: $file. Move it aside before retrying." }
        }
        $matching = $null -ne $old
        if ($old) {
            $matching = ([IO.File]::ReadAllLines($record)[1] -ceq $Version)
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { if ($old[$name] -cne $Hashes[$name]) { $matching = $false } }
        }
        if ($matching) { return }
        [IO.Directory]::CreateDirectory($tx) | Out-Null
        if ($old) {
            [IO.File]::Copy($record, (Join-Path $tx 'old-record'))
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { [IO.File]::Copy((Join-Path $Destination $name), (Join-Path $tx "old-$name")) }
        }
        Write-ToolRecord (Join-Path $tx 'new-record') $Version $Destination $Hashes
        # Destination-filesystem staging, before any published file is changed.
        $next = Join-Path $Destination ('.jvm-next-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText((Join-Path $tx 'stage-name'), [IO.Path]::GetFileName($next))
        [IO.Directory]::CreateDirectory($next) | Out-Null
        try {
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { [IO.File]::Copy((Join-Path $Work $name), (Join-Path $next $name)) }
            [IO.File]::WriteAllText((Join-Path $tx 'ready'), 'ready')
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
                $file = Join-Path $Destination $name
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
                [IO.File]::Move((Join-Path $next $name), $file)
            }
            [IO.File]::Copy((Join-Path $tx 'new-record'), $record, $true)
            Remove-Item -LiteralPath $tx -Recurse -Force
        } finally { Remove-ToolStage $next }
    } catch {
        $failure = $_
        try { Restore-ToolTransaction $State $Destination }
        catch { Write-InstallerMessage "Recovery retained at $tx. $($_.Exception.Message)" }
        throw $failure
    } finally {
        # Keep serialization through consented registry edits as well.
        $script:InstallerLock = $lock
    }
}
function Open-EnvironmentKey { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
function Get-RegistryValue($Key, [string]$Name) {
    if ($Key.GetValueNames() -contains $Name) {
        return @{ Exists = $true; Kind = [int]$Key.GetValueKind($Name); Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    return @{ Exists = $false; Kind = [int][Microsoft.Win32.RegistryValueKind]::ExpandString; Value = '' }
}
function Set-RegistrySnapshot($Key, [string]$Name, $Snapshot) {
    if ($Snapshot.Exists) { $Key.SetValue($Name, $Snapshot.Value, [Microsoft.Win32.RegistryValueKind]$Snapshot.Kind) }
    else { $Key.DeleteValue($Name, $false) }
}
function Test-PathEntry([string]$Entry, [string]$Target) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\', '/')
    return $expanded.Replace('/', '\') -ieq $Target.TrimEnd('\', '/').Replace('/', '\')
}
function Add-UserPath([string]$Value, [string]$Entry) {
    foreach ($token in $Value.Split(';')) { if (Test-PathEntry $token $Entry) { return $Value } }
    if ([string]::IsNullOrEmpty($Value)) { return $Entry }
    return "$Entry;$Value"
}
function Send-EnvironmentChange {
    if (-not ('JvmInstaller.Native' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace JvmInstaller { public static class Native {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);
}}
'@
    }
    $result = [UIntPtr]::Zero
    [JvmInstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
}
function Get-SetupConsent([string]$Choice, [bool]$Unattended, [string]$Prompt) {
    if ($Choice -eq 'yes') { return $true }
    if ($Choice -eq 'no' -or $Unattended -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $false }
    try { return (Read-Host "$Prompt [y/N]") -match '\A(?i:y|yes)\z' } catch { return $false }
}
function Set-UserEnvironment([string]$State, [string]$Destination, [string]$JavaHome, [string]$PathChoice, [string]$JavaChoice, [bool]$Unattended) {
    if ($PathChoice -eq 'no' -and $JavaChoice -eq 'no') { return }
    if ($Unattended -and $PathChoice -ne 'yes' -and $JavaChoice -ne 'yes') {
        Write-InstallerMessage "Unspecified environment setup skipped. Manual setup: user PATH adds $Destination; JAVA_HOME=$JavaHome and PATH adds its bin directory."
        return
    }
    $key = Open-EnvironmentKey
    try {
        $oldPath = Get-RegistryValue $key 'Path'
        $oldJava = Get-RegistryValue $key 'JAVA_HOME'
        foreach ($snapshot in @($oldPath, $oldJava)) {
            if ($snapshot.Exists -and $snapshot.Kind -notin @(1, 2)) { Stop-Installer 'Environment values must be REG_SZ or REG_EXPAND_SZ' }
        }
        $pathValue = [string]$oldPath.Value
        $toolPresent = (Add-UserPath $pathValue $Destination) -ceq $pathValue
        $javaBin = Join-Path $JavaHome 'bin'
        $javaPresent = $oldJava.Exists -and (Test-PathEntry ([string]$oldJava.Value) $JavaHome) -and ((Add-UserPath $pathValue $javaBin) -ceq $pathValue)
        $toolYes = $false; $javaYes = $false
        if (-not $toolPresent) {
            Write-InstallerMessage "HKCU\Environment\Path ($($oldPath.Kind)): add $Destination; preserve raw existing value: $pathValue"
            $toolYes = Get-SetupConsent $PathChoice $Unattended 'Persist tool PATH?'
        }
        if (-not $javaPresent) {
            Write-InstallerMessage "HKCU\Environment: JAVA_HOME '$($oldJava.Value)' -> '$JavaHome'; Path adds $javaBin. A default JDK may not exist yet."
            $javaYes = Get-SetupConsent $JavaChoice $Unattended 'Persist default Java?'
        }
        if (-not $toolYes -and -not $javaYes) {
            Write-InstallerMessage "Environment unchanged. Manual setup: user PATH adds $Destination; JAVA_HOME=$JavaHome and PATH adds $javaBin."
            return
        }
        if ($toolYes) { $pathValue = Add-UserPath $pathValue $Destination }
        if ($javaYes) { $pathValue = Add-UserPath $pathValue $javaBin }
        $backup = Join-Path $State ('environment-backup-' + [Guid]::NewGuid().ToString('N') + '.clixml')
        @{ Path = $oldPath; JAVA_HOME = $oldJava } | Export-Clixml -LiteralPath $backup -Encoding UTF8
        try {
            if ($javaYes) { $key.SetValue('JAVA_HOME', $JavaHome, [Microsoft.Win32.RegistryValueKind]$oldJava.Kind) }
            $key.SetValue('Path', $pathValue, [Microsoft.Win32.RegistryValueKind]$oldPath.Kind)
            $key.Flush()
            Send-EnvironmentChange
        } catch {
            $failure = $_
            try { Set-RegistrySnapshot $key 'Path' $oldPath; Set-RegistrySnapshot $key 'JAVA_HOME' $oldJava; $key.Flush() }
            catch { Write-InstallerMessage "Registry rollback failed; exact raw backup: $backup" }
            throw $failure
        }
        Write-InstallerMessage "Updated HKCU\Environment; raw value/type backup: $backup"
        $systemPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($entry in $systemPath.Split(';')) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim('"'))
            if (-not [IO.Path]::IsPathRooted($expanded)) { continue }
            if ([IO.File]::Exists([IO.Path]::Combine($expanded, 'java.exe'))) { Write-InstallerMessage "System Java at $expanded may precede user PATH. Machine PATH was preserved."; break }
        }
    } finally { $key.Dispose() }
}
function Invoke-JvmInstaller([string[]]$Arguments) {
    $version = ''; $pathChoice = 'ask'; $javaChoice = 'ask'; $unattended = $false
    $seen = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -ieq '-Help') {
            if ($Arguments.Count -ne 1) { Stop-Installer '-Help must be used alone' 2 }
            Write-Output 'Usage: install.ps1 [-Version major.minor.patch] [-Path | -NoPath] [-Java | -NoJava] [-NonInteractive]'
            return
        }
        $group = $arg.ToLowerInvariant()
        if ($group -in @('-path', '-nopath')) { $group = 'path' }
        if ($group -in @('-java', '-nojava')) { $group = 'java' }
        if ($seen.ContainsKey($group)) { Stop-Installer "Duplicate/conflicting option: $arg" 2 }
        $seen[$group] = $true
        switch ($arg.ToLowerInvariant()) {
            '-version' { $i++; if ($i -ge $Arguments.Count -or -not (Test-ToolVersion $Arguments[$i])) { Stop-Installer 'Version must be numeric major.minor.patch without leading zeros' 2 }; $version = $Arguments[$i] }
            '-path' { $pathChoice = 'yes' }
            '-nopath' { $pathChoice = 'no' }
            '-java' { $javaChoice = 'yes' }
            '-nojava' { $javaChoice = 'no' }
            '-noninteractive' { $unattended = $true }
            default { Stop-Installer "Unknown option: $arg" 2 }
        }
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Stop-Installer 'The native installer supports Windows only' }
    $userHome = $env:HOME
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $env:USERPROFILE }
    Assert-SafeRoot $userHome
    $userHome = [IO.Path]::GetFullPath($userHome)
    $data = $env:XDG_DATA_HOME
    if ([string]::IsNullOrEmpty($data) -or $data -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { $data = Join-Path $userHome '.local\share' }
    Assert-SafeRoot $data
    $data = [IO.Path]::GetFullPath($data)
    $destination = Join-Path $userHome '.local\bin'
    $state = Join-Path $data 'jvm\tool-install'
    $javaHome = Join-Path $data 'jvm\jdks\default'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('jvm-bootstrap-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $published = $false
    try {
        if (-not $version) {
            Get-Download 'https://getjvm.dev/latest.txt' (Join-Path $work 'latest.txt')
            $raw = [IO.File]::ReadAllText((Join-Path $work 'latest.txt'))
            if ($raw -cnotmatch '\A((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\n?\z') { Stop-Installer 'Invalid latest.txt version' }
            $version = $Matches[1]
        }
        $base = "https://github.com/codejive/jvm/releases/download/v$version"
        Get-Download "$base/SHA256SUMS" (Join-Path $work 'SHA256SUMS')
        $hashes = Read-ToolChecksums (Join-Path $work 'SHA256SUMS')
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            Get-Download "$base/$name" (Join-Path $work $name)
            if ((Get-ToolHash (Join-Path $work $name)) -cne $hashes[$name]) { Stop-Installer "Checksum mismatch: $name" }
        }
        Publish-Tool $work $state $destination $version $hashes
        $published = $true
        Write-InstallerMessage "Installed jvm $version in $destination"
        Set-UserEnvironment $state $destination $javaHome $pathChoice $javaChoice $unattended
        Write-InstallerMessage 'Open a fresh terminal application/IDE; existing hosts may retain old values. Bash startup files may override inherited PATH; use cygpath -u for native paths there.'
    } catch {
        if ($published) { Write-InstallerMessage 'Tool was installed; persistent environment setup failed.' }
        throw
    } finally {
        if ($script:InstallerLock) { $script:InstallerLock.Dispose(); $script:InstallerLock = $null }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

try { Invoke-JvmInstaller @($args) }
catch {
    Write-InstallerMessage $_.Exception.Message
    $code = 1
    if ($_.Exception.Data.Contains('InstallerCode')) { $code = [int]$_.Exception.Data['InstallerCode'] }
    exit $code
}
