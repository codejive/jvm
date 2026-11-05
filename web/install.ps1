# MIT License
#
# Copyright (c) 2026 Tako Schotanus
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
function Assert-SafeRoot([string]$Value) {
    if ($Value -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or $Value -match '[;\r\n\t]') {
        Stop-Installer "Expected an absolute native path without semicolons or line breaks: $Value"
    }
}
function Get-Download([string]$Url, [string]$File) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    try { $client.DownloadFile($Url, $File) }
    finally { $client.Dispose() }
}
function Expand-ToolArchive([string]$Work, [string]$Tar) {
    $archive = Join-Path $Work 'jvm.tar.gz'
    $checksum = [IO.File]::ReadAllText((Join-Path $Work 'jvm.tar.gz.sha256'))
    if ($checksum -cnotmatch '\A([0-9a-fA-F]{64})\n?\z') { Stop-Installer 'Invalid archive checksum' }
    if ((Get-ToolHash $archive) -cne $Matches[1].ToLowerInvariant()) { Stop-Installer 'Archive checksum mismatch' }
    $savedOptions = $env:TAR_OPTIONS
    try {
        $env:TAR_OPTIONS = $null
        & $Tar -xzf $archive -C $Work
        if ($LASTEXITCODE -ne 0) { Stop-Installer 'Archive extraction failed' }
    } finally { $env:TAR_OPTIONS = $savedOptions }
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
function Test-SetupAnswer([string]$Answer) { return $Answer -match '\A(?i:|y|yes)\z' }
function Get-InstallationMode([string]$Mode, [bool]$Unattended) {
    if ($Mode) { return $Mode }
    if ($Unattended -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return 'user' }
    Write-InstallerMessage "`nHow would you like to install jvm?`n`n1. Install locally`n   Copy all three jvm scripts to the current directory, without changing your`n   environment. Useful for including jvm in a Java project.`n`n2. Install for your user`n   Install jvm in HOME/.local/bin, with optional PATH and JAVA_HOME setup.`n   Useful for keeping jvm available across projects.`n"
    while ($true) {
        try { $answer = Read-Host 'Choose [1/2] (default: 2)' } catch { return 'user' }
        switch -Exact ($answer) {
            '1' { return 'local' }
            '2' { return 'user' }
            '' { return 'user' }
            default { Write-InstallerMessage 'Please enter 1 or 2.' }
        }
    }
}
function Get-SetupConsent([string]$Choice, [bool]$Unattended, [string]$Prompt) {
    if ($Choice -eq 'yes') { return $true }
    if ($Choice -eq 'no' -or $Unattended -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $false }
    try { return Test-SetupAnswer (Read-Host "$Prompt [Y/n]") } catch { return $false }
}
function Set-UserEnvironment([string]$Destination, [string]$JavaHome, [string]$PathChoice, [string]$JavaChoice, [bool]$Unattended) {
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
        if ((-not $toolPresent -and $PathChoice -ne 'no') -or (-not $javaPresent -and $JavaChoice -ne 'no')) {
            Write-InstallerMessage "`nLet's set up jvm for future terminals.`nThe optional settings below update your user environment variables:`n  PATH and JAVA_HOME (HKCU\Environment)"
        }
        if (-not $toolPresent -and $PathChoice -ne 'no') {
            Write-InstallerMessage "`nRun jvm from any directory?`n`nAdds $Destination to your user PATH.`n`nYes: enable the jvm command in future terminals.`nNo:  leave your Java environment settings unchanged.`n"
            $toolYes = Get-SetupConsent $PathChoice $Unattended 'Enable this?'
        }
        if (-not $javaPresent -and $JavaChoice -ne 'no') {
            $oldJavaDisplay = '<unset>'
            if ($oldJava.Exists) { $oldJavaDisplay = [string]$oldJava.Value }
            Write-InstallerMessage "`nUse jvm's default JDK for Java commands?`n`nSets JAVA_HOME to $JavaHome`n(current value: $oldJavaDisplay)`nand adds its bin directory to your user PATH.`n`nYes: configure future terminals to use jvm's default JDK.`nNo:  leave your Java environment settings unchanged.`n"
            $javaYes = Get-SetupConsent $JavaChoice $Unattended 'Enable this?'
        }
        if (-not $toolYes -and -not $javaYes) {
            Write-InstallerMessage "Environment unchanged. Manual setup: user PATH adds $Destination; JAVA_HOME=$JavaHome and PATH adds $javaBin."
            return
        }
        if ($toolYes) { $pathValue = Add-UserPath $pathValue $Destination }
        if ($javaYes) { $pathValue = Add-UserPath $pathValue $javaBin }
        try {
            if ($javaYes) { $key.SetValue('JAVA_HOME', $JavaHome, [Microsoft.Win32.RegistryValueKind]$oldJava.Kind) }
            $key.SetValue('Path', $pathValue, [Microsoft.Win32.RegistryValueKind]$oldPath.Kind)
            $key.Flush()
            Send-EnvironmentChange
        } catch {
            $failure = $_
            try { Set-RegistrySnapshot $key 'Path' $oldPath; Set-RegistrySnapshot $key 'JAVA_HOME' $oldJava; $key.Flush() }
            catch { Write-InstallerMessage "Registry rollback failed: $($_.Exception.Message)" }
            throw $failure
        }
        $script:EnvironmentChanged = $true
        Write-InstallerMessage 'Updated your user environment settings.'
        $systemPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($entry in $systemPath.Split(';')) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim('"'))
            if (-not [IO.Path]::IsPathRooted($expanded)) { continue }
            if ([IO.File]::Exists([IO.Path]::Combine($expanded, 'java.exe'))) { Write-InstallerMessage "System Java at $expanded may precede user PATH. Machine PATH was preserved."; break }
        }
    } finally { $key.Dispose() }
}
# Inspect managed inventory without executing Java or downloaded scripts.
function Test-InstalledJdk([string]$Data) {
    $inventory = Join-Path $Data 'jvm\jdks'
    if (-not [IO.Directory]::Exists($inventory)) { return $false }
    foreach ($directory in Get-ChildItem -LiteralPath $inventory -Directory -Force -ErrorAction Stop) {
        $id = $directory.Name
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            $id.Length -gt 180 -or $id -ceq 'default' -or $id -match '^(?:-|[0-9]+$)' -or $id -match '[\\/\t\r\n]') { continue }
        $valid = $true
        foreach ($name in @('java', 'javac')) {
            $found = $false
            foreach ($suffix in @('', '.exe', '.bat', '.cmd')) {
                if ([IO.File]::Exists((Join-Path $directory.FullName "bin\$name$suffix"))) { $found = $true; break }
            }
            if (-not $found) { $valid = $false; break }
        }
        if ($valid) { return $true }
    }
    return $false
}
function Invoke-JvmInstaller([string[]]$Arguments) {
    $script:EnvironmentChanged = $false
    $version = ''; $pathChoice = 'ask'; $javaChoice = 'ask'; $unattended = $false; $mode = ''
    $seen = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -ieq '-Help') {
            if ($Arguments.Count -ne 1) { Stop-Installer '-Help must be used alone' 2 }
            Write-Output 'Usage: install.ps1 [-Version major.minor.patch] [-Local | -User] [-Path | -NoPath] [-Java | -NoJava] [-NonInteractive]'
            Write-Output 'Local installation copies all three scripts to the current directory, without setup. Without a terminal, user installation remains the default.'
            return
        }
        $group = $arg.ToLowerInvariant()
        if ($group -in @('-path', '-nopath')) { $group = 'path' }
        if ($group -in @('-java', '-nojava')) { $group = 'java' }
        if ($group -in @('-local', '-user')) { $group = 'mode' }
        if ($seen.ContainsKey($group)) { Stop-Installer "Duplicate/conflicting option: $arg" 2 }
        $seen[$group] = $true
        switch ($arg.ToLowerInvariant()) {
            '-version' { $i++; if ($i -ge $Arguments.Count -or -not (Test-ToolVersion $Arguments[$i])) { Stop-Installer 'Version must be numeric major.minor.patch without leading zeros' 2 }; $version = $Arguments[$i] }
            '-path' { $pathChoice = 'yes' }
            '-nopath' { $pathChoice = 'no' }
            '-java' { $javaChoice = 'yes' }
            '-nojava' { $javaChoice = 'no' }
            '-local' { $mode = 'local' }
            '-user' { $mode = 'user' }
            '-noninteractive' { $unattended = $true }
            default { Stop-Installer "Unknown option: $arg" 2 }
        }
    }
    $mode = Get-InstallationMode $mode $unattended
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Stop-Installer 'The native installer supports Windows only' }
    $tar = Join-Path ([Environment]::SystemDirectory) 'tar.exe'
    if (-not [IO.File]::Exists($tar)) {
        $tarCommand = Get-Command tar.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $tarCommand) { Stop-Installer 'tar.exe is required; use an up-to-date Windows 10 or later' }
        $tar = $tarCommand.Source
    }
    $userHome = $env:HOME
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $env:USERPROFILE }
    Assert-SafeRoot $userHome
    $userHome = [IO.Path]::GetFullPath($userHome)
    $data = $env:XDG_DATA_HOME
    if ([string]::IsNullOrEmpty($data) -or $data -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { $data = Join-Path $userHome '.local\share' }
    Assert-SafeRoot $data
    $data = [IO.Path]::GetFullPath($data)
    $destination = Join-Path $userHome '.local\bin'
    if ($mode -eq 'local') { $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('.') }
    $javaHome = Join-Path $data 'jvm\jdks\default'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('jvm-bootstrap-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $installed = $false
    try {
        if (-not $version) {
            Get-Download 'https://getjvm.dev/latest.txt' (Join-Path $work 'latest.txt')
            $raw = [IO.File]::ReadAllText((Join-Path $work 'latest.txt'))
            if ($raw -cnotmatch '\A((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\n?\z') { Stop-Installer 'Invalid latest.txt version' }
            $version = $Matches[1]
        }
        $base = "https://github.com/codejive/jvm/releases/download/v$version"
        Get-Download "$base/jvm.tar.gz.sha256" (Join-Path $work 'jvm.tar.gz.sha256')
        Get-Download "$base/jvm.tar.gz" (Join-Path $work 'jvm.tar.gz')
        Expand-ToolArchive $work $tar
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            [IO.File]::Copy((Join-Path $work $name), (Join-Path $destination $name), $true)
        }
        $installed = $true
        Write-InstallerMessage "jvm $version installed successfully in $destination."
        if ($mode -eq 'user') { Set-UserEnvironment $destination $javaHome $pathChoice $javaChoice $unattended }
        try {
            $invocation = 'jvm'
            if ($mode -eq 'local') { $invocation = '.\jvm' }
            if (Test-InstalledJdk $data) { Write-InstallerMessage "`nSee your currently installed JDKs with:`n  $invocation list" }
            else { Write-InstallerMessage "`nNo JDK is installed yet. Install one with:`n  $invocation install" }
        } catch { Write-InstallerMessage "Could not check installed JDKs: $($_.Exception.Message)" }
        Write-InstallerMessage 'Setup complete.'
        if ($script:EnvironmentChanged) { Write-InstallerMessage 'Open a new terminal application to use your changes.' }
    } catch {
        if ($installed) { Write-InstallerMessage 'Tool was installed; persistent environment setup failed.' }
        throw
    } finally {
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
