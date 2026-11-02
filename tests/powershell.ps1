$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "This smoke suite requires Windows PowerShell 5.1; found $($PSVersionTable.PSVersion)."
}

$repository = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $repository 'jvm.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('jvm powershell ' + [guid]::NewGuid().ToString('N'))
$oldEnvironment = @{}
foreach ($name in @('HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'JVM_TEST_ARGS')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Assert-Equal {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Invoke-JvmTest {
    param([string[]]$Arguments, [int]$ExpectedExitCode = 0, [switch]$Interactive,
        [switch]$Redirect, [switch]$Capture, [switch]$Streams)
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $stdout = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.out')
    $stderr = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.err')
    $redirectOut = "$stdout.redirect"
    $redirectErr = "$stderr.redirect"
    if ($Redirect -or $Capture) {
        $words = @($Arguments | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
        $invocation = "& '$scriptPath' " + ($words -join ' ')
        if ($Capture) {
            $command = '$captured = ' + $invocation + " 2> '$redirectErr'; " +
                '$code = $LASTEXITCODE; $captured > ' + "'$redirectOut'; exit " + '$code'
        } else {
            $command = $invocation + " > '$redirectOut' 2> '$redirectErr'; exit " + '$LASTEXITCODE'
        }
        $allArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-Command', $command)
    } elseif ($Interactive) {
        # Mimics typing the command at a prompt, where an unquoted --- reaches the script.
        $words = @($Arguments | ForEach-Object {
            if ($_ -ceq '---') { '---' } else { "'" + ([string]$_).Replace("'", "''") + "'" }
        })
        $command = "& '$scriptPath' " + ($words -join ' ')
        $allArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-Command', $command)
    } else {
        $allArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath) + $Arguments
    }
    $quotedArguments = @($allArguments | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    })
    $process = Start-Process -FilePath $powershellExe `
        -ArgumentList ($quotedArguments -join ' ') -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $code = $process.ExitCode
    $outText = [IO.File]::ReadAllText($stdout)
    $errText = [IO.File]::ReadAllText($stderr)
    if ($Redirect -or $Capture) {
        Assert-Equal $outText '' 'Output bypassed PowerShell stdout redirection.'
        Assert-Equal $errText '' 'Output bypassed PowerShell stderr redirection.'
        $outText = [IO.File]::ReadAllText($redirectOut)
        $errText = [IO.File]::ReadAllText($redirectErr)
        Remove-Item -LiteralPath $redirectOut, $redirectErr -Force
    }
    $output = $outText + $errText
    Remove-Item -LiteralPath $stdout, $stderr -Force
    if ($code -ne $ExpectedExitCode) {
        throw "jvm.ps1 $($Arguments -join ' ') exited $code; expected $ExpectedExitCode.`n$output"
    }
    if ($Streams) { return [pscustomobject]@{ Out = $outText.TrimEnd(); Err = $errText.TrimEnd() } }
    return $output.TrimEnd()
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $homeDir = Join-Path $testRoot 'home'
    $data = Join-Path $testRoot 'data root'
    $cache = Join-Path $testRoot 'cache root'
    $config = Join-Path $testRoot 'config root'
    foreach ($path in @($homeDir, $data, $cache, $config)) {
        [void][IO.Directory]::CreateDirectory($path)
    }
    [Environment]::SetEnvironmentVariable('HOME', $homeDir)
    [Environment]::SetEnvironmentVariable('XDG_DATA_HOME', $data)
    [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME', $cache)
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $config)
    $argsFile = Join-Path $testRoot 'exec arguments.txt'
    [Environment]::SetEnvironmentVariable('JVM_TEST_ARGS', $argsFile)
    foreach ($arguments in @(@('--version'), @('--help'), @('list'), @('default'), @('default', '-v', '21'))) {
        $streams = Invoke-JvmTest $arguments -Redirect -Streams
        if (-not $streams.Out) { throw 'Primary result was not captured by >.' }
        Assert-Equal $streams.Err '' 'Primary result leaked to stderr.'
    }
    $streams = Invoke-JvmTest @('bogus') -ExpectedExitCode 2 -Redirect -Streams
    Assert-Equal $streams.Out '' 'Usage error leaked to stdout.'
    if ($streams.Err -notmatch 'jvm:') { throw 'Usage error was not captured by 2>.' }
    Invoke-JvmTest @('available', 'not_a_selector') -ExpectedExitCode 2 | Out-Null
    Invoke-JvmTest @('exec') -ExpectedExitCode 2 | Out-Null

    $archValue = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $archValue) { $archValue = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    switch -Regex ($archValue) {
        '^(AMD64|x64)$' { $arch = 'x86_64'; break }
        '^(ARM64|AArch64)$' { $arch = 'aarch64'; break }
        '^(x86|i[3-6]86)$' { $arch = 'i686'; break }
        default { throw "Unsupported test architecture: $archValue" }
    }
    $id = '21.0.1-temurin'
    $install = Join-Path (Join-Path $data 'jvm\jdks') $id
    [void][IO.Directory]::CreateDirectory((Join-Path $install 'bin'))
    [IO.File]::WriteAllText((Join-Path $install 'bin\java.exe'), '')
    [IO.File]::WriteAllText((Join-Path $install 'bin\javac.exe'), '')
    $fields = @(
        'ga', 'windows', $arch, 'jdk', 'hotspot', '', 'temurin',
        '21.0.1', '21.0.1', 'zip', 'https://example.invalid/jdk.zip',
        '', '', ('0' * 64), '[]'
    )
    $manifest = "jvm-manifest-v1`n$($fields -join "`t")`n`n"
    [IO.File]::WriteAllText((Join-Path $install '.jvm-manifest'), $manifest,
        [Text.UTF8Encoding]::new($false))

    Assert-Equal (Invoke-JvmTest @('--version')) 'jvm 0.2.0' 'Version output mismatch.'
    $list = Invoke-JvmTest @('list')
    if ($list -notmatch [regex]::Escape($id)) { throw "List omitted installed ID $id." }
    Assert-Equal (Invoke-JvmTest @('home', $id)) $install 'Exact-ID home resolution mismatch.'
    [IO.File]::WriteAllText((Join-Path $testRoot '.jvmrc'), "java=$id`n")
    Push-Location $testRoot
    try { Assert-Equal (Invoke-JvmTest @('home')) $install 'Project Java setting was ignored.' }
    finally { Pop-Location }
    $environment = Invoke-JvmTest @('env', '-f', $id)
    if ($environment -notmatch [regex]::Escape('$env:JAVA_HOME =')) { throw 'env omitted JAVA_HOME.' }
    if ($environment -notmatch [regex]::Escape('$env:PATH =')) { throw 'env omitted PATH.' }

    foreach ($arguments in @(@('home', $id), @('env', '-f', $id), @('list'))) {
        $streams = Invoke-JvmTest $arguments -Redirect -Streams
        if (-not $streams.Out) { throw 'Primary result was not captured by >.' }
        Assert-Equal $streams.Err '' 'Primary result leaked to stderr.'
    }
    $streams = Invoke-JvmTest @('home', $id) -Capture -Streams
    Assert-Equal $streams.Out $install 'Assignment capture lost the home path.'
    Assert-Equal $streams.Err '' 'Assignment capture emitted stderr.'
    $streams = Invoke-JvmTest @('env', '-f', $id) -Capture -Streams
    Assert-Equal $streams.Out $environment 'Assignment capture lost environment statements.'
    Assert-Equal $streams.Err '' 'Environment assignment capture emitted stderr.'
    $streams = Invoke-JvmTest @('install', $id) -Redirect -Streams
    Assert-Equal $streams.Out '' 'Install confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Already installed') { throw 'Install confirmation was not captured by 2>.' }
    Invoke-JvmTest @('install', $id) | Out-Null
    $defaultResult = Invoke-JvmTest @('default', $id)
    if ($defaultResult -notmatch [regex]::Escape("Default JDK set to: $id")) {
        throw 'Default selection did not report the selected ID.'
    }
    $streams = Invoke-JvmTest @('default', $id) -Redirect -Streams
    Assert-Equal $streams.Out '' 'Default confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Default JDK set to:') { throw 'Default confirmation was not captured by 2>.' }
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Default query mismatch.'
    Invoke-JvmTest @('default', '-v', '21', $id) | Out-Null
    Assert-Equal (Invoke-JvmTest @('default', '-v', '21')) $id 'Per-major default query mismatch.'
    Assert-Equal (Invoke-JvmTest @('home', '21')) `
        (Join-Path (Join-Path $data 'jvm\jdks') '21') 'Major home should use its stable link.'
    Assert-Equal (Invoke-JvmTest @('home')) (Join-Path (Join-Path $data 'jvm\jdks') 'default') `
        'Default home should use the stable link.'
    $probe = Join-Path (Join-Path $install 'bin') 'probe.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $probe
    $execution = Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile',
        '-NonInteractive', '-Command', '[Console]::WriteLine($env:JAVA_HOME); exit 23') `
        -ExpectedExitCode 23
    Assert-Equal $execution $install 'exec did not use the selected JDK PATH and JAVA_HOME.'
    $streams = Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile',
        '-NonInteractive', '-Command', '[Console]::Out.WriteLine("child output"); [Console]::Error.WriteLine("child diagnostic"); exit 23') `
        -ExpectedExitCode 23 -Redirect -Streams
    Assert-Equal $streams.Out 'child output' 'exec stdout was not captured by >.'
    if ($streams.Err -notmatch 'child diagnostic') { throw 'exec stderr was not captured by 2>.' }
    $argumentProbe = Join-Path $testRoot 'argument probe.ps1'
    [IO.File]::WriteAllText($argumentProbe,
        '[IO.File]::WriteAllText($env:JVM_TEST_ARGS, "<$($args[0])>|<$($args[1])>")')
    Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile', '-NonInteractive',
        '-File', $argumentProbe, '', 'value with spaces') | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<>|<value with spaces>' `
        'exec did not preserve empty and spaced arguments.'
    Invoke-JvmTest @('exec', $id, '---', 'probe.exe', '-NoProfile', '-NonInteractive',
        '-File', $argumentProbe, 'x', 'y z') -Interactive | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<x>|<y z>' `
        'exec did not accept an unquoted --- separator from a PowerShell prompt.'
    Invoke-JvmTest @('exec', $id, '---', 'probe.exe', '-NoProfile', '-NonInteractive',
        '-File', $argumentProbe, '---', 'z') | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<--->|<z>' `
        'exec did not treat only the first --- as the separator.'
    Remove-Item -LiteralPath $argsFile -Force
    $env:PSExecutionPolicyPreference = 'Bypass'
    Invoke-JvmTest @('exec', $id, '--', $argumentProbe, 'a', 'b c') | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<a>|<b c>' `
        'exec did not run a .ps1 script with its arguments.'
    $batchProbe = Join-Path $testRoot 'batch probe.cmd'
    [IO.File]::WriteAllText($batchProbe,
        "@echo off`r`n>`"%JVM_TEST_ARGS%`" echo %JAVA_HOME%^|%~1^|%~2`r`nexit /b 7`r`n")
    Invoke-JvmTest @('exec', $id, '--', $batchProbe, 'a', 'b c') -ExpectedExitCode 7 | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) "$install|a|b c" `
        'exec did not run a .cmd script with its arguments and exit code.'
    Remove-Item -LiteralPath $argsFile -Force
    Invoke-JvmTest @('exec', $id, '--', ($batchProbe -replace '\.cmd$', ''), 'a', 'b c') `
        -ExpectedExitCode 7 | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) "$install|a|b c" `
        'exec did not find a path-qualified command without its extension.'
    $both = Join-Path $testRoot 'both probe'
    [IO.File]::WriteAllText("$both.cmd", "@echo off`r`n>`"%JVM_TEST_ARGS%`" echo cmd`r`n")
    [IO.File]::WriteAllText("$both.ps1", '[IO.File]::WriteAllText($env:JVM_TEST_ARGS, "ps1")')
    Invoke-JvmTest @('exec', $id, '--', $both) | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) 'ps1' `
        'exec did not prefer .ps1 over .cmd for an extensionless command.'

    $secondId = '21.0.2-temurin'
    $secondInstall = Join-Path (Join-Path $data 'jvm\jdks') $secondId
    [void][IO.Directory]::CreateDirectory((Join-Path $secondInstall 'bin'))
    [IO.File]::WriteAllText((Join-Path $secondInstall 'bin\java.exe'), '')
    [IO.File]::WriteAllText((Join-Path $secondInstall 'bin\javac.exe'), '')
    $secondFields = @($fields)
    $secondFields[7] = '21.0.2'
    $secondFields[8] = '21.0.2'
    $secondManifest = "jvm-manifest-v1`n$($secondFields -join "`t")`n`n"
    [IO.File]::WriteAllText((Join-Path $secondInstall '.jvm-manifest'), $secondManifest,
        [Text.UTF8Encoding]::new($false))
    $streams = Invoke-JvmTest @('home', 'temurin-21') -ExpectedExitCode 1 -Redirect -Streams
    Assert-Equal $streams.Out '' 'Ambiguity table leaked to stdout.'
    foreach ($text in @('Multiple JDKs match', 'DEFAULT', $id, $secondId)) {
        if ($streams.Err -notmatch [regex]::Escape($text)) { throw "Ambiguity stderr omitted $text." }
    }
    Invoke-JvmTest @('install', $secondId) | Out-Null
    Invoke-JvmTest @('default', $secondId) | Out-Null
    Invoke-JvmTest @('default', '-v', '21', $secondId) | Out-Null
    Assert-Equal (Invoke-JvmTest @('default')) $secondId 'Global default replacement failed.'
    Assert-Equal (Invoke-JvmTest @('default', '-v', '21')) $secondId `
        'Per-major default replacement failed.'
    $streams = Invoke-JvmTest @('uninstall', $secondId) -Redirect -Streams
    Assert-Equal $streams.Out '' 'Uninstall confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Successfully uninstalled') { throw 'Uninstall confirmation was not captured by 2>.' }
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Global default was not restored after uninstall.'
    Assert-Equal (Invoke-JvmTest @('default', '-v', '21')) $id `
        'Per-major default was not restored after uninstall.'
    Invoke-JvmTest @('uninstall', $id) | Out-Null
    if (Test-Path -LiteralPath $install) { throw 'Uninstall left the installation directory behind.' }
    if (Test-Path -LiteralPath $secondInstall) { throw 'Uninstall left the replacement behind.' }

    [Console]::Out.WriteLine("PowerShell $($PSVersionTable.PSVersion) isolated smoke checks passed.")
} finally {
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name])
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
