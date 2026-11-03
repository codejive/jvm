$ErrorActionPreference = 'Stop'

$script:DefaultDistro = 'temurin'
$script:DefaultVersion = '25'

$script:ScriptInvocation = $MyInvocation
$script:Version = '0.2.0'
$script:BaseUrl = 'https://getjvm.dev/index'
$script:ExitCode = 1
$script:CommandExitCode = 0
$script:DataPath = $null
$script:JdksPath = $null
$script:CachePath = $null
$script:HostReady = $false
$script:WorkPath = $null
$script:StagePath = $null
$script:CurrentDefault = $null
$script:ProjectConfig = $null
$script:GlobalConfig = $null

function Stop-Jvm {
    param([string]$Message, [int]$Code = 1)
    $script:ExitCode = $Code
    $exception = [Exception]::new($Message)
    $exception.Data['JvmExpected'] = $true
    throw $exception
}

function Test-ExistingInstallationDirectory {
    param([string]$Id)
    if (-not (Test-LocalId $Id)) { return $false }
    Initialize-DataPath
    $path = Join-Path $script:JdksPath $Id
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    return -not ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Write-JvmError {
    param([string]$Message)
    Write-JvmDiagnostic "jvm: $Message"
}

# Use PowerShell streams so callers can redirect, merge or capture script output.
# Native stderr records display only their message. An anonymous command avoids
# appending a function name to the formatting ID. Continue keeps stream 2 output
# from aborting under our Stop policy.
function Write-JvmDiagnostic {
    param([string]$Message)
    $record = [System.Management.Automation.ErrorRecord]::new(
        [Exception]::new($Message), 'NativeCommandErrorMessage',
        [System.Management.Automation.ErrorCategory]::FromStdErr, $null)
    & { [CmdletBinding()] param($Item); $PSCmdlet.WriteError($Item) } $record -ErrorAction Continue
}

function Get-AbsolutePath {
    param([string]$Path, [string]$Fallback)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and [IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    if ([string]::IsNullOrWhiteSpace($Fallback) -or -not [IO.Path]::IsPathRooted($Fallback)) {
        Stop-Jvm "need an absolute HOME or XDG directory"
    }
    return [IO.Path]::GetFullPath($Fallback)
}

function Get-HomePath {
    $homePath = [Environment]::GetEnvironmentVariable('HOME')
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = [Environment]::GetEnvironmentVariable('USERPROFILE')
    }
    if ([string]::IsNullOrWhiteSpace($homePath)) {
        Stop-Jvm 'need an absolute HOME'
    }
    return Get-AbsolutePath $homePath $null
}

function Initialize-DataPath {
    if ($script:DataPath) { return }
    $homePath = Get-HomePath
    $base = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME')
    if ([string]::IsNullOrWhiteSpace($base) -or -not [IO.Path]::IsPathRooted($base)) {
        $base = Join-Path $homePath '.local\share'
    }
    $script:DataPath = Join-Path (Get-AbsolutePath $base $homePath) 'jvm'
    $script:JdksPath = Join-Path $script:DataPath 'jdks'
}

function Initialize-CachePath {
    if ($script:CachePath) { return }
    $homePath = Get-HomePath
    $base = [Environment]::GetEnvironmentVariable('XDG_CACHE_HOME')
    if ([string]::IsNullOrWhiteSpace($base) -or -not [IO.Path]::IsPathRooted($base)) {
        $base = Join-Path $homePath '.cache'
    }
    $script:CachePath = Join-Path (Get-AbsolutePath $base $homePath) 'jvm'
    [void][IO.Directory]::CreateDirectory($script:CachePath)
}

function Initialize-Host {
    if ($script:HostReady) { return }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-Jvm 'jvm requires Windows'
    }
    $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if ([string]::IsNullOrWhiteSpace($machine)) {
        $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    }
    switch -Regex ($machine) {
        '^(AMD64|x64)$' { $script:Arch = 'x86_64'; break }
        '^(ARM64|AArch64)$' { $script:Arch = 'aarch64'; break }
        '^(x86|i[3-6]86)$' { $script:Arch = 'i686'; break }
        default { Stop-Jvm "unsupported architecture: Windows/$machine" }
    }
    $script:Os = 'windows'
    Initialize-DataPath
    $script:HostReady = $true
}

function ConvertTo-Major {
    param([string]$Version)
    if ($Version -match '^1\.') { $Version = $Version.Substring(2) }
    if ($Version -match '^([0-9]+)') { return $Matches[1] }
    return ''
}

function Compare-Major {
    param([string]$Left, [string]$Right)
    $a = $Left.TrimStart('0')
    $b = $Right.TrimStart('0')
    if (-not $a) { $a = '0' }
    if (-not $b) { $b = '0' }
    if ($a.Length -ne $b.Length) {
        if ($a.Length -gt $b.Length) { return 1 }
        return -1
    }
    return [string]::CompareOrdinal($a, $b)
}

function Test-Major {
    param([string]$Value)
    return $Value -cmatch '^[1-9][0-9]*$'
}

function Get-Selector {
    param([string]$Value)
    $result = [ordered]@{
        Kind = 'invalid'; Distro = ''; Major = ''; Min = ''; Max = ''
    }
    if ($Value -cmatch '^(?:(?<distro>[a-z][a-z0-9-]*)-)?(?<min>[1-9][0-9]*)\+$') {
        $result.Kind = 'range'; $result.Distro = $Matches.distro
        $result.Min = $Matches.min
    } elseif ($Value -cmatch '^(?:(?<distro>[a-z][a-z0-9-]*)-)?(?<min>[1-9][0-9]*)\.\.(?<max>[1-9][0-9]*)$') {
        if ((Compare-Major $Matches.min $Matches.max) -le 0) {
            $result.Kind = 'range'; $result.Distro = $Matches.distro
            $result.Min = $Matches.min; $result.Max = $Matches.max
        }
    } elseif ([string]::IsNullOrEmpty($Value)) {
        $result.Kind = 'empty'
    } elseif (Test-Major $Value) {
        $result.Kind = 'major'; $result.Major = $Value
    } elseif ($Value -cmatch '^(?<distro>[a-z][a-z0-9-]*)-(?<major>[1-9][0-9]*)$') {
        $result.Kind = 'distro-major'; $result.Distro = $Matches.distro
        $result.Major = $Matches.major
    } elseif ($Value -cmatch '^[a-z][a-z0-9-]*$') {
        $result.Kind = 'distro'; $result.Distro = $Value
    } elseif (Test-SafeId $Value) {
        $result.Kind = 'id'
    }
    return [pscustomobject]$result
}

function Test-SafeId {
    param([string]$Id)
    return ($Id.Length -le 180 -and $Id -cmatch '^[0-9][a-zA-Z0-9._+-]*-[a-z][a-z0-9-]*$' -and
        $Id -cnotmatch '\.\.' -and $Id -cnotmatch '\.$')
}

function Test-LocalId {
    param([string]$Id)
    return ($Id.Length -le 180 -and $Id -cne '' -and $Id -cne '.' -and
        $Id -cne '..' -and $Id -cne 'default' -and $Id -notmatch '^-' -and
        $Id -notmatch '[\\/\t\r\n]' -and $Id -notmatch '^[0-9]+$')
}

function Get-InstallId {
    param([string]$Version, [string]$Distro, [string]$Major)
    $id = "$Version-$Distro"
    $leading = ''
    if ($id -match '^([0-9]+)') { $leading = $Matches[1] }
    if ($leading -ceq $Major) { return $id }
    return "$Major-$id"
}

function Test-EligibleIndexRow {
    param([string[]]$Fields)
    return ($Fields[0] -in @('ga', 'ea') -and $Fields[1] -ceq $script:Os -and
        $Fields[2] -ceq $script:Arch -and $Fields[3] -ceq 'jdk' -and
        $Fields[9] -in @('tar.gz', 'zip') -and
        $Fields[14] -notmatch '(^\[|,)musl(,|\]$)')
}

function Get-IndexRows {
    param([string]$Body)
    $rows = New-Object System.Collections.Generic.List[object]
    $lines = $Body -split "`n"
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd("`r")
        if (-not $line) { continue }
        $fields = $line.Split([char]9)
        if (-not (Test-EligibleIndexRow $fields)) { continue }
        $major = ConvertTo-Major $fields[7]
        $rows.Add([pscustomobject]@{
            Release = $fields[0]; OS = $fields[1]; Arch = $fields[2]
            JVM = $fields[4]; Distro = $fields[6]; JavaVersion = $fields[7]
            Version = $fields[8]; Format = $fields[9]; Url = $fields[10]
            Size = $fields[12]; Sha = $fields[13].ToLowerInvariant()
            Features = $fields[14]; Source = $line
            Id = Get-InstallId $fields[8] $fields[6] $major
            Major = $major; Status = '.'
        })
    }
    return $rows.ToArray()
}

