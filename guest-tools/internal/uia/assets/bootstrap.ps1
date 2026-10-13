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

    $references = 'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'System.Web.Extensions'
    $code = Get-Content -Raw -Encoding UTF8 -LiteralPath $source

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

    $loaded = $false
    if (Test-Path -LiteralPath $dll) {
        try {
            [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dll)) | Out-Null
            $loaded = $true
            Write-HelperLog ('loaded ' + $name + ' after ' + $watch.ElapsedMilliseconds + ' ms')
        } catch {
            Write-HelperLog ('cannot load ' + $name + ': ' + $_.Exception.Message)
            try { Remove-Item -LiteralPath $dll -Force } catch { }
        }
    }
    if (-not $loaded) {
        # The helper runs from the bytes of this compile; the file is stored for later starts.
        $tmp = Join-Path $dir ($stem + '.' + $PID + '.tmp.dll')
        Add-Type -TypeDefinition $code -ReferencedAssemblies $references -OutputAssembly $tmp
        $compiled = $watch.ElapsedMilliseconds
        [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($tmp)) | Out-Null
        try {
            Move-Item -LiteralPath $tmp -Destination $dll -Force
            Write-HelperLog ('compiled ' + $name + ' after ' + $compiled + ' ms')
        } catch {
            Write-HelperLog ('compiled after ' + $compiled + ' ms; ' + $name + ' is in use and was not replaced')
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
