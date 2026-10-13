$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    function Write-HelperLog([string]$text) {
        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        [Console]::Error.WriteLine($stamp + ' bootstrap ' + $PID + ': ' + $text)
    }

    $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $source = Join-Path $dir 'helper.cs'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($source)))).Replace('-', '').ToLower()
    $stem = 'helper-' + $hash.Substring(0, 16)
    $name = $stem + '.dll'
    $dll = Join-Path $dir $name

    # A temp file belongs to a running compile when the PowerShell process named in it started before the file was created.
    Get-ChildItem -LiteralPath $dir -Filter 'helper-*.tmp.dll' | ForEach-Object {
        $running = $false
        try {
            if ($_.Name -match '\.(\d+)\.tmp\.dll$') {
                $owner = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
                if ($owner -and $owner.ProcessName -eq 'powershell' -and $owner.StartTime -le $_.CreationTime) {
                    $running = $true
                }
            }
        } catch {
            $running = $true
        }
        if (-not $running) {
            try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
        }
    }

    # Loads the assembly from the file's bytes, which leaves the file unlocked.
    function Import-Helper([string]$path) {
        [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($path)) | Out-Null
    }

    $loaded = $false
    if (Test-Path -LiteralPath $dll) {
        try {
            Import-Helper $dll
            $loaded = $true
            Write-HelperLog ('loaded ' + $name + ' after ' + $watch.ElapsedMilliseconds + ' ms')
        } catch {
            Write-HelperLog ('cannot load ' + $name + ': ' + $_.Exception.Message)
            try { Remove-Item -LiteralPath $dll -Force } catch { }
        }
    }
    if (-not $loaded) {
        $tmp = Join-Path $dir ($stem + '.' + $PID + '.tmp.dll')
        $code = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        Add-Type -TypeDefinition $code -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase, System.Web.Extensions -OutputAssembly $tmp
        $compiled = $watch.ElapsedMilliseconds
        $moved = $true
        try {
            Move-Item -LiteralPath $tmp -Destination $dll -Force
        } catch {
            $moved = $false
        }
        if ($moved) {
            Import-Helper $dll
            Write-HelperLog ('compiled ' + $name + ' after ' + $compiled + ' ms')
        } else {
            try {
                Import-Helper $dll
                $loaded = $true
                Write-HelperLog ('compiled after ' + $compiled + ' ms; ' + $name + ' is in use, loaded that file')
            } catch {
                Import-Helper $tmp
                Write-HelperLog ('compiled after ' + $compiled + ' ms; ' + $name + ' cannot be replaced or loaded, loaded the new build')
            }
            try { Remove-Item -LiteralPath $tmp -Force } catch { }
        }
    }

    Get-ChildItem -LiteralPath $dir -Filter 'helper-*.dll' | Where-Object { $_.Name -ne $name -and $_.Name -notlike '*.tmp.dll' } | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
    }

    [Alcove.UiaHelper]::Run()
} catch {
    $text = $_.Exception.Message
    try { [Console]::Error.WriteLine('bootstrap ' + $PID + ' failed: ' + ($_ | Out-String)) } catch { }
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ ev = 'fatal'; error = $text }))
    [Console]::Out.Flush()
    exit 1
}
