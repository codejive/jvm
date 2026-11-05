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
    function Write-ArchiveFixture {
        & "$env:SystemRoot\System32\tar.exe" -czf (Join-Path $fixture 'jvm.tar.gz') -C $fixture jvm jvm.ps1 jvm.cmd latest.txt
        Assert ($LASTEXITCODE -eq 0) 'fixture archive creation failed'
        [IO.File]::WriteAllText((Join-Path $fixture 'jvm.tar.gz.sha256'), ((Get-ToolHash (Join-Path $fixture 'jvm.tar.gz')) + "`n"))
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'latest.txt'), "0.2.0`n")
    Write-ArchiveFixture
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
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { Assert ((Get-ToolHash (Join-Path $destination $name)) -ceq $hashes[$name]) "payload differs: $name" }
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:XDG_DATA_HOME 'jvm\jdks'))) 'created JDK storage'
    Assert ($script:requests.Count -eq 3) 'expected latest, one checksum and one archive'
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
    $goodSums = [IO.File]::ReadAllText((Join-Path $fixture 'jvm.tar.gz.sha256'))
    foreach ($bad in @('<html>error</html>', ($goodSums + $goodSums), ($goodSums.Trim() + '  jvm.tar.gz'))) {
        [IO.File]::WriteAllText((Join-Path $fixture 'jvm.tar.gz.sha256'), $bad)
        Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'jvm.tar.gz.sha256'), $goodSums)
    [IO.File]::AppendAllText((Join-Path $fixture 'jvm.tar.gz'), 'corrupt')
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    Write-ArchiveFixture
    $script:downloadFailure = $true
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    $script:downloadFailure = $false
    Assert ((Get-ToolHash (Join-Path $destination 'jvm')) -ceq $hashes['jvm']) 'failure damaged installed tool'
    Pass 'malformed or multiple digests, checksum mismatch and download failure'
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
        [IO.File]::AppendAllText((Join-Path $fixture $name), "`nnew fixture release`n")
        $hashes[$name] = Get-ToolHash (Join-Path $fixture $name)
    }
    Write-ArchiveFixture
    Invoke-JvmInstaller @('-Version', '0.2.1', '-NonInteractive', '-NoPath', '-NoJava')
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { Assert ((Get-ToolHash (Join-Path $destination $name)) -ceq $hashes[$name]) 'update did not replace full payload' }
    # Reset fixture to a coherent release for subsequent integration checks.
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
        [IO.File]::Copy((Join-Path $root $name), (Join-Path $fixture $name), $true)
        $hashes[$name] = Get-ToolHash (Join-Path $fixture $name)
    }
    Write-ArchiveFixture
    Invoke-JvmInstaller @('-Version', '0.2.0', '-NonInteractive', '-NoPath', '-NoJava')
    Pass 'explicit version update replaces all three scripts'
    $env:HOME = 'relative'
    Expect-Failure { Invoke-JvmInstaller @('-NonInteractive') }
    $env:HOME = Join-Path $temp 'fallback home'
    $dataOverride = $env:XDG_DATA_HOME
    $env:XDG_DATA_HOME = 'C:relative'
    Invoke-JvmInstaller @('-NonInteractive', '-NoPath', '-Java')
    $key = Open-EnvironmentKey
    try { Assert ((Get-RegistryValue $key 'JAVA_HOME').Value -ceq (Join-Path $env:HOME '.local\share\jvm\jdks\default')) 'drive-relative XDG override did not fall back' } finally { $key.Dispose() }
    $env:XDG_DATA_HOME = $dataOverride
    Pass 'relative HOME refused and relative XDG uses fallback for Java setup'
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
    Write-Output "$count PowerShell installer checks passed"
} finally {
    $env:HOME = $savedHome; $env:XDG_DATA_HOME = $savedData
    Remove-Item Env:JVM_TEST_FIXTURE, Env:JVM_TEST_REGISTRY, Env:JVM_TEST_BOOTSTRAP -ErrorAction SilentlyContinue
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
    if (([IO.Path]::GetFullPath($temp)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
