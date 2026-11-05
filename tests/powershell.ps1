param([string]$PowerShellExecutable = (Join-Path $PSHOME 'powershell.exe'))

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "This smoke suite requires Windows PowerShell 5.1; found $($PSVersionTable.PSVersion)."
}

$repository = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $repository 'jvm.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('jvm powershell ' + [guid]::NewGuid().ToString('N'))
$oldEnvironment = @{}
$script:passed = 0
foreach ($name in @('HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'JVM_TEST_ARGS')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Write-TestPass {
    param([string]$Description)
    $script:passed++
    [Console]::Out.WriteLine("ok $script:passed - $Description")
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
    $powershellExe = $PowerShellExecutable
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
        # Mimics typing the command at a prompt, including an unquoted optional separator.
        $words = @(for ($wordIndex = 0; $wordIndex -lt $Arguments.Count; $wordIndex++) {
            if ($wordIndex -eq 2 -and $Arguments[$wordIndex] -ceq '--') { '--' }
            else { "'" + $Arguments[$wordIndex].Replace("'", "''") + "'" }
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

function Assert-DefaultUsage {
    foreach ($command in @('default', 'd')) {
        $invalid = @(@('set'), @('set', ''), @('set', '21', ''), @('set', '', '21'),
            @('set', '21', '21', 'extra'), @('21', 'extra'), @(''), @('set', '25..21'))
        foreach ($scope in @('0', '01', '-1', ' 21', "21`n")) {
            $invalid += ,@($scope)
        }
        foreach ($scope in @('0', '01', '-1', '21+', '21..25', 'temurin-21', ' 21', "21`n")) {
            $invalid += ,@('set', $scope, '21')
        }
        foreach ($arguments in $invalid) {
            $streams = Invoke-JvmTest (@($command) + $arguments) -ExpectedExitCode 2 -Redirect -Streams
            Assert-Equal $streams.Out '' 'Default usage error emitted stdout.'
            if ($streams.Err -notmatch [regex]::Escape('usage: jvm default [<major>] | jvm default set [<major>] <selector>')) {
                throw 'Default usage diagnostic omitted the grammar.'
            }
        }
    }
}

function Invoke-JvmLauncherTest {
    param([string]$ArgumentText, [int]$ExpectedExitCode = 0)
    $stdout = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.out')
    $stderr = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.err')
    $command = '/d /s /c ""' + $launcherPath + '" ' + $ArgumentText + '"'
    $process = Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
        -ArgumentList $command -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $outText = [IO.File]::ReadAllText($stdout).TrimEnd()
    $errText = [IO.File]::ReadAllText($stderr).TrimEnd()
    Remove-Item -LiteralPath $stdout, $stderr -Force
    Assert-Equal ([string]$process.ExitCode) ([string]$ExpectedExitCode) `
        "jvm.cmd $ArgumentText returned the wrong exit code. $outText $errText"
    return [pscustomobject]@{ Out = $outText; Err = $errText }
}

function Assert-CmdEnvironmentPaste {
    param([string]$Output, [string]$JavaHome, [switch]$GraalVM)
    $stdout = Join-Path $testRoot 'cmd-env.out'
    $stderr = Join-Path $testRoot 'cmd-env.err'
    $stdin = Join-Path $testRoot 'cmd-env.in'
    $result = Join-Path $testRoot 'cmd-env.result'
    $probePath = Join-Path $testRoot 'cmd environment probe.ps1'
    [IO.File]::WriteAllText($probePath,
        '$values = @($env:JAVA_HOME, $env:PATH); ' +
        'if ($args.Count -gt 1) { $values += $env:GRAALVM_HOME }; ' +
        '[IO.File]::WriteAllLines($args[0], $values)')
    $probe = '"' + $PowerShellExecutable + '" -NoProfile -NonInteractive -File "' +
        $probePath + '" "' + $result + '"'
    $expected = "$JavaHome`r`n" + (Join-Path $JavaHome 'bin') + ';' + $env:PATH
    if ($GraalVM) { $probe += ' graalvm'; $expected += "`r`n$JavaHome" }
    # Feed separate lines to CMD as if pasted at its prompt, including the comment.
    [IO.File]::WriteAllText($stdin, $Output + "`r`n" + $probe + "`r`nexit`r`n")
    $process = Start-Process -FilePath $env:ComSpec -NoNewWindow -Wait -PassThru `
        -ArgumentList '/d /q /v:off' -RedirectStandardInput $stdin `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Assert-Equal ([string]$process.ExitCode) '0' 'Pasted CMD statements failed.'
    Assert-Equal ([IO.File]::ReadAllText($stderr)) '' 'Pasted CMD statements emitted stderr.'
    Assert-Equal ([IO.File]::ReadAllText($result).TrimEnd()) $expected `
        'Pasted CMD statements did not apply JAVA_HOME and expand PATH.'
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
    # Ignore configuration in the contributor's working directory.
    Push-Location $testRoot
    foreach ($arguments in @(@('--version'), @('--help'), @('list'), @('default'), @('default', '21'))) {
        $streams = Invoke-JvmTest $arguments -Redirect -Streams
        if (-not $streams.Out) { throw 'Primary result was not captured by >.' }
        Assert-Equal $streams.Err '' 'Primary result leaked to stderr.'
    }
    foreach ($command in @('default', 'd')) {
        Assert-Equal (Invoke-JvmTest @($command)) 'No JDK currently set as the default' 'Missing global default mismatch.'
        Assert-Equal (Invoke-JvmTest @($command, '21')) 'No JDK currently set as the default for version 21' 'Missing major default mismatch.'
        Invoke-JvmTest @($command, '--help') | Out-Null
    }
    Assert-DefaultUsage
    if (@(Get-ChildItem -LiteralPath $data, $cache -Force).Count) { throw 'Usage errors or queries created storage.' }
    Write-TestPass 'help, missing default queries, aliases and usage errors without storage mutation'
    $streams = Invoke-JvmTest @('bogus') -ExpectedExitCode 2 -Redirect -Streams
    Assert-Equal $streams.Out '' 'Usage error leaked to stdout.'
    Assert-Equal $streams.Err 'jvm: usage: jvm <command> [selector]; use jvm --help' `
        'Usage error included PowerShell error formatting.'
    if ($streams.Err -notmatch 'jvm:') { throw 'Usage error was not captured by 2>.' }
    Write-TestPass 'usage errors use plain stderr and exit 2'
    $originalScriptPath = $scriptPath
    $programErrorScript = Join-Path $testRoot 'program-error.ps1'
    [IO.File]::WriteAllText($programErrorScript,
        [IO.File]::ReadAllText($scriptPath).Replace('    Invoke-Jvm @($args)',
            "    throw 'synthetic program error'"))
    try {
        $scriptPath = $programErrorScript
        $streams = Invoke-JvmTest @('--version') -ExpectedExitCode 1 -Redirect -Streams
        if ($streams.Err -notmatch 'synthetic program error' -or
            $streams.Err -notmatch 'Exception:|CategoryInfo') {
            throw "Unexpected program error lost its detailed diagnostic: $($streams.Err)"
        }
        [IO.File]::WriteAllText($programErrorScript,
            [IO.File]::ReadAllText($originalScriptPath).Replace('    Invoke-Jvm @($args)',
                "    throw [IO.IOException]::new('synthetic I/O failure')"))
        $streams = Invoke-JvmTest @('--version') -ExpectedExitCode 1 -Redirect -Streams
        Assert-Equal $streams.Err 'jvm: synthetic I/O failure' `
            'Operational exception included PowerShell error formatting.'
    } finally { $scriptPath = $originalScriptPath }
    Write-TestPass 'unexpected errors retain diagnostics and operational errors use plain stderr'
    Invoke-JvmTest @('available', 'not_a_selector') -ExpectedExitCode 2 | Out-Null
    Invoke-JvmTest @('exec') -ExpectedExitCode 2 | Out-Null
    foreach ($alias in @('exec', 'x')) {
        Invoke-JvmTest @($alias, '--help') | Out-Null
        foreach ($tail in @(@(), @('21'), @(''), @('', 'java'), @('21', ''),
            @('21', '--'), @('21', '--', ''), @('_', '--'), @('_', ''))) {
            $streams = Invoke-JvmTest (@($alias) + $tail) -ExpectedExitCode 2 -Redirect -Streams
            Assert-Equal $streams.Out '' 'Malformed exec printed stdout.'
            Assert-Equal $streams.Err 'jvm: usage: jvm exec <selector> [--] <command> [args...]' `
                'Malformed exec omitted its usage diagnostic.'
        }
    }
    foreach ($path in @((Join-Path $data 'jvm'), (Join-Path $cache 'jvm'))) {
        if (Test-Path -LiteralPath $path) { throw 'Malformed exec created manager state.' }
    }
    Write-TestPass 'invalid selectors and malformed exec arguments exit 2 without manager state'

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

    Assert-Equal (Invoke-JvmTest @('--version')) 'jvm 0.2.1' 'Version output mismatch.'
    $list = Invoke-JvmTest @('list')
    if ($list -notmatch [regex]::Escape($id)) { throw "List omitted installed ID $id." }
    Assert-Equal (Invoke-JvmTest @('home', $id)) $install 'Exact-ID home resolution mismatch.'
    Write-TestPass 'version, offline listing and exact-ID home resolution'
    [IO.File]::WriteAllText((Join-Path $testRoot '.jvmrc'), "java=$id`n")
    Push-Location $testRoot
    try {
        Assert-Equal (Invoke-JvmTest @('home')) $install 'Project Java setting was ignored.'
        [IO.File]::WriteAllText((Join-Path $testRoot '.jvmrc'), "java=21+`n")
        foreach ($arguments in @(@('env'), @('e', '-f'), @('e', $id, '-f'))) {
            $configuredEnvironment = Invoke-JvmTest $arguments
            $expectedArguments = switch ($arguments.Count) {
                1 { 'env' }
                2 { 'e -f' }
                3 { "e '$id' -f" }
            }
            $expectedComment = "# Use: iex (& '" + $scriptPath.Replace("'", "''") + "' $expectedArguments)"
            Assert-Equal (($configuredEnvironment -split "`r?`n")[0]) $expectedComment `
                'env usage did not preserve the original arguments.'
            if ($configuredEnvironment -notmatch [regex]::Escape($install)) {
                throw 'Configured env did not select the installed JDK.'
            }
        }
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath (Join-Path $testRoot '.jvmrc')
    }
    Write-TestPass 'project configuration and env usage preserve aliases, selectors and flag order'
    $environment = Invoke-JvmTest @('env', '-f', $id)
    $expectedUsage = "# Use: iex (& '" + $scriptPath.Replace("'", "''") + "' env -f '$id')"
    Assert-Equal (($environment -split "`r?`n")[0]) $expectedUsage 'env usage omitted the quoted script path.'
    $invocationDirectory = Join-Path $testRoot "script's folder"
    [void][IO.Directory]::CreateDirectory($invocationDirectory)
    Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $invocationDirectory 'jvm.ps1')
    Push-Location $testRoot
    try {
        $relativeEnvironment = & ".\script's folder\jvm.ps1" env -f $id
        $usage = ($relativeEnvironment -split "`r?`n")[0]
        Assert-Equal $usage "# Use: iex (& '.\script''s folder\jvm.ps1' env -f '$id')" 'Relative invocation was not preserved and quoted.'
        # Evaluate in a child process to leave this test process's environment intact.
        $checkCommand = $usage.Substring(7) + '; if ($env:JAVA_HOME -cne ' +
            "'" + $install.Replace("'", "''") + "') { exit 1 }"
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $checkCommand
        Assert-Equal ([string]$LASTEXITCODE) '0' 'Copied PowerShell usage command failed.'
    } finally { Pop-Location }
    if ($environment -notmatch [regex]::Escape('$env:JAVA_HOME =')) { throw 'env omitted JAVA_HOME.' }
    if ($environment -notmatch [regex]::Escape('$env:PATH =')) { throw 'env omitted PATH.' }
    Write-TestPass 'env emits JAVA_HOME and PATH with executable usage from a spaced and quoted relative path'

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
    Write-TestPass 'home, env and list support redirection and assignment capture'
    $streams = Invoke-JvmTest @('install', $id) -Redirect -Streams
    Assert-Equal $streams.Err "Already installed $id" 'Install confirmation included error formatting.'
    Assert-Equal $streams.Out '' 'Install confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Already installed') { throw 'Install confirmation was not captured by 2>.' }
    Invoke-JvmTest @('install', $id) | Out-Null
    Write-TestPass 'exact-ID install reuses the installed JDK and confirms on plain stderr'
    $defaultResult = Invoke-JvmTest @('default', 'set', $id)
    if ($defaultResult -notmatch [regex]::Escape("Default JDK set to: $id")) {
        throw 'Default selection did not report the selected ID.'
    }
    $streams = Invoke-JvmTest @('default', 'set', $id) -Redirect -Streams
    Assert-Equal $streams.Out '' 'Default confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Default JDK set to:') { throw 'Default confirmation was not captured by 2>.' }
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Default query mismatch.'
    Write-TestPass 'global default selection, query and confirmation redirection'
    Invoke-JvmTest @('default', 'set', '21', $id) | Out-Null
    Assert-Equal (Invoke-JvmTest @('default', '21')) $id 'Per-major default query mismatch.'
    Assert-Equal (Invoke-JvmTest @('home', '21')) `
        (Join-Path (Join-Path $data 'jvm\jdks') '21') 'Major home should use its stable link.'
    Assert-Equal (Invoke-JvmTest @('home')) (Join-Path (Join-Path $data 'jvm\jdks') 'default') `
        'Default home should use the stable link.'
    foreach ($command in @('default', 'd')) {
        foreach ($selector in @($id, '21', 'temurin-21', '21+', 'temurin-21..21')) {
            Invoke-JvmTest @($command, 'set', $selector) | Out-Null
            Invoke-JvmTest @($command, 'set', '21', $selector) | Out-Null
        }
        Assert-Equal (Invoke-JvmTest @($command, '21')) $id 'Alias major query mismatch.'
        $streams = Invoke-JvmTest @($command, 'set', '22', $id) -ExpectedExitCode 1 -Redirect -Streams
        if ($streams.Err -notmatch 'expected 22') { throw 'Major mismatch omitted expected scope.' }
    }
    $beforeUsage = Invoke-JvmTest @('list')
    Assert-DefaultUsage
    Assert-Equal (Invoke-JvmTest @('list')) $beforeUsage 'Usage errors changed inventory or defaults.'
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Usage errors changed global default.'
    Assert-Equal (Invoke-JvmTest @('default', '21')) $id 'Usage errors changed major default.'
    Write-TestPass 'default scope/selector grammar, aliases, ranges, mismatch and usage failure preservation'
    $probe = Join-Path (Join-Path $install 'bin') 'probe.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $probe
    $execution = Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile',
        '-NonInteractive', '-Command', '[Console]::WriteLine($env:JAVA_HOME); exit 23') `
        -ExpectedExitCode 23
    Assert-Equal $execution $install 'exec did not use the selected JDK PATH and JAVA_HOME.'
    Write-TestPass 'exec sets the selected JDK PATH and JAVA_HOME and returns the child exit code'
    $streams = Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile',
        '-NonInteractive', '-Command', '[Console]::Out.WriteLine("child output"); [Console]::Error.WriteLine("child diagnostic"); exit 23') `
        -ExpectedExitCode 23 -Redirect -Streams
    Assert-Equal $streams.Out 'child output' 'exec stdout was not captured by >.'
    if ($streams.Err -notmatch 'child diagnostic') { throw 'exec stderr was not captured by 2>.' }
    Write-TestPass 'exec forwards child stdout and stderr through PowerShell redirection'
    $argumentProbe = Join-Path $testRoot 'argument probe.ps1'
    [IO.File]::WriteAllText($argumentProbe,
        '[IO.File]::WriteAllText($env:JVM_TEST_ARGS, "<$($args[0])>|<$($args[1])>")')
    Invoke-JvmTest @('exec', $id, '--', 'probe.exe', '-NoProfile', '-NonInteractive',
        '-File', $argumentProbe, '', 'value with spaces') | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<>|<value with spaces>' `
        'exec did not preserve empty and spaced arguments.'
    Write-TestPass 'exec preserves empty arguments and arguments containing spaces'
    foreach ($alias in @('exec', 'x')) {
        foreach ($selector in @($id, '_')) {
            Invoke-JvmTest @($alias, $selector, 'probe.exe', '-NoProfile', '-NonInteractive',
                '-File', $argumentProbe, '--', '$(literal) & * --help') -Interactive | Out-Null
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<-->|<$(literal) & * --help>' `
                'exec did not preserve child arguments without a separator.'
            Invoke-JvmTest @($alias, $selector, '--', 'probe.exe', '-NoProfile', '-NonInteractive',
                '-File', $argumentProbe, 'x', 'y z') -Interactive | Out-Null
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<x>|<y z>' `
                'exec did not accept the optional separator at a prompt.'
            Invoke-JvmTest @($alias, $selector, '--', 'probe.exe', '-NoProfile', '-NonInteractive',
                '-File', $argumentProbe, '', 'two words') | Out-Null
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<>|<two words>' `
                'exec did not preserve arguments through -File.'
        }
    }
    Invoke-JvmTest @('exec', $id, '--', '--', 'probe.exe') -ExpectedExitCode 127 | Out-Null
    Write-TestPass 'exec and x accept selectors and the placeholder, with one optional separator'
    $launcherDirectory = Join-Path $testRoot "launcher's folder & !test! (x)^"
    [void][IO.Directory]::CreateDirectory($launcherDirectory)
    $launcherPath = Join-Path $launcherDirectory 'jvm.cmd'
    Copy-Item -LiteralPath (Join-Path $repository 'jvm.cmd') -Destination $launcherPath
    Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $launcherDirectory 'jvm.ps1')
    foreach ($alias in @('env', 'e')) {
        $streams = Invoke-JvmLauncherTest ($alias + ' -f ' + $id)
        Assert-Equal $streams.Err '' 'CMD env emitted stderr.'
        $lines = $streams.Out -split "`r?`n"
        Assert-Equal $lines[1] ('set "JAVA_HOME=' + $install + '"') 'CMD env omitted JAVA_HOME.'
        Assert-Equal $lines[2] ('set "PATH=' + (Join-Path $install 'bin') + ';%PATH%"') `
            'CMD env did not retain the PATH reference.'
        Assert-Equal $lines[0] 'rem Copy ^& paste these lines into your CMD window' 'CMD copy-and-paste comment mismatch.'
        Assert-CmdEnvironmentPaste $streams.Out $install
    }
    $savedPath = $env:PATH
    try {
        $env:PATH = (Join-Path $install 'bin') + ';' + $savedPath
        $streams = Invoke-JvmLauncherTest ('env ' + $id)
        if ($streams.Out -match '(?m)^set "PATH=') { throw 'CMD env repeated an existing bin entry.' }
        $streams = Invoke-JvmLauncherTest ('env -f ' + $id)
        if ($streams.Out -notmatch '(?m)^set "PATH=') { throw 'CMD env -f omitted PATH.' }
    } finally { $env:PATH = $savedPath }
    $savedData = $env:XDG_DATA_HOME
    try {
        $env:PATH = $savedPath + ';C:\literal %PATH% !bang! (x)^'
        $env:XDG_DATA_HOME = Join-Path $testRoot 'data !bang! & (jdk)^'
        $graalId = '21.0.1-graalvm'
        $graalHome = Join-Path $env:XDG_DATA_HOME ('jvm\jdks\' + $graalId)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $graalHome))
        Copy-Item -LiteralPath $install -Destination $graalHome -Recurse
        $graalFields = @($fields)
        $graalFields[4] = 'graalvm'; $graalFields[6] = 'graalvm'
        [IO.File]::WriteAllText((Join-Path $graalHome '.jvm-manifest'),
            "jvm-manifest-v1`n$($graalFields -join "`t")`n`n", [Text.UTF8Encoding]::new($false))
        $streams = Invoke-JvmLauncherTest ('env -f ' + $graalId)
        Assert-CmdEnvironmentPaste $streams.Out $graalHome -GraalVM
    } finally { $env:XDG_DATA_HOME = $savedData; $env:PATH = $savedPath }
    [void](Invoke-JvmTest @('env', '--cmd', $id) -ExpectedExitCode 2)
    [void](Invoke-JvmTest @('--cmd', '--cmd', 'env', $id) -ExpectedExitCode 2)
    [void](Invoke-JvmLauncherTest '--version')
    Write-TestPass 'CMD env supports copy and paste, PATH expansion, GraalVM and PATH deduplication'
    foreach ($alias in @('exec', 'x')) {
        foreach ($separator in @('', '-- ')) {
            $prefix = $alias + ' _ ' + $separator + 'probe.exe -NoProfile -NonInteractive -File "' + $argumentProbe + '" '
            $streams = Invoke-JvmLauncherTest ($prefix + '"" "two words"')
            Assert-Equal $streams.Out '' 'jvm.cmd printed unexpected stdout.'
            Assert-Equal $streams.Err '' 'jvm.cmd printed unexpected stderr.'
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<>|<two words>' `
                'jvm.cmd did not preserve empty and spaced arguments.'
            [void](Invoke-JvmLauncherTest ($prefix + '"--" "$(1+2) & * --help"'))
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<-->|<$(1+2) & * --help>' `
                'jvm.cmd interpreted literal child arguments.'
            [void](Invoke-JvmLauncherTest ($prefix + '"--cmd" "two words"'))
            Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<--cmd>|<two words>' `
                'jvm.cmd consumed the output signal from child arguments.'
        }
    }
    [void](Invoke-JvmLauncherTest 'x _ probe.exe -NoProfile -NonInteractive -Command "exit 37"' 37)
    [void](Invoke-JvmLauncherTest 'x _' 2)
    Write-TestPass 'jvm.cmd supports the placeholder, spaced launcher paths, literal arguments and exit codes'
    Remove-Item -LiteralPath $argsFile -Force
    $env:PSExecutionPolicyPreference = 'Bypass'
    Invoke-JvmTest @('exec', $id, '--', $argumentProbe, 'a', 'b c') | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile)) '<a>|<b c>' `
        'exec did not run a .ps1 script with its arguments.'
    Write-TestPass 'exec runs PowerShell scripts with their arguments'
    $batchProbe = Join-Path $testRoot 'batch probe.cmd'
    [IO.File]::WriteAllText($batchProbe,
        "@echo off`r`n>`"%JVM_TEST_ARGS%`" echo %JAVA_HOME%^|%~1^|%~2`r`nexit /b 7`r`n")
    Invoke-JvmTest @('exec', $id, $batchProbe, 'a', 'b c') -ExpectedExitCode 7 | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) "$install|a|b c" `
        'exec did not run a .cmd script with its arguments and exit code.'
    Write-TestPass 'exec runs batch scripts with their arguments and exit code'
    Remove-Item -LiteralPath $argsFile -Force
    Invoke-JvmTest @('exec', $id, '--', ($batchProbe -replace '\.cmd$', ''), 'a', 'b c') `
        -ExpectedExitCode 7 | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) "$install|a|b c" `
        'exec did not find a path-qualified command without its extension.'
    Write-TestPass 'exec resolves extensionless path-qualified commands'
    $both = Join-Path $testRoot 'both probe'
    [IO.File]::WriteAllText("$both.cmd", "@echo off`r`n>`"%JVM_TEST_ARGS%`" echo cmd`r`n")
    [IO.File]::WriteAllText("$both.ps1", '[IO.File]::WriteAllText($env:JVM_TEST_ARGS, "ps1")')
    Invoke-JvmTest @('exec', $id, $both) | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($argsFile).Trim()) 'ps1' `
        'exec did not prefer .ps1 over .cmd for an extensionless command.'
    Write-TestPass 'exec prefers .ps1 over .cmd for extensionless commands'

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
    $streams = Invoke-JvmTest @('d', 'set', 'temurin-21') -ExpectedExitCode 1 -Redirect -Streams
    if ($streams.Err -notmatch 'Multiple JDKs match') { throw 'Default setter did not preserve ambiguity.' }
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Ambiguity changed global default.'
    Write-TestPass 'ambiguous selection reports candidate IDs and defaults on stderr'
    Invoke-JvmTest @('install', $secondId) | Out-Null
    foreach ($arguments in @(@('install', '-v', '-v', $id), @('i', '-d', '-v', $id, '-d'),
            @('home', '-v', $id), @('install', '-v', '21', '25'))) {
        [void](Invoke-JvmTest $arguments -ExpectedExitCode 2)
    }
    $streams = Invoke-JvmTest @('install', $secondId, '-v') -Redirect -Streams
    Assert-Equal $streams.Out '' 'install -v wrote to stdout.'
    Assert-Equal ($streams.Err -replace "`r`n", "`n") "Java 21 default JDK set to: $secondId`nAlready installed $secondId" `
        'install -v confirmation mismatch.'
    Assert-Equal (Invoke-JvmTest @('default', '21')) $secondId 'install -v did not replace major default.'
    Assert-Equal (Invoke-JvmTest @('default')) $id 'install -v replaced global default.'
    foreach ($arguments in @(@('i', '-v', $id, '-d'), @('install', '-d', '-v', $secondId))) {
        [void](Invoke-JvmTest $arguments)
        $expectedId = if ($arguments -contains $secondId) { $secondId } else { $id }
        Assert-Equal (Invoke-JvmTest @('default')) $expectedId 'Combined flags lost global selection.'
        Assert-Equal (Invoke-JvmTest @('default', '21')) $expectedId 'Combined flags lost major selection.'
    }
    # A blocked major update stops before global selection; a blocked global
    # update retains the major selection that has already succeeded.
    $majorLink = Join-Path $data 'jvm\jdks\21'
    $globalLink = Join-Path $data 'jvm\jdks\default'
    [IO.Directory]::Delete($majorLink)
    [IO.File]::WriteAllText($majorLink, 'keep')
    [void](Invoke-JvmTest @('install', '-d', '-v', $id) -ExpectedExitCode 1)
    Assert-Equal (Invoke-JvmTest @('default')) $secondId 'Failed major update changed global default.'
    [IO.File]::Delete($majorLink)
    [IO.Directory]::Delete($globalLink)
    [IO.File]::WriteAllText($globalLink, 'keep')
    $streams = Invoke-JvmTest @('install', '-v', $id, '-d') -ExpectedExitCode 1 -Redirect -Streams
    Assert-Equal $streams.Out '' 'Failed combined selection wrote to stdout.'
    Assert-Equal (Invoke-JvmTest @('default', '21')) $id 'Failed global update rolled back major selection.'
    Assert-Equal ([IO.File]::ReadAllText($globalLink)) 'keep' 'Combined flags replaced unrelated data.'
    [IO.File]::Delete($globalLink)
    [void](Invoke-JvmTest @('install', '-v', '-d', $secondId))
    Write-TestPass 'install -v replaces the major default, combines with -d and preserves partial successes'
    Invoke-JvmTest @('default', 'set', $secondId) | Out-Null
    Invoke-JvmTest @('default', 'set', '21', $secondId) | Out-Null
    Assert-Equal (Invoke-JvmTest @('default')) $secondId 'Global default replacement failed.'
    Assert-Equal (Invoke-JvmTest @('default', '21')) $secondId `
        'Per-major default replacement failed.'
    Write-TestPass 'global and per-major default junction replacement'
    $projectConfig = Join-Path $testRoot '.jvmrc'
    $userConfig = Join-Path $config 'jvm\config'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $userConfig))
    foreach ($contents in @("unknown=invalid`n", "java=99`ndistro=unavailable`n")) {
        [IO.File]::WriteAllText($projectConfig, $contents)
        [IO.File]::WriteAllText($userConfig, $contents)
        Invoke-JvmTest @('d', 'set', '21', '21') | Out-Null
        Invoke-JvmTest @('default', 'set', '21') | Out-Null
        Assert-Equal (Invoke-JvmTest @('d')) $secondId 'Configuration affected global default.'
        Assert-Equal (Invoke-JvmTest @('d', '21')) $secondId 'Configuration affected major default.'
    }
    Remove-Item -LiteralPath $projectConfig, $userConfig
    Write-TestPass 'default queries and setters ignore malformed and conflicting configuration'
    $homeProbe = @('probe.exe', '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write($env:JAVA_HOME)')
    # The probe is available in the first JDK; use its physical path for either selection.
    $homeProbe[0] = $probe
    $brokenId = '99.0.1-temurin'
    [void][IO.Directory]::CreateDirectory((Join-Path (Join-Path $data 'jvm\jdks') $brokenId))
    foreach ($alias in @('exec', 'x')) {
        [IO.File]::WriteAllText($userConfig, "java=$secondId`n")
        [IO.File]::WriteAllText($projectConfig, "java=$id`n")
        Assert-Equal (Invoke-JvmTest (@($alias, '_') + $homeProbe)) $install 'Project java did not win.'
        Remove-Item -LiteralPath $projectConfig
        Assert-Equal (Invoke-JvmTest (@($alias, '_', '--') + $homeProbe)) $secondInstall 'User java was ignored.'
        Remove-Item -LiteralPath $userConfig
        Assert-Equal (Invoke-JvmTest (@($alias, '_') + $homeProbe)) $secondInstall 'Global default was ignored.'
        foreach ($value in @('_', '0', $brokenId)) {
            [IO.File]::WriteAllText($projectConfig, "java=$value`n")
            [IO.File]::WriteAllText($userConfig, "java=$secondId`n")
            Invoke-JvmTest (@($alias, '_') + $homeProbe) -Redirect -ExpectedExitCode 1 | Out-Null
            Assert-Equal (Invoke-JvmTest (@($alias, $id) + $homeProbe) -Redirect) $install 'Explicit selector consulted java configuration.'
        }
        Remove-Item -LiteralPath $projectConfig, $userConfig
    }
    Invoke-JvmTest @('uninstall', $brokenId) | Out-Null
    foreach ($command in @('available', 'list', 'install', 'uninstall', 'default', 'home', 'env')) {
        $arguments = if ($command -eq 'default') { @($command, 'set', '_') } else { @($command, '_') }
        Invoke-JvmTest $arguments -Redirect -ExpectedExitCode 2 | Out-Null
    }
    # An unusable default must not use the available fallback major.
    $fallbackId = '25.0.1-temurin'
    $fallbackInstall = Join-Path (Join-Path $data 'jvm\jdks') $fallbackId
    [void][IO.Directory]::CreateDirectory((Join-Path $fallbackInstall 'bin'))
    foreach ($launcher in @('java.exe', 'javac.exe')) {
        [IO.File]::WriteAllText((Join-Path $fallbackInstall "bin\$launcher"), '')
    }
    $fallbackFields = @($fields); $fallbackFields[7] = '25.0.1'; $fallbackFields[8] = '25.0.1'
    [IO.File]::WriteAllText((Join-Path $fallbackInstall '.jvm-manifest'),
        "jvm-manifest-v1`n$($fallbackFields -join "`t")`n`n", [Text.UTF8Encoding]::new($false))
    $defaultLink = Join-Path (Join-Path $data 'jvm\jdks') 'default'
    [IO.Directory]::Delete($defaultLink)
    [IO.File]::WriteAllText($defaultLink, 'unusable default')
    $streams = Invoke-JvmTest (@('exec', '_') + $homeProbe) -Redirect -ExpectedExitCode 1 -Streams
    Assert-Equal $streams.Out '' 'Unusable default ran the child.'
    if (-not $streams.Err) { throw 'Unusable default omitted its diagnostic.' }
    Invoke-JvmTest @('default') -ExpectedExitCode 1 | Out-Null
    Invoke-JvmTest @('d', 'set', $id) -ExpectedExitCode 1 | Out-Null
    Assert-Equal ([IO.File]::ReadAllText($defaultLink)) 'unusable default' 'Failed setter replaced unrelated data.'
    Remove-Item -LiteralPath $defaultLink
    Assert-Equal (Invoke-JvmTest (@('exec', '_') + $homeProbe)) $fallbackInstall 'Fallback major was ignored.'
    Invoke-JvmTest @('uninstall', $fallbackId) | Out-Null
    Invoke-JvmTest @('default', 'set', $secondId) | Out-Null
    Write-TestPass 'exec placeholder resolves project/user/default/fallback and preserves failures and selector boundaries'
    foreach ($selector in @('21+', 'temurin-21..25')) {
        $streams = Invoke-JvmTest @('install', $selector) -Redirect -Streams
        Assert-Equal $streams.Err "Already installed $secondId" 'Range confirmation included error formatting.'
        Assert-Equal $streams.Out '' 'Range install confirmation leaked to stdout.'
        if ($streams.Err -notmatch [regex]::Escape("Already installed $secondId")) {
            throw 'Range install did not reuse the eligible major default.'
        }
    }
    Write-TestPass 'range installs reuse the eligible major default and confirm on plain stderr'
    [IO.File]::WriteAllText((Join-Path $testRoot '.jvmrc'), "java=21+`ndistro=unavailable-vendor`n")
    Push-Location $testRoot
    try {
        $streams = Invoke-JvmTest @('i', '-d') -Redirect -Streams
        if ($streams.Err -notmatch [regex]::Escape("Already installed $secondId")) {
            throw 'Configured range install did not reuse the local JDK.'
        }
    } finally { Pop-Location }
    Assert-Equal (Invoke-JvmTest @('default')) $secondId 'Range install -d selected the wrong JDK.'
    Write-TestPass 'configured range install with -d reuses a local JDK despite the distro preference'
    $streams = Invoke-JvmTest @('uninstall', $secondId) -Redirect -Streams
    Assert-Equal $streams.Out '' 'Uninstall confirmation leaked to stdout.'
    if ($streams.Err -notmatch 'Successfully uninstalled') { throw 'Uninstall confirmation was not captured by 2>.' }
    Assert-Equal (Invoke-JvmTest @('default')) $id 'Global default was not restored after uninstall.'
    Assert-Equal (Invoke-JvmTest @('default', '21')) $id `
        'Per-major default was not restored after uninstall.'
    Write-TestPass 'uninstall confirms on stderr and restores global and per-major defaults'
    Invoke-JvmTest @('uninstall', $id) | Out-Null
    if (Test-Path -LiteralPath $install) { throw 'Uninstall left the installation directory behind.' }
    if (Test-Path -LiteralPath $secondInstall) { throw 'Uninstall left the replacement behind.' }
    Write-TestPass 'uninstall removes both installation directories'

    [Console]::Out.WriteLine("PASS: $script:passed PowerShell smoke checks (offline; synthetic JDKs) using $PowerShellExecutable.")
} finally {
    if ((Get-Location).Path -eq $testRoot) { Pop-Location }
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name])
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