function Invoke-HttpsTransfer {
    param(
        [string]$Url, [string]$OutputPath, [string]$Validator = '',
        [string]$ValidatorValue = '', [int]$TimeoutSeconds = 45
    )
    $tls12 = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    $current = [Uri]$Url
    for ($redirect = 0; $redirect -le 10; $redirect++) {
        if ($current.Scheme -cne 'https' -or $current.UserInfo) {
            Stop-Jvm 'refusing non-HTTPS transfer or redirect'
        }
        $request = [Net.HttpWebRequest]::Create($current)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.UserAgent = 'jvm/0.2.0'
        if ($Validator -eq 'If-None-Match') {
            $request.Headers[[Net.HttpRequestHeader]::IfNoneMatch] = $ValidatorValue
        } elseif ($Validator -eq 'If-Modified-Since') {
            $request.IfModifiedSince = [DateTime]::Parse(
                $ValidatorValue, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        $response = $null
        try {
            $response = $request.GetResponse()
        } catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response }
            else { throw }
        }
        if (-not $response) { Stop-Jvm 'HTTP transfer returned no response' }
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $location = $response.Headers['Location']
                if (-not $location) { Stop-Jvm "HTTP $status redirect has no Location" }
                        $next = New-Object -TypeName System.Uri -ArgumentList @($current, $location)
                $response.Close()
                if ($next.Scheme -cne 'https' -or $next.UserInfo) {
                    Stop-Jvm 'refusing non-HTTPS transfer redirect'
                }
                $current = $next
                continue
            }
            if ($status -eq 200) {
                $inputStream = $response.GetResponseStream()
                $outputStream = [IO.File]::Open($OutputPath, [IO.FileMode]::Create,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose(); $inputStream.Dispose() }
            }
            return [pscustomobject]@{
                Status = $status
                ETag = $response.Headers['ETag']
                LastModified = $response.Headers['Last-Modified']
            }
        } finally {
            $response.Close()
        }
    }
    Stop-Jvm 'too many HTTP redirects'
}

function Read-MetadataCache {
    param([string]$Url, [string]$Entry, [string]$BodyPath)
    if (-not [IO.File]::Exists($Entry)) {
        return [pscustomobject]@{ Valid = $false; Checked = 0L; ETag = ''; Modified = '' }
    }
    $text = [IO.File]::ReadAllText($Entry)
    $lines = $text -split "`n", 5
    if ($lines.Count -lt 5 -or $lines[0].TrimEnd("`r") -cne $Url) {
        return [pscustomobject]@{ Valid = $false; Checked = 0L; ETag = ''; Modified = '' }
    }
    $checkedText = $lines[1].TrimEnd("`r")
    $checked = 0L
    if ($checkedText -notmatch '^[0-9]{1,12}$' -or
        -not [long]::TryParse($checkedText, [ref]$checked)) {
        return [pscustomobject]@{ Valid = $false; Checked = 0L; ETag = ''; Modified = '' }
    }
    $etag = $lines[2].TrimEnd("`r")
    $modified = $lines[3].TrimEnd("`r")
    if ($etag -match '[\r\n]' -or $modified -match '[\r\n]') {
        return [pscustomobject]@{ Valid = $false; Checked = 0L; ETag = ''; Modified = '' }
    }
    $body = $lines[4]
    if ([string]::IsNullOrEmpty($body)) {
        return [pscustomobject]@{ Valid = $false; Checked = 0L; ETag = ''; Modified = '' }
    }
    [IO.File]::WriteAllText($BodyPath, $body, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Valid = $true; Checked = $checked; ETag = $etag; Modified = $modified
    }
}

