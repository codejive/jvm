# Offline Windows PowerShell 5.1 tests; registry access is confined to a disposable key.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('jvm-installer-test-' + [Guid]::NewGuid().ToString('N'))
$savedHome = $env:HOME; $savedData = $env:XDG_DATA_HOME
$registryPath = 'Software\Codejive\InstallerTests\' + [Guid]::NewGuid().ToString('N')
$count = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Pass([string]$Message) { $script:count++; Write-Output "ok $script:count - $Message" }
function Expect-Failure([scriptblock]$Action, [int]$Code = 1) {
    $failed = $false
    try { & $Action } catch {
        $failed = $true
        if ($_.Exception.Data.Contains('InstallerCode')) { Assert ($_.Exception.Data['InstallerCode'] -eq $Code) 'unexpected error code' }
    }
    Assert $failed 'expected failure'
}
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $env:HOME = Join-Path $temp "home space 'quote' caf$([char]0xe9)"
    $env:XDG_DATA_HOME = Join-Path $temp 'data space'
    $source = [IO.File]::ReadAllText((Join-Path $root 'web\install.ps1'))
    # Load functions, excluding only the public entry point; no production test hooks.
    . ([scriptblock]::Create($source.Substring(0, $source.LastIndexOf('try { Invoke-JvmInstaller @($args) }'))))
    function Open-EnvironmentKey { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath) }
    function Send-EnvironmentChange { if ($script:failNotification) { throw 'injected registry setup failure' } }
    $script:failNotification = $false
    $fixture = Join-Path $temp 'fixture'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $hashes = @{}
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
        [IO.File]::Copy((Join-Path $root $name), (Join-Path $fixture $name))
        $hashes[$name] = Get-ToolHash (Join-Path $fixture $name)
    }
    $sums = @('jvm', 'jvm.ps1', 'jvm.cmd') | ForEach-Object { "$($hashes[$_])  $_" }
    [IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS'), (($sums -join "`n") + "`n"))
    [IO.File]::WriteAllText((Join-Path $fixture 'latest.txt'), "0.2.0`n")
    $script:requests = @()
    $script:downloadFailure = $false
    function Get-Download([string]$Url, [string]$File) {
        $script:requests += $Url
        if ($script:downloadFailure) { throw 'injected HTTP failure' }
        [IO.File]::Copy((Join-Path $fixture ($Url.Split('/')[-1])), $File)
    }
    Invoke-JvmInstaller @('-Help') | Out-Null
    Expect-Failure { Invoke-JvmInstaller @('-Path', '-NoPath') } 2
    Expect-Failure { Invoke-JvmInstaller @('-Version', '01.2.3') } 2
    Expect-Failure { Invoke-JvmInstaller @('-Shell', 'bash') } 2
    Assert ($script:requests.Count -eq 0 -and -not (Test-Path -LiteralPath $env:HOME)) 'help/usage caused side effects'
    Pass 'help and usage validate before networking/storage'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'web\install.ps1') -Help | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'public help exit status'
    # Public invocation must report usage 2, including when launched from CMD.
    $publicInvalid = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'web\install.ps1') + '" -Path -NoPath 2>nul'
    & $env:ComSpec /d /c $publicInvalid
    Assert ($LASTEXITCODE -eq 2) 'CMD public invalid argument exit status'
    Pass 'public PowerShell/CMD entry points and exit statuses'
    Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava')
    $destination = Join-Path $env:HOME '.local\bin'
    $state = Join-Path $env:XDG_DATA_HOME 'jvm\tool-install'
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { Assert ((Get-ToolHash (Join-Path $destination $name)) -ceq $hashes[$name]) "payload differs: $name" }
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:XDG_DATA_HOME 'jvm\jdks'))) 'created JDK storage'
    Assert ($script:requests.Count -eq 5) 'latest should resolve exactly once'
    Pass 'latest, native paths, non-ASCII home and complete exact-byte Windows payload'
    Invoke-JvmInstaller @('-NonInteractive')
    $key = Open-EnvironmentKey
    try { Assert (-not (Get-RegistryValue $key 'Path').Exists -and -not (Get-RegistryValue $key 'JAVA_HOME').Exists) 'unattended implicit edits' } finally { $key.Dispose() }
    Pass 'unspecified unattended setup is skipped'
    $script:requests = @()
    Invoke-JvmInstaller @('-Version', '0.2.0', '-NonInteractive', '-Path', '-Java')
    Assert (-not ($script:requests -like '*latest.txt')) 'pinned version fetched latest'
    $key = Open-EnvironmentKey
    try {
        $before = Get-RegistryValue $key 'Path'
        Assert ($before.Value.Split(';').Count -eq 2) 'expected two whole entries'
        Assert ((Get-RegistryValue $key 'JAVA_HOME').Value -ceq (Join-Path $env:XDG_DATA_HOME 'jvm\jdks\default')) 'wrong stable Java home'
    } finally { $key.Dispose() }
    Invoke-JvmInstaller @('-NonInteractive', '-Path', '-Java')
    $key = Open-EnvironmentKey
    try { Assert ((Get-RegistryValue $key 'Path').Value -ceq $before.Value) 'repeat setup duplicated PATH' } finally { $key.Dispose() }
    Pass 'explicit consent, missing PATH, registry Java setup and idempotence'
    $key = Open-EnvironmentKey
    try {
        $key.SetValue('Path', '%USERPROFILE%\custom;C:\Other Java\bin;;', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.SetValue('JAVA_HOME', 'C:\Old JDK', [Microsoft.Win32.RegistryValueKind]::String)
    } finally { $key.Dispose() }
    Invoke-JvmInstaller @('-NonInteractive', '-Path', '-Java')
    $key = Open-EnvironmentKey
    try {
        Assert ((Get-RegistryValue $key 'Path').Value.EndsWith('%USERPROFILE%\custom;C:\Other Java\bin;;')) 'raw tokens changed'
        Assert ((Get-RegistryValue $key 'Path').Kind -eq 2) 'expandable type changed'
        Assert ((Get-RegistryValue $key 'JAVA_HOME').Kind -eq 1) 'string type changed'
        $oldPath = Get-RegistryValue $key 'Path'; $oldJava = Get-RegistryValue $key 'JAVA_HOME'
        $key.SetValue('Path', 'C:\untouched', [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('JAVA_HOME', 'C:\untouched', [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Dispose() }
    $script:failNotification = $true
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive', '-Path', '-Java') }
    $script:failNotification = $false
    $key = Open-EnvironmentKey
    try {
        Assert ((Get-RegistryValue $key 'Path').Value -ceq 'C:\untouched') 'PATH rollback failed'
        Assert ((Get-RegistryValue $key 'Path').Kind -eq 1) 'PATH type rollback failed'
        Assert ((Get-RegistryValue $key 'JAVA_HOME').Value -ceq 'C:\untouched') 'JAVA_HOME rollback failed'
        Assert ((Get-RegistryValue $key 'JAVA_HOME').Kind -eq 2) 'JAVA_HOME type rollback failed'
    } finally { $key.Dispose() }
    Pass 'raw registry values/types preserved and failed setup rolled back'
    $file = Join-Path $destination 'jvm.cmd'
    [IO.File]::AppendAllText($file, 'modified')
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava') }
    [IO.File]::Copy((Join-Path $fixture 'jvm.cmd'), $file, $true)
    Pass 'locally modified payload refused'
    $goodSums = [IO.File]::ReadAllText((Join-Path $fixture 'SHA256SUMS'))
    foreach ($bad in @('<html>error</html>', ($goodSums + $sums[0]), ($goodSums.Replace('jvm.cmd', '../jvm.cmd')))) {
        [IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS'), $bad)
        Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS'), $goodSums)
    [IO.File]::AppendAllText((Join-Path $fixture 'jvm'), 'corrupt')
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    [IO.File]::Copy((Join-Path $root 'jvm'), (Join-Path $fixture 'jvm'), $true)
    $script:downloadFailure = $true
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    $script:downloadFailure = $false
    Assert ((Get-ToolHash (Join-Path $destination 'jvm')) -ceq $hashes['jvm']) 'failure damaged installed tool'
    Pass 'malformed checksum data, duplicates, paths, checksum mismatch and download failure'
    $lock = [IO.File]::Open((Join-Path $state 'lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Expect-Failure { Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava') } } finally { $lock.Dispose() }
    Pass 'concurrent installer lock refuses a second publisher'
    $tx = Join-Path $state 'transaction'
    [IO.Directory]::CreateDirectory($tx) | Out-Null
    [IO.File]::Copy((Join-Path $state 'record'), (Join-Path $tx 'old-record'))
    [IO.File]::Copy((Join-Path $state 'record'), (Join-Path $tx 'new-record'))
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { [IO.File]::Copy((Join-Path $destination $name), (Join-Path $tx "old-$name")) }
    [IO.File]::WriteAllText((Join-Path $tx 'ready'), 'ready')
    [IO.File]::WriteAllText((Join-Path $destination 'jvm.ps1'), 'interrupted')
    Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava')
    Assert ((Get-ToolHash (Join-Path $destination 'jvm.ps1')) -ceq $hashes['jvm.ps1']) 'recovery failed'
    Assert (-not (Test-Path -LiteralPath $tx)) 'transaction not cleared'
    Pass 'interrupted multi-file publication recovers before retrying'
    $installedTime = [datetime]'2000-01-01'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $destination 'jvm'), $installedTime)
    Invoke-JvmInstaller @('-Version', '0.2.0', '-NonInteractive', '-NoPath', '-NoJava')
    Assert ([IO.File]::GetLastWriteTimeUtc((Join-Path $destination 'jvm')) -eq $installedTime) 'matching reinstall replaced bytes'
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
        [IO.File]::AppendAllText((Join-Path $fixture $name), "`nnew fixture release`n")
        $hashes[$name] = Get-ToolHash (Join-Path $fixture $name)
    }
    $newSums = @('jvm', 'jvm.ps1', 'jvm.cmd') | ForEach-Object { "$($hashes[$_])  $_" }
    [IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS'), (($newSums -join "`n") + "`n"))
    $held = [IO.File]::Open((Join-Path $destination 'jvm.ps1'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Expect-Failure { Invoke-JvmInstaller @('-Version', '0.2.1', '-NonInteractive', '-NoPath', '-NoJava') } }
    finally { $held.Dispose() }
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { Assert ((Get-ToolHash (Join-Path $destination $name)) -ceq (Get-ToolHash (Join-Path $root $name))) 'failed replacement damaged old payload' }
    Assert (-not (Test-Path -LiteralPath $tx)) 'rollback left a transaction'
    Invoke-JvmInstaller @('-Version', '0.2.1', '-NonInteractive', '-NoPath', '-NoJava')
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { Assert ((Get-ToolHash (Join-Path $destination $name)) -ceq $hashes[$name]) 'update did not replace full payload' }
    # Reset fixture to a coherent release for subsequent integration checks.
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
        [IO.File]::Copy((Join-Path $root $name), (Join-Path $fixture $name), $true)
        $hashes[$name] = Get-ToolHash (Join-Path $fixture $name)
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS'), $goodSums)
    Invoke-JvmInstaller @('-Version', '0.2.0', '-NonInteractive', '-NoPath', '-NoJava')
    Pass 'matching reinstall is a no-op, locked-file failure rolls back and owned update succeeds'
    [IO.Directory]::CreateDirectory($tx) | Out-Null
    [IO.File]::WriteAllText((Join-Path $tx 'unknown'), 'preserve')
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava') }
    Assert ([IO.File]::ReadAllText((Join-Path $tx 'unknown')) -ceq 'preserve') 'unknown recovery material deleted'
    [IO.File]::Delete((Join-Path $tx 'unknown')); [IO.Directory]::Delete($tx)
    Pass 'unknown recovery material is retained'
    $env:HOME = 'relative'
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    $env:HOME = Join-Path $temp 'fallback home'
    $dataOverride = $env:XDG_DATA_HOME
    $env:XDG_DATA_HOME = 'C:relative'
    Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-NoJava')
    Assert (Test-Path -LiteralPath (Join-Path $env:HOME '.local\share\jvm\tool-install\record')) 'drive-relative XDG override did not fall back'
    $env:XDG_DATA_HOME = $dataOverride
    $env:HOME = Join-Path $temp 'unowned'
    [IO.Directory]::CreateDirectory((Join-Path $env:HOME '.local\bin')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:HOME '.local\bin\jvm'), 'unowned')
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    Pass 'relative HOME and unowned destination refused'
    $env:JVM_TEST_FIXTURE = $fixture
    $env:JVM_TEST_REGISTRY = $registryPath
    $shim = @'
function Open-EnvironmentKey { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($env:JVM_TEST_REGISTRY) }
function Send-EnvironmentChange {}
function Get-Download([string]$Url, [string]$File) { [IO.File]::Copy((Join-Path $env:JVM_TEST_FIXTURE ($Url.Split('/')[-1])), $File) }
'@
    $env:HOME = Join-Path $temp 'cmd home'
    $env:XDG_DATA_HOME = Join-Path $temp 'cmd data'
    $env:JVM_TEST_BOOTSTRAP = Join-Path $temp 'cmd-bootstrap.ps1'
    [IO.File]::WriteAllText($env:JVM_TEST_BOOTSTRAP, $source.Replace('try { Invoke-JvmInstaller @($args) }', ($shim + "`ntry { Invoke-JvmInstaller @(`$args) }")))
    # Keep the documented bootstrap expression and CMD quote boundaries exact;
    # replace only the HTTP command with a local fixture inside PowerShell.
    $cmdBootstrap = 'powershell.exe -NoProfile -Command "$ErrorActionPreference = ''Stop''; Remove-Item Alias:irm -Force; function irm { param($Url) if ($Url -cne ''https://getjvm.dev/install.ps1'') { throw ''bad URL'' }; [IO.File]::ReadAllText($env:JVM_TEST_BOOTSTRAP) }; iex (irm ''https://getjvm.dev/install.ps1'')"'
    & $env:ComSpec /d /c $cmdBootstrap
    Assert ($LASTEXITCODE -eq 0) 'documented CMD bootstrap quoting failed'
    Assert ((Get-ToolHash (Join-Path $env:HOME '.local\bin\jvm.cmd')) -ceq $hashes['jvm.cmd']) 'CMD bootstrap payload differs'
    Pass 'documented CMD bootstrap expression and quoting with offline HTTP fixture'
    if ($env:JVM_TEST_BASH) {
        # Use the real Bash-to-PowerShell path with in-file test doubles; the shipped
        # bootstrap has no download/registry overrides or arbitrary setup-only API.
        $env:HOME = Join-Path $temp 'bash home'
        $env:XDG_DATA_HOME = Join-Path $temp 'bash data'
        $bootstrap = [IO.File]::ReadAllText((Join-Path $root 'web\install.sh'))
        $bootstrap = $bootstrap.Replace('try { Invoke-JvmInstaller @($args) }', ($shim + "`ntry { Invoke-JvmInstaller @(`$args) }"))
        $bootstrapPath = Join-Path $temp 'bootstrap.sh'
        [IO.File]::WriteAllText($bootstrapPath, $bootstrap, (New-Object Text.UTF8Encoding $false))
        & $env:JVM_TEST_BASH $bootstrapPath --version 0.2.0 --path --java --non-interactive
        Assert ($LASTEXITCODE -eq 0) 'Bash-to-PowerShell bootstrap failed'
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            Assert ((Get-ToolHash (Join-Path $env:HOME ".local\bin\$name")) -ceq $hashes[$name]) 'Bash payload differs'
        }
        # Exercise the installed-system fallback without changing native tools
        # or depending on a particular Windows Bash implementation's PATH.
        $restrictedPath = Join-Path $temp 'restricted-path.sh'
        $restrictedSource = @'
#!/usr/bin/env bash
set -eu
PATH="$(dirname "$(command -v cygpath)"):$(cygpath -u -S)"
export PATH
if command -v powershell.exe >/dev/null; then exit 99; fi
source "$1" --version 0.2.0 --no-path --no-java --non-interactive
'@
        [IO.File]::WriteAllText($restrictedPath, $restrictedSource.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        & $env:JVM_TEST_BASH $restrictedPath $bootstrapPath
        Assert ($LASTEXITCODE -eq 0) 'Windows Bash could not locate system PowerShell outside PATH'
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $env:JVM_TEST_BASH -c 'HOME=relative; source "$1" --version 0.2.0 --no-path --no-java --non-interactive' test $bootstrapPath 2> (Join-Path $temp 'bash-invalid.err')
            $invalidStatus = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        Assert ($invalidStatus -eq 1) 'Windows Bash accepted relative HOME'
        Assert ([IO.File]::ReadAllText((Join-Path $temp 'bash-invalid.err')) -like '*HOME must be absolute*') 'Windows Bash did not reject HOME before publication'
        Pass 'real Windows Bash delegates publication and registry setup to embedded PowerShell'
    }
    Write-Output "$count PowerShell installer checks passed"
} finally {
    $env:HOME = $savedHome; $env:XDG_DATA_HOME = $savedData
    Remove-Item Env:JVM_TEST_FIXTURE, Env:JVM_TEST_REGISTRY, Env:JVM_TEST_BOOTSTRAP -ErrorAction SilentlyContinue
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
    if (([IO.Path]::GetFullPath($temp)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
