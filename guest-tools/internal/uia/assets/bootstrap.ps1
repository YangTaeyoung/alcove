$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8

    $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $source = Join-Path $dir 'helper.cs'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($source)))).Replace('-', '').ToLower()
    $name = 'helper-' + $hash.Substring(0, 16) + '.dll'
    $dll = Join-Path $dir $name

    $started = (Get-Date).AddSeconds(-1)
    Get-ChildItem -LiteralPath $dir -Filter 'helper-*.tmp.dll' | Where-Object { $_.LastWriteTime -lt $started } | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
    }

    $loaded = $false
    if (Test-Path -LiteralPath $dll) {
        try {
            [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
            $loaded = $true
        } catch {
            try { Remove-Item -LiteralPath $dll -Force } catch { }
        }
    }
    if (-not $loaded) {
        $tmp = Join-Path $dir ('helper-' + $hash.Substring(0, 16) + '.' + $PID + '.tmp.dll')
        $code = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        Add-Type -TypeDefinition $code -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase, System.Web.Extensions -OutputAssembly $tmp
        Move-Item -LiteralPath $tmp -Destination $dll -Force
        [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
    }

    Get-ChildItem -LiteralPath $dir -Filter 'helper-*.dll' | Where-Object { $_.Name -ne $name -and $_.Name -notlike '*.tmp.dll' } | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
    }

    [Alcove.UiaHelper]::Run()
} catch {
    $text = $_.Exception.Message
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ ev = 'fatal'; error = $text }))
    [Console]::Out.Flush()
    exit 1
}