function Publish-MetadataCache {
    param([string]$Entry, [string]$BodyPath, [string]$Url,
        [string]$ETag, [string]$Modified)
    $temporary = Join-Path $script:CachePath ('.entry-' + [guid]::NewGuid().ToString('N'))
    $body = [IO.File]::ReadAllText($BodyPath)
    $contents = "$Url`n$(Get-UnixTimeSeconds)`n$ETag`n$Modified`n$body"
    [IO.File]::WriteAllText($temporary, $contents, [Text.UTF8Encoding]::new($false))
    try {
        if ([IO.File]::Exists($Entry)) {
            [IO.File]::Replace($temporary, $Entry, $null)
        } else {
            [IO.File]::Move($temporary, $Entry)
        }
    } catch {
        if ([IO.File]::Exists($Entry) -and [IO.File]::Exists($temporary)) {
            [IO.File]::Replace($temporary, $Entry, $null)
        } elseif ([IO.File]::Exists($temporary)) {
            [IO.File]::Move($temporary, $Entry)
        } else { throw }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-UnixTimeSeconds {
    $epoch = [DateTime]::SpecifyKind(
        [DateTime]::ParseExact('1970-01-01', 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
    return [long]([DateTime]::UtcNow - $epoch).TotalSeconds
}

function Get-Metadata {
    Initialize-CachePath
    $url = "$($script:BaseUrl)/metadata/all/$($script:Os)/$($script:Arch)/jdk-latest.tsv"
    $entry = Join-Path $script:CachePath "all-$($script:Os)-$($script:Arch)-jdk-latest-v1"
    $bodyPath = Join-Path $script:WorkPath 'cached'
    $cache = Read-MetadataCache $url $entry $bodyPath
    $now = Get-UnixTimeSeconds
    if ($cache.Valid -and $now -ge $cache.Checked -and ($now - $cache.Checked) -lt 3600) {
        return [IO.File]::ReadAllText($bodyPath)
    }
    $validator = ''; $value = ''
    if ($cache.Valid) {
        if ($cache.ETag) { $validator = 'If-None-Match'; $value = $cache.ETag }
        elseif ($cache.Modified) { $validator = 'If-Modified-Since'; $value = $cache.Modified }
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $download = Join-Path $script:WorkPath 'download'
        try {
            $response = Invoke-HttpsTransfer $url $download $validator $value 45
        } catch {
            if ($cache.Valid) { return [IO.File]::ReadAllText($bodyPath) }
            Stop-Jvm "cannot obtain metadata for $($script:Os)/$($script:Arch) from $url ($($_.Exception.Message))"
        }
        if ($response.Status -eq 304) {
            if ($cache.Valid) {
                Publish-MetadataCache $entry $bodyPath $url $cache.ETag $cache.Modified
                return [IO.File]::ReadAllText($bodyPath)
            }
            $validator = ''; $value = ''
            continue
        }
        if ($response.Status -ne 200 -or -not [IO.File]::Exists($download) -or
            (Get-Item -LiteralPath $download).Length -eq 0) {
            if ($cache.Valid) { return [IO.File]::ReadAllText($bodyPath) }
            Stop-Jvm "cannot obtain metadata for $($script:Os)/$($script:Arch) from $url (HTTP $($response.Status))"
        }
        Publish-MetadataCache $entry $download $url $response.ETag $response.LastModified
        return [IO.File]::ReadAllText($download)
    }
    if ($cache.Valid) { return [IO.File]::ReadAllText($bodyPath) }
    Stop-Jvm "cannot obtain metadata for $($script:Os)/$($script:Arch) from $url"
}

function New-WorkDirectory {
    param([string]$Parent, [string]$Prefix)
    [void][IO.Directory]::CreateDirectory($Parent)
    $path = Join-Path $Parent ($Prefix + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-ConfigFile {
    param([string]$Path)
    $values = @{ java = ''; distro = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Jvm "cannot read configuration: $Path"
    }
    $seen = @{ java = $false; distro = $false }
    foreach ($rawLine in [IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') { Stop-Jvm "invalid configuration line: $Path" }
        $separator = $line.IndexOf('=')
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($key -eq 'java') {
            $selector = Get-Selector $value
            if ($seen.java -or -not $value -or $value.Length -gt 180 -or
                $selector.Kind -notin @('id', 'major', 'distro-major', 'range')) {
                Stop-Jvm "duplicate or invalid java setting: $Path"
            }
            $seen.java = $true; $values.java = $value
        } elseif ($key -eq 'distro') {
            if ($seen.distro -or $value -notmatch '^[a-z][a-z0-9-]*$' -or $value.Length -gt 180) {
                Stop-Jvm "duplicate or invalid distro setting: $Path"
            }
            $seen.distro = $true; $values.distro = $value
        } else { Stop-Jvm "unknown configuration key: $key ($Path)" }
    }
    return $values
}

function Get-ConfigSetting {
    param([ValidateSet('java', 'distro')][string]$Key)
    if (-not $script:ProjectConfig) {
        $script:ProjectConfig = Get-ConfigFile (Join-Path (Get-Location).Path '.jvmrc')
    }
    if ($script:ProjectConfig[$Key]) { return $script:ProjectConfig[$Key] }
    if (-not $script:GlobalConfig) {
        $homePath = Get-HomePath
        $base = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
        if ([string]::IsNullOrWhiteSpace($base) -or -not [IO.Path]::IsPathRooted($base)) {
            $base = Join-Path $homePath '.config'
        }
        $script:GlobalConfig = Get-ConfigFile (Join-Path (Join-Path $base 'jvm') 'config')
    }
    return $script:GlobalConfig[$Key]
}

function Get-InstallationDistro {
    param([string]$Selector)
    $parsed = Get-Selector $Selector
    if ($parsed.Kind -in @('major', 'range') -and -not $parsed.Distro) {
        $configured = Get-ConfigSetting distro
        if ($configured) { return $configured }
    }
    return $script:DefaultDistro
}

function Get-InternalManifestRow {
    param([string]$Directory)
    $id = Split-Path -Leaf $Directory
    $manifest = Join-Path $Directory '.jvm-manifest'
    if (-not (Test-SafeId $id) -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $null }
    $lines = [IO.File]::ReadAllLines($manifest)
    if ($lines.Count -ne 3 -or $lines[0] -cne 'jvm-manifest-v1') { return $null }
    $fields = $lines[1].Split([char]9)
    if ($fields.Count -lt 15 -or -not (Test-EligibleIndexRow $fields)) { return $null }
    $major = ConvertTo-Major $fields[7]
    if (-not $major -or (Get-InstallId $fields[8] $fields[6] $major) -cne $id -or
        $fields[13] -notmatch '^[0-9a-fA-F]{64}$') { return $null }
    return [pscustomobject]@{
        Id = $id; Distro = $fields[6]; Version = $fields[8]; JVM = $fields[4]
        OS = $fields[1]; Arch = $fields[2]; Status = '.'
        Url = $fields[10]; Sha = $fields[13].ToLowerInvariant()
        Format = $fields[9]; Size = $fields[12]; JavaVersion = $fields[7]
        Major = $major; Source = $lines[1]
    }
}

function Test-CompleteInstallation {
    param([string]$Id)
    $directory = Join-Path $script:JdksPath $Id
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $false }
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $false
    }
    return ((Test-JdkLayout $directory) -and ($null -ne (Get-InternalManifestRow $directory)))
}

function Test-JdkLayout {
    param([string]$Directory)
    foreach ($name in @('java', 'javac')) {
        $found = $false
        foreach ($suffix in @('.exe', '.bat', '.cmd', '')) {
            if ([IO.File]::Exists((Join-Path (Join-Path $Directory 'bin') ($name + $suffix)))) {
                $found = $true; break
            }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Get-LocalInventory {
    Initialize-Host
    if (-not (Test-Path -LiteralPath $script:JdksPath)) { return }
    if (-not (Test-Path -LiteralPath $script:JdksPath -PathType Container)) {
        Stop-Jvm 'cannot read installed inventory'
    }
    $rows = New-Object System.Collections.Generic.List[object]
    try { $directories = Get-ChildItem -LiteralPath $script:JdksPath -Force -Directory }
    catch { Stop-Jvm 'cannot read installed inventory' }
    foreach ($directory in $directories) {
        $id = $directory.Name
        if (-not (Test-LocalId $id) -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            continue
        }
        $row = Get-InternalManifestRow $directory.FullName
        if ($row) { $row.Status = '.' }
        elseif (-not (Test-JdkLayout $directory.FullName)) {
            $row = [pscustomobject]@{
                Id = $id; Distro = ''; Version = ''; JVM = ''; OS = ''; Arch = ''
                Status = 'invalid JDK'; Url = ''; Sha = ''; Format = ''; Size = ''
                JavaVersion = ''; Major = ''; Source = ''
            }
        } else {
            $status = 'manifest missing'
            if (Test-Path -LiteralPath (Join-Path $directory.FullName '.jvm-manifest')) {
                $status = 'manifest invalid'
            }
            $row = [pscustomobject]@{
                Id = $id; Distro = ''; Version = ''; JVM = ''; OS = ''; Arch = ''
                Status = $status; Url = ''; Sha = ''; Format = ''; Size = ''
                JavaVersion = ''; Major = ''; Source = ''
            }
        }
        $rows.Add($row)
    }
    return Sort-RowsById $rows.ToArray()
}

function Get-UsableLocalRow {
    param([string]$Id)
    $directory = Join-Path $script:JdksPath $Id
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or
        ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return $null
    }
    if (-not (Test-JdkLayout $directory)) { return $null }
    $row = Get-InternalManifestRow $directory
    if ($row) { return $row }
    return [pscustomobject]@{
        Id = $Id; Distro = ''; Version = ''; JVM = ''; OS = ''; Arch = ''
        Status = 'manifest missing'; Url = ''; Sha = ''; Format = ''; Size = ''
        JavaVersion = ''; Major = ''; Source = ''
    }
}

function Get-TabTable {
    param([object[]]$Rows, [string[]]$Columns)
    $widths = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $widths += [Math]::Max(1, $Columns[$i].Length)
    }
    foreach ($row in $Rows) {
        if ($row.PSObject.Properties['Status'] -and $row.Status) { continue }
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $widths[$i] = [Math]::Max($widths[$i], ([string]$row.($Columns[$i])).Length)
        }
    }
    foreach ($row in $Rows) {
        if ($row.PSObject.Properties['Status'] -and $row.Status) {
            Write-Output ("$($row.ID)`t($($row.Status))")
            continue
        }
        $cells = @()
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $value = [string]$row.($Columns[$i])
            $tabs = [Math]::Max(1, [Math]::Min(4, [int][Math]::Floor($widths[$i] / 8) + 1) -
                [int][Math]::Floor($value.Length / 8))
            if ($i -lt $Columns.Count - 1) { $cells += $value + ("`t" * $tabs) }
            else { $cells += $value }
        }
        Write-Output (($cells -join ''))
    }
}

function Sort-RowsById {
    param([object[]]$Rows)
    $ordered = @($Rows)
    if ($ordered.Count -gt 1) {
        [Array]::Sort($ordered, [Comparison[object]]{
            param($left, $right)
            [String]::CompareOrdinal([string]$left.Id, [string]$right.Id)
        })
    }
    return $ordered
}

function Remove-TreeNoFollow {
    param([string]$Path)
    if (-not (Test-PathEntry $Path)) { return }
    $attributes = [IO.File]::GetAttributes($Path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($attributes -band [IO.FileAttributes]::Directory) {
            [IO.Directory]::Delete($Path)
        } else {
            [IO.File]::Delete($Path)
        }
        return
    }
    if ($attributes -band [IO.FileAttributes]::Directory) {
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
            Remove-TreeNoFollow $child
        }
        [IO.Directory]::Delete($Path)
    } else {
        [IO.File]::Delete($Path)
    }
}

function Get-Matches {
    param([object[]]$Rows, [string]$Selector, [string]$Distro = '',
        [switch]$Listing, [switch]$Range, [switch]$Probe, [switch]$NoRange)
    $parsed = Get-Selector $Selector
    $exact = @($Rows | Where-Object { $_.Id -ceq $Selector })
    if ($exact.Count -gt 0) { return $exact }
    if ($parsed.Kind -eq 'range' -and $NoRange) {
        Stop-Jvm 'selector must be a full ID, major, or distro-major (version ranges allowed except for uninstall)' 2
    }
    $wantedDistro = $Distro
    $wantedMajor = ''
    if ($parsed.Kind -eq 'range') {
        $wantedDistro = if ($parsed.Distro) { $parsed.Distro } else { $Distro }
    } elseif ($parsed.Kind -eq 'major') { $wantedMajor = $parsed.Major }
    elseif ($parsed.Kind -eq 'distro-major') {
        $wantedMajor = $parsed.Major; $wantedDistro = $parsed.Distro
    } elseif ($parsed.Kind -eq 'distro' -and $Listing) { $wantedDistro = $parsed.Distro }
    elseif ($parsed.Kind -eq 'empty' -and $Listing) { }
    else {
        if (-not $Probe) { Stop-Jvm "No JDK found matching: $Selector" }
        return
    }
    $matches = @($Rows | Where-Object {
        if (-not $_.JavaVersion) { return $false }
        $major = ConvertTo-Major $_.JavaVersion
        if ($wantedMajor -and $major -cne $wantedMajor) { return $false }
        if ($wantedDistro -and $_.Distro -cne $wantedDistro) { return $false }
        if ($parsed.Kind -eq 'range') {
            if ((Compare-Major $major $parsed.Min) -lt 0) { return $false }
            if ($parsed.Max -and (Compare-Major $major $parsed.Max) -gt 0) { return $false }
        }
        return $true
    })
    if (-not $matches.Count -and -not ($Listing -and $parsed.Kind -eq 'empty')) {
        if (-not $Probe) { Stop-Jvm "No JDK found matching: $Selector" }
        return
    }
    if ($parsed.Kind -eq 'range' -and -not $Listing) {
            $highest = ''
            foreach ($candidate in $matches) {
                $candidateMajor = ConvertTo-Major $candidate.JavaVersion
                if (-not $highest -or (Compare-Major $candidateMajor $highest) -gt 0) {
                    $highest = $candidateMajor
                }
            }
            if ($highest) {
                $matches = @($matches | Where-Object { (ConvertTo-Major $_.JavaVersion) -ceq $highest })
                $matches = @(Sort-RowsById $matches)
                $preferred = Get-DefaultTargetId ([string]$highest) -Quiet
                if ($preferred) {
                    $selected = @($matches | Where-Object { $_.Id -ceq $preferred })
                    if ($selected.Count) { return $selected }
                }
                return @($matches | Select-Object -First 1)
            }
    }
    if (-not $Listing -and $matches.Count -gt 1) {
        Write-JvmDiagnostic ('Multiple JDKs match, try again using one of the following IDs:')
        Format-Inventory $matches | ForEach-Object { Write-JvmDiagnostic $_ }
        Stop-Jvm 'ambiguous JDK selector'
    }
    return $matches
}

function Get-DefaultTargetId {
    param([string]$Name = 'default', [switch]$Quiet)
    $link = Join-Path $script:JdksPath $Name
    $script:CurrentDefault = ''
    if (-not (Test-PathEntry $link)) { return '' }
    try { $item = Get-Item -LiteralPath $link -Force }
    catch {
        if ($Quiet) { return '' }
        throw
    }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ($Quiet) { return '' }
        Stop-Jvm "default path is not a managed link: $link"
    }
    try {
        $target = Resolve-PhysicalPath $link
        $inventory = Resolve-PhysicalPath $script:JdksPath
    } catch {
        if ($Quiet) { return '' }
        throw
    }
    if (-not $target.StartsWith($inventory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        if ($Quiet) { return '' }
        Stop-Jvm 'default points outside the managed JDK inventory'
    }
    $id = Split-Path -Leaf $target
    if (-not (Test-LocalId $id) -or
        [IO.Path]::GetFullPath($target).TrimEnd('\') -ine
        [IO.Path]::GetFullPath((Join-Path $script:JdksPath $id)).TrimEnd('\')) {
        if ($Quiet) { return '' }
        Stop-Jvm 'default points outside the managed JDK inventory'
    }
    $script:CurrentDefault = $id
    return $id
}

function Resolve-PhysicalPath {
    param([string]$Path)
    Initialize-NativePath
    return [JvmNativePath]::Resolve([IO.Path]::GetFullPath($Path))
}

function Initialize-NativePath {
    if ('JvmNativePath' -as [type]) { return }
    $native = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class JvmNativePath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern uint GetFileAttributes(string name);
  public static bool Exists(string path) {
    return GetFileAttributes(path) != 0xFFFFFFFF;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr CreateFile(string name, uint access, uint share,
    IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern uint GetFinalPathNameByHandle(IntPtr handle,
    StringBuilder path, uint length, uint flags);
  [DllImport("kernel32.dll")]
  private static extern bool CloseHandle(IntPtr handle);
  public static string Resolve(string path) {
    IntPtr h = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
    if (h == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
    try {
      StringBuilder b = new StringBuilder(512);
      uint n = GetFinalPathNameByHandle(h, b, (uint)b.Capacity, 0);
      if (n == 0) throw new System.ComponentModel.Win32Exception();
      if (n >= b.Capacity) {
        b = new StringBuilder((int)n + 1);
        n = GetFinalPathNameByHandle(h, b, (uint)b.Capacity, 0);
        if (n == 0 || n >= b.Capacity) throw new System.ComponentModel.Win32Exception();
      }
      string value = b.ToString();
      if (value.StartsWith(@"\\?\UNC\")) return @"\\" + value.Substring(8);
      if (value.StartsWith(@"\\?\")) return value.Substring(4);
      return value;
    } finally { CloseHandle(h); }
  }
}
'@
    Add-Type -TypeDefinition $native -Language CSharp | Out-Null
}

function Test-PathEntry {
    param([string]$Path)
    Initialize-NativePath
    return [JvmNativePath]::Exists([IO.Path]::GetFullPath($Path))
}

function New-ManagedJunction {
    param([string]$Link, [string]$Target)
    [void](New-Item -ItemType Junction -Path $Link -Target $Target)
    $resolved = Resolve-PhysicalPath $Link
    if ([IO.Path]::GetFullPath($resolved).TrimEnd('\') -ine
        [IO.Path]::GetFullPath((Resolve-PhysicalPath $Target)).TrimEnd('\')) {
        Stop-Jvm 'cannot verify the default JDK junction'
    }
}

function Set-ManagedDefault {
    param([string]$Id, [string]$Name = 'default', [switch]$Initial)
    Initialize-Host
    $destination = Join-Path $script:JdksPath $Name
    $current = Get-DefaultTargetId $Name
    if ($Initial -and $current) { return }
    if (-not $Id) {
        if ($current) { [IO.Directory]::Delete($destination) }
        return
    }
    $row = Get-UsableLocalRow $Id
    if (-not $row) { Stop-Jvm "default JDK is unavailable: $Id" }
    if ($current -ceq $Id) { return }
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DataPath 'tmp'))
    $stage = New-WorkDirectory (Join-Path $script:DataPath 'tmp') 'default-'
    $newLink = Join-Path $stage 'link'
    try {
        New-ManagedJunction $newLink (Join-Path $script:JdksPath $Id)
        if ($Initial) {
            try { [IO.Directory]::Move($newLink, $destination) }
            catch {
                if (Get-DefaultTargetId $Name -Quiet) { return }
                throw
            }
        } else {
            $previous = Join-Path $stage 'previous'
            if (Test-Path -LiteralPath $destination) {
                [IO.Directory]::Move($destination, $previous)
            }
            try { [IO.Directory]::Move($newLink, $destination) }
            catch {
                if (Test-Path -LiteralPath $previous) {
                    [IO.Directory]::Move($previous, $destination)
                }
                throw
            }
        }
    } finally {
        foreach ($path in @($newLink, (Join-Path $stage 'previous'))) {
            if (Test-Path -LiteralPath $path) { [IO.Directory]::Delete($path) }
        }
        if (Test-Path -LiteralPath $stage) { [IO.Directory]::Delete($stage) }
    }
}

function Initialize-ManagedDefault {
    param([string]$Id, [string]$Name = 'default')
    $path = Join-Path $script:JdksPath $Name
    if (Test-PathEntry $path) { return }
    try { Set-ManagedDefault $Id $Name -Initial }
    catch {
        if ($Name -eq 'default') {
            Stop-Jvm 'JDK installed, but default selection failed; run jvm default <ID>'
        }
        Stop-Jvm "JDK installed, but Java $Name default selection failed; run jvm default -v $Name <ID>"
    }
}

function Resolve-Installed {
    param([string]$Selector, [switch]$Probe)
    $rows = @(Get-LocalInventory)
    $parsed = Get-Selector $Selector
    if ($parsed.Kind -eq 'major') {
        $reference = Join-Path $script:JdksPath $parsed.Major
        if (Test-Path -LiteralPath $reference) {
            $id = Get-DefaultTargetId $parsed.Major
            $row = Get-UsableLocalRow $id
            if (-not $row -or $row.Major -cne $parsed.Major -or
                (Resolve-PhysicalPath $reference) -ine (Resolve-PhysicalPath (Join-Path $script:JdksPath $id))) {
                Stop-Jvm "default JDK for version $($parsed.Major) is unavailable"
            }
            return $row
        }
    }
    if ((Test-LocalId $Selector) -and $parsed.Kind -ne 'major') {
        $local = Get-UsableLocalRow $Selector
        if ($local) { return $local }
        $directory = Join-Path $script:JdksPath $Selector
        if (Test-Path -LiteralPath $directory -PathType Container) {
            Stop-Jvm "JDK has no usable java/javac launchers: $Selector"
        }
    }
    $matches = @(Get-Matches $rows $Selector -Probe:$Probe)
    if (-not $matches.Count) { return $null }
    return $matches[0]
}

function Select-RangeRow {
    param([object[]]$Rows, [string]$Selector)
    $matches = @(Get-Matches $Rows $Selector -Range)
    if ($matches.Count) { return $matches[0] }
    return $null
}

function Format-Inventory {
    param([object[]]$Rows)
    $current = Get-DefaultTargetId 'default' -Quiet
    $majorDefaults = @{}
    foreach ($row in $Rows) {
        if ($row.Major -and -not $majorDefaults.ContainsKey($row.Major)) {
            $target = Get-DefaultTargetId $row.Major -Quiet
            if ($target) { $majorDefaults[$row.Major] = $target }
        }
    }
    $display = New-Object System.Collections.Generic.List[object]
    $display.Add([pscustomobject]@{
        ID = 'ID'; DISTRIBUTION = 'DISTRIBUTION'; VERSION = 'VERSION'; JVM = 'JVM'; DEFAULT = 'DEFAULT'
    })
    foreach ($row in $Rows) {
        if ($row.Status -ne '.') {
            $display.Add([pscustomobject]@{ ID = $row.Id; DISTRIBUTION = ''
                VERSION = ''; JVM = ''; DEFAULT = ''; Status = $row.Status })
            continue
        }
        $marks = @()
        if ($row.Id -ceq $current) { $marks += 'global' }
        if ($majorDefaults.ContainsKey($row.Major) -and $row.Id -ceq $majorDefaults[$row.Major]) {
            $marks += $row.Major
        }
        $display.Add([pscustomobject]@{
            ID = $row.Id; DISTRIBUTION = $row.Distro; VERSION = $row.JavaVersion
            JVM = $row.JVM; DEFAULT = ($marks -join ',')
        })
    }
    Get-TabTable $display.ToArray() @('ID', 'DISTRIBUTION', 'VERSION', 'JVM', 'DEFAULT')
}

function Invoke-Available {
    param([string]$Selector, [switch]$ShowType)
    if ($Selector.Length -gt 100) { Stop-Jvm 'selector is too long' 2 }
    $parsed = Get-Selector $Selector
    if ($parsed.Kind -notin @('empty', 'major', 'distro', 'distro-major', 'range')) {
        if ($Selector -match '^0[0-9]*$') { Stop-Jvm 'Java major must be positive, without leading zeros' 2 }
        Stop-Jvm 'selector must be a major, distro, distro-major, or version range' 2
    }
    Initialize-Host
    Initialize-CachePath
    $script:WorkPath = New-WorkDirectory $script:CachePath '.discovery-'
    try { $rows = @(Get-IndexRows (Get-Metadata)) }
    finally {
        if ($script:WorkPath -and (Test-Path -LiteralPath $script:WorkPath)) {
            Remove-TreeNoFollow $script:WorkPath
        }
        $script:WorkPath = $null
    }
    $matches = @($rows | Where-Object {
        if ($parsed.Distro -and $_.Distro -cne $parsed.Distro) { return $false }
        $major = $_.Major
        if ($parsed.Major -and $major -cne $parsed.Major) { return $false }
        if ($parsed.Min -and (Compare-Major $major $parsed.Min) -lt 0) { return $false }
        if ($parsed.Max -and (Compare-Major $major $parsed.Max) -gt 0) { return $false }
        return $true
    })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $display = New-Object System.Collections.Generic.List[object]
    $display.Add([pscustomobject]@{ ID = 'ID'; DISTRIBUTION = 'DISTRIBUTION'
        VERSION = 'VERSION'; JVM = 'JVM'; TYPE = 'TYPE' })
    foreach ($row in $matches) {
        if (-not $seen.Add($row.Id)) { continue }
        $features = $row.Features.TrimStart('[').TrimEnd(']')
        $type = if ($row.Release -eq 'ea') {
            'ea' + $(if ($features) { ",$features" })
        } else { $features }
        $display.Add([pscustomobject]@{ ID = $row.Id; DISTRIBUTION = $row.Distro
            VERSION = $row.JavaVersion; JVM = $row.JVM; TYPE = $type })
    }
    if ($matches.Count -eq 0 -and ($parsed.Distro -or $parsed.Major -or $parsed.Min)) {
        Stop-Jvm "No JDK found matching: $Selector"
    }
    if (-not $ShowType) {
        foreach ($row in $display) { $row.PSObject.Properties.Remove('TYPE') }
        Get-TabTable $display.ToArray() @('ID', 'DISTRIBUTION', 'VERSION', 'JVM')
    } else {
        Get-TabTable $display.ToArray() @('ID', 'DISTRIBUTION', 'VERSION', 'JVM', 'TYPE')
    }
}

function Invoke-List {
    param([string]$Selector)
    if ($Selector.Length -gt 180) { Stop-Jvm 'selector is too long' 2 }
    $parsed = Get-Selector $Selector
    $valid = $parsed.Kind -in @('empty', 'major', 'distro', 'distro-major', 'range', 'id')
    if (-not $valid -and -not (Test-ExistingInstallationDirectory $Selector)) {
        Stop-Jvm 'selector must be a major, distro, distro-major, or version range' 2
    }
    Initialize-Host
    $rows = @(Get-LocalInventory)
    if (-not $rows.Count) {
        Write-Output ("No JDKs are installed. Use 'install' to install one")
        return
    }
    $matches = @(Get-Matches $rows $Selector -Listing)
    Format-Inventory $matches
}

function Get-DownloadDigest {
    param([string]$Path, [string]$Expected, [string]$ExpectedSize)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { $digest = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
    if ($digest -cne $Expected) { Stop-Jvm 'SHA-256 checksum mismatch' }
    if ($ExpectedSize) {
        if ($ExpectedSize -notmatch '^[0-9]{1,18}$') { Stop-Jvm 'invalid advertised size' }
        if ((Get-Item -LiteralPath $Path).Length -ne [long]$ExpectedSize) {
            Stop-Jvm 'download size mismatch'
        }
    }
}

function ConvertTo-SafeArchivePath {
    param([string]$Path)
    if (-not $Path -or $Path -match '[^a-zA-Z0-9._+@%/=-]' -or
        $Path.StartsWith('/') -or $Path.Contains('\') -or
        $Path -match '(^|/)\.\.($|/)') { return $null }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($component in $Path.Split('/')) {
        if (-not $component -or $component -eq '.') { continue }
        if ($component.EndsWith('.') -or
            $component -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)') { return $null }
        $parts.Add($component)
    }
    return ($parts -join '/')
}

function Get-ZipEntries {
    param([string]$Archive)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $entries = New-Object System.Collections.Generic.List[object]
    $names = @{}
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $isDirectory = $name.EndsWith('/')
            $path = ConvertTo-SafeArchivePath $name.TrimEnd('/')
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { Stop-Jvm 'symbolic links are not supported in Windows JDK archives' }
            if ($unixType -notin @(0, 0x8000, 0x4000) -and
                -not ($isDirectory -and $unixType -eq 0)) { Stop-Jvm 'unsupported zip entry type' }
            if ($null -eq $path) { Stop-Jvm 'unsafe or unsupported archive paths' }
            if (-not $path -and $isDirectory) { continue }
            if (-not $path) { Stop-Jvm 'unsafe or unsupported archive paths' }
            $folded = $path.ToLowerInvariant()
            if ($names.ContainsKey($folded)) { Stop-Jvm 'duplicate archive paths are unsafe' }
            $names[$folded] = if ($isDirectory) { 'd' } else { 'f' }
            $entries.Add([pscustomobject]@{
                Name = $path; ZipName = $name; Directory = $isDirectory
            })
        }
        if (-not $entries.Count) { Stop-Jvm 'archive is empty' }
        foreach ($item in $entries) {
            $parent = Split-Path -Parent ($item.Name -replace '/', '\')
            while ($parent) {
                $key = $parent.Replace('\', '/').ToLowerInvariant()
                if ($names.ContainsKey($key) -and $names[$key] -ne 'd') {
                    Stop-Jvm 'archive path conflicts with a non-directory entry'
                }
                $parent = Split-Path -Parent $parent
            }
        }
        return $entries.ToArray()
    } finally { $zip.Dispose() }
}

function Expand-SafeZip {
    param([string]$Archive, [string]$Destination)
    $entries = @(Get-ZipEntries $Archive)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entryInfo in $entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination ($entryInfo.Name.Replace('/', '\'))))
            $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Jvm 'unsafe archive path'
            }
            if ($entryInfo.Directory) { [void][IO.Directory]::CreateDirectory($target); continue }
            $parent = Split-Path -Parent $target
            [void][IO.Directory]::CreateDirectory($parent)
            $zipEntry = $zip.GetEntry($entryInfo.ZipName)
            if (-not $zipEntry) { Stop-Jvm 'cannot read zip archive entry' }
            $source = $zipEntry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $source.CopyTo($output) }
            finally { $source.Dispose(); $output.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Expand-SafeTar {
    param([string]$Archive, [string]$Destination)
    $tarCommand = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if (-not $tarCommand) { Stop-Jvm 'tar.exe is required to extract this tar.gz archive' }
    $names = @(& $tarCommand.Source -tzf $Archive 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not $names.Count) { Stop-Jvm 'cannot inspect tar.gz archive' }
    $verbose = @(& $tarCommand.Source -tvzf $Archive 2>&1)
    if ($LASTEXITCODE -ne 0 -or $verbose.Count -ne $names.Count) {
        Stop-Jvm 'cannot inspect tar.gz archive'
    }
    $types = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $rawName = [string]$names[$i]
        $line = [string]$verbose[$i]
        if ($line.Length -lt 1 -or $line[0] -notin @('-', 'd')) {
            Stop-Jvm 'unsupported tar entry type'
        }
        $listedName = (($line -split '\s+')[-1]).TrimEnd('/')
        if ($listedName -cne $rawName.TrimEnd('/')) {
            Stop-Jvm 'unsupported tar entry listing'
        }
        $name = ConvertTo-SafeArchivePath $rawName.TrimEnd('/')
        if ($null -eq $name) {
            Stop-Jvm 'unsafe or unsupported archive paths'
        }
        if (-not $name -and $line[0] -eq 'd') { continue }
        if (-not $name -or $types.ContainsKey($name)) {
            Stop-Jvm 'duplicate archive paths are unsafe'
        }
        $types[$name] = if ($line[0] -eq 'd') { 'd' } else { 'f' }
    }
    foreach ($name in $types.Keys) {
        $parent = Split-Path -Parent ($name -replace '/', '\')
        while ($parent) {
            $parentKey = $parent.Replace('\', '/')
            if ($types.ContainsKey($parentKey) -and $types[$parentKey] -ne 'd') {
                Stop-Jvm 'archive path conflicts with a non-directory entry'
            }
            $parent = Split-Path -Parent $parent
        }
    }
    [void][IO.Directory]::CreateDirectory($Destination)
    & $tarCommand.Source -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) { Stop-Jvm 'tar.gz extraction failed' }
}

function Expand-JdkArchive {
    param([string]$Archive, [string]$Format)
    $unpacked = Join-Path $script:StagePath 'unpacked'
    [void][IO.Directory]::CreateDirectory($unpacked)
    if ($Format -eq 'zip') { Expand-SafeZip $Archive $unpacked }
    else { Expand-SafeTar $Archive $unpacked }
    $candidates = New-Object System.Collections.Generic.List[string]
    $directories = @((Get-Item -LiteralPath $unpacked)) + @(Get-ChildItem -LiteralPath $unpacked -Directory -Recurse)
    foreach ($directory in $directories) {
        $candidate = $directory.FullName
        if ((Split-Path -Leaf $candidate) -eq 'bin') { $candidate = Split-Path -Parent $candidate }
        if (Test-JdkLayout $candidate) { $candidates.Add($candidate) }
    }
    if ($candidates.Count -ne 1) {
        Stop-Jvm 'archive must contain exactly one JDK with bin/java and bin/javac (Windows also .exe, .bat, .cmd)'
    }
    $homePath = $candidates[0]
    Test-ReleasePlatform $homePath
    if (Test-Path -LiteralPath (Join-Path $homePath '.jvm-manifest')) {
        Stop-Jvm 'archive contains reserved .jvm-manifest'
    }
    return $homePath
}

function Test-ReleasePlatform {
    param([string]$HomePath)
    $release = Join-Path $HomePath 'release'
    if (-not (Test-Path -LiteralPath $release -PathType Leaf)) { return }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($release)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) { continue }
        $key = $line.Substring(0, $separator)
        if ($key -in @('OS_ARCH', 'OS_NAME')) {
            $values[$key] = $line.Substring($separator + 1).Trim('"')
        }
    }
    $arch = $values['OS_ARCH']
    if ($arch -in @('amd64', 'AMD64')) { $arch = 'x86_64' }
    elseif ($arch -in @('arm64', 'ARM64')) { $arch = 'aarch64' }
    elseif ($arch -in @('x86', 'i386', 'i486', 'i586')) { $arch = 'i686' }
    if ($arch -and $arch -cne $script:Arch) {
        Stop-Jvm 'JDK release architecture does not match the host'
    }
    $osName = $values['OS_NAME']
    if ($osName -and $osName -notmatch '^Windows') {
        Stop-Jvm 'JDK release operating system does not match the host'
    }
}

function Write-InstallationManifest {
    param([string]$Home, [string]$SourceRow)
    $contents = "jvm-manifest-v1`n$SourceRow`n`n"
    [IO.File]::WriteAllText((Join-Path $Home '.jvm-manifest'), $contents,
        [Text.UTF8Encoding]::new($false))
}

function Initialize-InstalledDefaults {
    param([string]$Id, [string]$Major, [string]$MakeDefault)
    if ($Major) { Initialize-ManagedDefault $Id $Major }
    if ($MakeDefault -eq '-d') { Set-ManagedDefault $Id; Write-DefaultReport $Id 'default' }
    else { Initialize-ManagedDefault $Id 'default' }
}

function Write-DefaultReport {
    param([string]$Id, [string]$Name = 'default')
    if ($Id) {
        if ($Name -eq 'default') { Write-JvmDiagnostic ("Default JDK set to: $Id") }
        else { Write-JvmDiagnostic ("Java $Name default JDK set to: $Id") }
    } elseif ($Name -eq 'default') {
        Write-JvmDiagnostic ('No JDK currently set as the default')
    } else {
        Write-JvmDiagnostic ("No JDK currently set as the default for version $Name")
    }
}

function Install-Jdk {
    param([string]$Selector, [string]$MakeDefault = '', [string]$ExpectedMajor = '',
        [switch]$UseConfig)
    Initialize-Host
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DataPath 'tmp'))
    $script:WorkPath = New-WorkDirectory (Join-Path $script:DataPath 'tmp') 'install-'
    try {
        if ((Test-LocalId $Selector) -and (Get-UsableLocalRow $Selector)) {
            $row = Get-UsableLocalRow $Selector
            if ($ExpectedMajor -and $row.Major -cne $ExpectedMajor) {
                Stop-Jvm "selected JDK has Java major $($row.Major), expected $ExpectedMajor"
            }
            Initialize-InstalledDefaults $Selector $row.Major $MakeDefault
            Write-JvmDiagnostic ("Already installed $Selector")
            return $Selector
        }
        $parsed = Get-Selector $Selector
        if ($parsed.Kind -eq 'range') {
            $row = Resolve-Installed $Selector -Probe
            if ($row) {
                if ($ExpectedMajor -and $row.Major -cne $ExpectedMajor) {
                    Stop-Jvm "selected JDK has Java major $($row.Major), expected $ExpectedMajor"
                }
                Initialize-InstalledDefaults $row.Id $row.Major $MakeDefault
                Write-JvmDiagnostic ("Already installed $($row.Id)")
                return $row.Id
            }
        }
        if ($parsed.Kind -notin @('id', 'major', 'distro-major', 'range')) {
            Stop-Jvm 'selector must be a full ID, major, or distro-major (version ranges allowed except for uninstall)' 2
        }
        $distro = $script:DefaultDistro
        if ($UseConfig) { $distro = Get-InstallationDistro $Selector }
        $rows = @(Get-IndexRows (Get-Metadata))
        $matches = @(Get-Matches $rows $Selector $distro)
        if ($ExpectedMajor -and $matches[0].Major -cne $ExpectedMajor) {
            Stop-Jvm "selected JDK has Java major $($matches[0].Major), expected $ExpectedMajor"
        }
        $preferredFormat = 'zip'
        $preferred = @($matches | Where-Object { $_.Format -eq $preferredFormat })
        if ($preferred.Count) { $matches = $preferred }
        if ($matches.Count -ne 1) {
            Stop-Jvm 'multiple artifact rows remain for the resolved ID and chosen archive format; use a corrected upstream index'
        }
        $row = $matches[0]
        $id = $row.Id
        if (-not (Test-SafeId $id)) { Stop-Jvm 'unsafe installation ID' }
        $existing = Join-Path $script:JdksPath $id
        if (Test-CompleteInstallation $id) {
            Initialize-InstalledDefaults $id $row.Major $MakeDefault
            Write-JvmDiagnostic ("Already installed $id")
            return $id
        }
        if (Test-PathEntry $existing) {
            Stop-Jvm "incomplete or incompatible installation already exists: $existing"
        }
        if (-not $row.Url.StartsWith('https://') -or $row.Url -match '[\r\n\t]') {
            Stop-Jvm 'artifact URL must use HTTPS'
        }
        if ($row.Sha -notmatch '^[a-f0-9]{64}$') { Stop-Jvm 'expected SHA-256 is missing or invalid' }
        Write-JvmDiagnostic ("Installing $id...")
        $download = Join-Path $script:WorkPath 'download'
        $response = Invoke-HttpsTransfer $row.Url $download '' '' 1800
        if ($response.Status -ne 200) { Stop-Jvm "artifact transfer failed (HTTP $($response.Status))" }
        Get-DownloadDigest $download $row.Sha $row.Size
        $homePath = Expand-JdkArchive $download $row.Format
        Write-InstallationManifest $homePath $row.Source
        $publish = Join-Path $script:WorkPath 'publish'
        [IO.Directory]::Move($homePath, $publish)
        [void][IO.Directory]::CreateDirectory($script:JdksPath)
        try { [IO.Directory]::Move($publish, $existing) }
        catch {
            if (-not (Test-CompleteInstallation $id)) { throw }
            Remove-TreeNoFollow $publish
        }
        if (-not (Test-CompleteInstallation $id)) { Stop-Jvm "cannot publish installation: $id" }
        Initialize-InstalledDefaults $id $row.Major $MakeDefault
        Write-JvmDiagnostic ("Successfully installed $id")
        return $id
    } finally {
        if ($script:WorkPath -and (Test-Path -LiteralPath $script:WorkPath)) {
            Remove-TreeNoFollow $script:WorkPath
        }
        $script:WorkPath = $null
    }
}

function Resolve-Selection {
    param([string]$Selector, [string]$ExpectedMajor = '',
        [switch]$UseConfig)
    Initialize-Host
    $row = Resolve-Installed $Selector -Probe
    if ($row) {
        if ($ExpectedMajor -and $row.Major -cne $ExpectedMajor) {
            Stop-Jvm "selected JDK has Java major $($row.Major), expected $ExpectedMajor"
        }
        return $row
    }
    $id = Install-Jdk $Selector '' $ExpectedMajor -UseConfig:$UseConfig
    return Get-UsableLocalRow $id
}

function Invoke-Default {
    param([string]$Selector, [string]$Major = 'default')
    Initialize-Host
    $current = Get-DefaultTargetId $Major
    if (-not $Selector) {
        if (-not $current) {
            if ($Major -eq 'default') { Write-Output 'No JDK currently set as the default' }
            else { Write-Output "No JDK currently set as the default for version $Major" }
            return
        }
        $row = Get-UsableLocalRow $current
        if (-not $row -or ($Major -ne 'default' -and $row.Major -cne $Major)) {
            Stop-Jvm "default JDK is unavailable: $current"
        }
        Write-Output ($current)
        return
    }
    $row = Resolve-Installed $Selector
    if ($Major -ne 'default' -and $row.Major -cne $Major) {
        Stop-Jvm "selected JDK has Java major $($row.Major), expected $Major"
    }
    Set-ManagedDefault $row.Id $Major
    Write-DefaultReport $row.Id $Major
}

function Resolve-Home {
    param([string]$Selector, [string]$OriginalSelector = $Selector, [switch]$Physical)
    Initialize-Host
    if ($Selector) {
        $row = Resolve-Installed $Selector
        if (-not $Physical -and (Test-Major $OriginalSelector)) {
            $link = Join-Path $script:JdksPath $OriginalSelector
            if ((Test-Path -LiteralPath $link) -and
                (Resolve-PhysicalPath $link) -ieq
                (Resolve-PhysicalPath (Join-Path $script:JdksPath $row.Id))) {
                return [pscustomobject]@{ Home = $link; Row = $row }
            }
        }
        return [pscustomobject]@{
            Home = Resolve-PhysicalPath (Join-Path $script:JdksPath $row.Id); Row = $row
        }
    }
    $default = Join-Path $script:JdksPath 'default'
    if (-not (Test-PathEntry $default)) { Stop-Jvm 'No JDK currently set as the default' }
    $id = Get-DefaultTargetId 'default'
    $row = Get-UsableLocalRow $id
    if (-not $row) { Stop-Jvm 'default JDK is missing or unusable' }
    if ($Physical) { $homePath = Resolve-PhysicalPath (Join-Path $script:JdksPath $id) }
    else { $homePath = $default }
    return [pscustomobject]@{ Home = $homePath; Row = $row }
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-EnvironmentInvocationPath {
    $invocation = $script:ScriptInvocation
    if ($invocation.InvocationName -ne '&' -and $invocation.InvocationName -ne '.') {
        return $invocation.InvocationName
    }
    # InvocationName is the operator for calls such as & '.\jvm.ps1'. Read
    # literal command paths without evaluating caller expressions.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $invocation.Line, [ref]$tokens, [ref]$parseErrors)
    $command = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.Extent.StartColumnNumber -eq $invocation.OffsetInLine
    }, $true)
    if ($command) {
        $word = $command.CommandElements[0]
        if ($word -is [Management.Automation.Language.StringConstantExpressionAst] -or
            ($word -is [Management.Automation.Language.ExpandableStringExpressionAst] -and
                $word.NestedExpressions.Count -eq 0)) {
            return $word.Value
        }
    }
    return $PSCommandPath
}

function Invoke-HomeOrEnvironment {
    param([string]$Command, [string]$Selector, [string]$OriginalSelector,
        [switch]$ForcePath, [string[]]$OriginalArguments)
    $resolved = Resolve-Home $Selector $OriginalSelector
    if ($Command -eq 'home') {
        Write-Output ($resolved.Home)
        return
    }
    $javaHome = $resolved.Home
    $bin = Join-Path $javaHome 'bin'
    $invocationPath = Get-EnvironmentInvocationPath
    if ($invocationPath -match "[`r`n]") { Stop-Jvm 'script path must be a single-line path' }
    $usage = '& ' + (ConvertTo-PowerShellLiteral $invocationPath)
    foreach ($argument in $OriginalArguments) {
        if ($argument -match '^[a-zA-Z0-9_-]+$') { $usage += ' ' + $argument }
        else { $usage += ' ' + (ConvertTo-PowerShellLiteral $argument) }
    }
    $lines = @("# Use: iex ($usage)",
        ('$env:JAVA_HOME = ' + (ConvertTo-PowerShellLiteral $javaHome)))
    if ($resolved.Row.JVM -eq 'graalvm') {
        $lines += '$env:GRAALVM_HOME = ' + (ConvertTo-PowerShellLiteral $javaHome)
    }
    $alreadyPresent = $false
    if (-not $ForcePath) {
        foreach ($part in ([Environment]::GetEnvironmentVariable('PATH') -split ';')) {
            if ($part.TrimEnd('\') -ieq $bin.TrimEnd('\')) { $alreadyPresent = $true; break }
        }
    }
    if (-not $alreadyPresent) {
        $lines += '$env:PATH = ' + (ConvertTo-PowerShellLiteral ($bin + ';')) + ' + $env:PATH'
    }
    # One complete string also supports Invoke-Expression (& .\jvm env ...).
    Write-Output ($lines -join "`n")
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') { $slashes++; continue }
        if ($char -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($char)
        }
        $slashes = 0
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Find-Executable {
    param([string]$Command, [string]$PreferredPath = '')
    $extensions = [Environment]::GetEnvironmentVariable('PATHEXT')
    if (-not $extensions) { $extensions = '.COM;.EXE;.BAT;.CMD' }
    $suffixes = @('.ps1') + @($extensions.Split(';') | Where-Object { $_ })
    if ($Command -match '[\\/]') {
        $path = [IO.Path]::GetFullPath($Command)
        if ([IO.File]::Exists($path)) { return $path }
        if (-not [IO.Path]::GetExtension($Command)) {
            foreach ($suffix in $suffixes) {
                if ([IO.File]::Exists($path + $suffix)) { return $path + $suffix }
            }
        }
        return $null
    }
    $candidates = @('')
    if (-not [IO.Path]::GetExtension($Command)) { $candidates = $suffixes }
    $searchPath = @()
    if ($PreferredPath) { $searchPath += $PreferredPath }
    $searchPath += [Environment]::GetEnvironmentVariable('PATH') -split ';'
    foreach ($directory in $searchPath) {
        if (-not $directory) { continue }
        foreach ($extension in $candidates) {
            $path = Join-Path $directory ($Command + $extension)
            if ([IO.File]::Exists($path)) { return [IO.Path]::GetFullPath($path) }
        }
    }
    return $null
}

function Invoke-JdkCommand {
    param([string]$Selector, [string[]]$CommandArguments)
    $resolved = Resolve-Home $Selector $Selector -Physical
    $selectedBin = Join-Path $resolved.Home 'bin'
    $commandPath = Find-Executable $CommandArguments[0] $selectedBin
    if (-not $commandPath) { Stop-Jvm "command not found: $($CommandArguments[0])" 127 }
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $commandPath
    $start.WorkingDirectory = (Get-Location).Path
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $quoted = @($CommandArguments | Select-Object -Skip 1 |
        ForEach-Object { ConvertTo-WindowsArgument ([string]$_) })
    if ($extension -eq '.ps1') {
        # Honors the user's execution policy; no override is applied.
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        if (-not [IO.File]::Exists($start.FileName)) {
            # Started from another host such as PowerShell 7: use Windows PowerShell.
            $start.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        }
        $quoted = @('-NoProfile', '-NonInteractive', '-File',
            (ConvertTo-WindowsArgument $commandPath)) + $quoted
    }
    $start.Arguments = $quoted -join ' '
    $start.EnvironmentVariables['JAVA_HOME'] = $resolved.Home
    $start.EnvironmentVariables['PATH'] = $selectedBin + ';' +
        [Environment]::GetEnvironmentVariable('PATH')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { Stop-Jvm 'cannot start command' 126 }
        # Drain both pipes concurrently to avoid deadlock when either buffer fills.
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        while ($null -ne $stdout -or $null -ne $stderr) {
            if ($null -ne $stdout -and $stdout.IsCompleted) {
                $line = $stdout.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdout = $null }
                else { Write-Output $line; $stdout = $process.StandardOutput.ReadLineAsync() }
            }
            if ($null -ne $stderr -and $stderr.IsCompleted) {
                $line = $stderr.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderr = $null }
                else { Write-JvmDiagnostic $line; $stderr = $process.StandardError.ReadLineAsync() }
            }
            if (($null -ne $stdout -or $null -ne $stderr) -and
                ($null -eq $stdout -or -not $stdout.IsCompleted) -and
                ($null -eq $stderr -or -not $stderr.IsCompleted)) {
                Start-Sleep -Milliseconds 10
            }
        }
        $process.WaitForExit()
        $script:CommandExitCode = $process.ExitCode
    } catch [ComponentModel.Win32Exception] {
        Stop-Jvm "cannot execute command: $($CommandArguments[0])" 126
    } finally { $process.Dispose() }
}

function Get-ReplacementDefault {
    param([string]$Removed, [string]$Version, [string]$Major = '')
    $rows = @(Get-LocalInventory | Where-Object { $_.Id -cne $Removed -and $_.Status -eq '.' })
    if ($Major) {
        $same = @(Sort-RowsById @($rows | Where-Object { $_.Major -ceq $Major }))
        if ($same.Count) { return $same[0].Id }
        return ''
    }
    if (-not $Version) {
        $first = @(Sort-RowsById $rows)
        if ($first.Count) { return $first[0].Id }
        return ''
    }
    $oldMajor = ConvertTo-Major $Version
    $valid = @($rows | Where-Object { $_.Major } | Sort-Object Id)
    if (-not $valid.Count) { return '' }
    $same = @($valid | Where-Object { $_.Major -ceq $oldMajor })
    if ($same.Count) { return $same[0].Id }
    $higher = $null
    $lower = $null
    foreach ($candidate in $valid) {
        $comparison = Compare-Major $candidate.Major $oldMajor
        if ($comparison -gt 0 -and
            (-not $higher -or (Compare-Major $candidate.Major $higher.Major) -lt 0 -or
                ($candidate.Major -ceq $higher.Major -and
                    [String]::CompareOrdinal($candidate.Id, $higher.Id) -lt 0))) {
            $higher = $candidate
        }
        if ($comparison -lt 0 -and
            (-not $lower -or (Compare-Major $candidate.Major $lower.Major) -gt 0 -or
                ($candidate.Major -ceq $lower.Major -and
                    [String]::CompareOrdinal($candidate.Id, $lower.Id) -lt 0))) {
            $lower = $candidate
        }
    }
    if ($higher) { return $higher.Id }
    if ($lower) { return $lower.Id }
    return ''
}

function Invoke-Uninstall {
    param([string]$Selector)
    Initialize-Host
    $rows = @(Get-LocalInventory)
    $matches = @(Get-Matches $rows $Selector -NoRange)
    if ($matches.Count -ne 1) { Stop-Jvm "No JDK found matching: $Selector" }
    $row = $matches[0]
    $id = $row.Id
    if (-not (Test-LocalId $id)) { Stop-Jvm 'unsafe installation ID' }
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DataPath 'tmp'))
    $removal = New-WorkDirectory (Join-Path $script:DataPath 'tmp') "remove-$id-"
    $global = Get-DefaultTargetId 'default' -Quiet
    $references = @()
    if (Test-Path -LiteralPath $script:JdksPath) {
      foreach ($item in @(Get-ChildItem -LiteralPath $script:JdksPath -Force -Directory)) {
        if ((Test-Major $item.Name) -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $target = Get-DefaultTargetId $item.Name -Quiet
            if ($target -ceq $id) { $references += $item.Name }
        }
      }
    }
    $changed = New-Object System.Collections.Generic.List[object]
    try {
        if ($global -ceq $id) {
            $replacement = Get-ReplacementDefault $id $row.JavaVersion
            Set-ManagedDefault $replacement 'default'
            $changed.Add([pscustomobject]@{ Name = 'default'; Id = $replacement })
        }
        foreach ($major in $references) {
            $replacement = Get-ReplacementDefault $id $row.JavaVersion $major
            Set-ManagedDefault $replacement $major
            $changed.Add([pscustomobject]@{ Name = $major; Id = $replacement })
        }
        try { [IO.Directory]::Move((Join-Path $script:JdksPath $id), (Join-Path $removal $id)) }
        catch {
            foreach ($entry in $changed) { Set-ManagedDefault $id $entry.Name }
            $hint = if ($script:Os -eq 'windows') { ' (it might be in use)' } else { '' }
            Stop-Jvm "couldn't uninstall $id$hint"
        }
        Remove-TreeNoFollow (Join-Path $removal $id)
        [IO.Directory]::Delete($removal)
        Write-JvmDiagnostic ("Successfully uninstalled $id")
        foreach ($entry in $changed) { Write-DefaultReport $entry.Id $entry.Name }
    } finally {
        if (Test-Path -LiteralPath $removal) {
            if (-not (Get-ChildItem -LiteralPath $removal -Force)) { [IO.Directory]::Delete($removal) }
        }
    }
}

function Show-Help {
    Write-Output (@'
jvm finds and installs Java Development Kits for this computer.

Usage: .\jvm <command> [options] [selector]

Commands:
  available, a [-t] [selector]      Show compatible JDKs available to download.
  install, i [-d] [selector]        Download, verify and install a JDK.
  uninstall, u <selector>           Remove an installed JDK.
  list, l [selector]                Show JDK folders and manifest status, offline.
  default, d [-v <major>] [selector]  Show or select a persistent default.
  home, h [selector]           Print an installed JDK home or default path.
  env, e [-f] [selector]       Print PowerShell environment assignments.
  exec, x <selector> [--] <command> [args...]  Run with a selected JDK.
  --help                            Show this help.
  --version                         Show the jvm version.

default/home/env/exec install automatically when no installed JDK matches.
Without a selector, default only queries its reference.
exec requires a selector; _ uses project java, user java, default, then fallback.
The _ placeholder is exclusive to exec/x and is not a configuration value.
One optional -- immediately after the exec selector is skipped.
The command and all later arguments are forwarded unchanged.

Selectors:
  available/list: major (21), distro (temurin), or distro-major (temurin-21).
  install/uninstall/default/home/env/exec: full ID, major, or distro-major.
  Ranges (except uninstall): 21+, 21..26, temurin-21+; listings show all matches.
  Ranges select the highest major, then its eligible default, then C ID order.
  Install ranges reuse local matches first; remote majors/ranges use configured distro or Temurin.
  Majors use java_version; IDs use version, with a Java-major prefix if needed.

Options:
  -t  available: show release type/features in a final TYPE column.
  -d  install: make the installed JDK the persistent default.
  -f  env: always print the PATH assignment.
  -v  default: query or set the specified Java major's default.

Configuration (optional, literal key=value lines):
  .\.jvmrc, then $XDG_CONFIG_HOME\jvm\config (or ~/.config/jvm/config).
  Keys: java=21+ and distro=graalvm-community. No parent-directory lookup.
  CLI selector > project java > user java. Install falls back to major {0}.
  Omitted home/env selectors and exec _ then use the installed default, or major {0} if it is absent.

PowerShell examples:
  jvm install
  jvm i -d temurin-21
  jvm uninstall temurin-21
  jvm default -v 21 temurin-21
  jvm home 21
  iex (jvm env temurin-21)
  jvm x 21 java.exe -version
  jvm x _ -- java.exe -version

Shell setup (once, in your PowerShell profile):
  $env:JAVA_HOME = "$HOME\.local\share\jvm\jdks\default"
  $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
'@ -f $script:DefaultVersion)
}

function Invoke-Jvm {
    param([string[]]$Arguments)
    $command = if ($Arguments.Count) { $Arguments[0] } else { '' }
    $aliases = @{ a = 'available'; i = 'install'; u = 'uninstall'; l = 'list'
        d = 'default'; h = 'home'; e = 'env'; x = 'exec' }
    if ($aliases.ContainsKey($command)) { $command = $aliases[$command] }
    if ($command -in @('--help', '--version')) {
        if ($Arguments.Count -ne 1) { Stop-Jvm "$command takes no arguments" 2 }
        if ($command -eq '--help') { Show-Help } else { Write-Output ("jvm $script:Version") }
        return
    }
    if ($command -notin @('available', 'install', 'uninstall', 'list', 'default', 'home', 'env', 'exec')) {
        Stop-Jvm 'usage: jvm <command> [selector]; use jvm --help' 2
    }
    $remaining = @($Arguments | Select-Object -Skip 1)
    if ($remaining.Count -eq 1 -and $remaining[0] -eq '--help') { Show-Help; return }
    $selector = ''; $option = ''; $majorOption = ''; $forcePath = $false; $showType = $false
    $commandArgs = @()
    if ($command -eq 'exec') {
        if (-not $remaining.Count -or -not $remaining[0]) {
            Stop-Jvm 'usage: jvm exec <selector> [--] <command> [args...]' 2
        }
        $selector = $remaining[0]
        $commandIndex = 1
        if ($remaining.Count -gt $commandIndex -and $remaining[$commandIndex] -ceq '--') {
            $commandIndex++
        }
        if ($remaining.Count -le $commandIndex -or -not $remaining[$commandIndex]) {
            Stop-Jvm 'usage: jvm exec <selector> [--] <command> [args...]' 2
        }
        $commandArgs = @($remaining | Select-Object -Skip $commandIndex)
        if ($selector -ceq '_') { $selector = '' }
    } else {
        for ($i = 0; $i -lt $remaining.Count; $i++) {
            $argument = [string]$remaining[$i]
            if ($command -eq 'default' -and $argument -eq '-v') {
                if ($majorOption -or $i + 1 -ge $remaining.Count -or
                    -not (Test-Major ([string]$remaining[$i + 1]))) {
                    Stop-Jvm '-v requires one positive Java major' 2
                }
                $majorOption = [string]$remaining[$i + 1]; $i++; continue
            }
            if (($command -eq 'available' -and $argument -eq '-t') -or
                ($command -eq 'env' -and $argument -eq '-f')) {
                if (($command -eq 'available' -and $showType) -or
                    ($command -eq 'env' -and $forcePath)) { Stop-Jvm 'duplicate flag' 2 }
                if ($command -eq 'available') { $showType = $true } else { $forcePath = $true }
                continue
            }
            if ($argument -eq '-d' -and $command -eq 'install') {
                if ($option) { Stop-Jvm 'duplicate flag' 2 }
                $option = $argument; continue
            }
            if ($argument.StartsWith('-')) { Stop-Jvm "unsupported flag: $argument" 2 }
            if (-not $argument -or $selector) { Stop-Jvm 'expected one nonempty selector' 2 }
            $selector = $argument
        }
    }
    if (-not $selector) {
        if ($command -eq 'uninstall') {
            Stop-Jvm 'usage: jvm uninstall <selector>' 2
        }
    }
    if ($command -in @('install', 'home', 'env', 'exec', 'default', 'uninstall') -and $selector) {
        $parsed = Get-Selector $selector
        $valid = $parsed.Kind -in @('id', 'major', 'distro-major', 'range')
        if ($command -eq 'uninstall' -and $parsed.Kind -eq 'range') { $valid = $false }
        if (-not $valid -and -not (Test-ExistingInstallationDirectory $selector)) {
            Stop-Jvm 'selector must be a full ID, major, or distro-major (version ranges allowed except for uninstall)' 2
        }
        if ($selector.Length -gt 180) { Stop-Jvm 'selector is too long' 2 }
    }
    if ($command -in @('install', 'home', 'env', 'exec') -and -not $selector) {
        $selector = Get-ConfigSetting java
        if (-not $selector -and $command -eq 'install') { $selector = $script:DefaultVersion }
        if (-not $selector) {
            Initialize-DataPath
            if (-not (Test-PathEntry (Join-Path $script:JdksPath 'default'))) {
                $selector = $script:DefaultVersion
            }
        }
    }
    if ($selector -and $command -in @('default', 'home', 'env', 'exec')) {
        $resolved = Resolve-Selection $selector $majorOption `
            -UseConfig:($command -ne 'default')
        $selectorForOutput = $selector
        $selector = $resolved.Id
    } else { $selectorForOutput = $selector }
    switch ($command) {
        available { Invoke-Available $selector -ShowType:$showType }
        list { Invoke-List $selector }
        install { [void](Install-Jdk $selector $option '' -UseConfig) }
        uninstall { Invoke-Uninstall $selector }
        default { Invoke-Default $selector $(if ($majorOption) { $majorOption } else { 'default' }) }
        home { Invoke-HomeOrEnvironment 'home' $selector $selectorForOutput }
        env { Invoke-HomeOrEnvironment 'env' $selector $selectorForOutput -ForcePath:$forcePath -OriginalArguments $Arguments }
        exec { return Invoke-JdkCommand $selector $commandArgs }
    }
}

try {
    Invoke-Jvm @($args)
    exit $script:CommandExitCode
} catch {
    # .NET calls can wrap ordinary filesystem/network failures in an invocation
    # exception. Inspect the chain without treating programming errors as usage.
    $failure = $_.Exception
    $expected = $false
    while ($failure) {
        if ($failure.Data.Contains('JvmExpected') -or
            $failure -is [IO.IOException] -or
            $failure -is [UnauthorizedAccessException] -or
            $failure -is [Net.WebException] -or
            $failure -is [Security.SecurityException]) {
            $expected = $true
            break
        }
        $failure = $failure.InnerException
    }
    if ($expected) {
        Write-JvmError $_.Exception.Message
        exit $script:ExitCode
    }
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
