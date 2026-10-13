$ErrorActionPreference = 'Stop'
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

    if (Test-Path -LiteralPath $dll) {
        [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
    } else {
        $code = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        Add-Type -TypeDefinition $code -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase, System.Web.Extensions -OutputAssembly $dll
        [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
    }

    Get-ChildItem -LiteralPath $dir -Filter 'helper-*.dll' | Where-Object { $_.Name -ne $name } | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
    }

    [Alcove.UiaHelper]::Run()
} catch {
    $msg = $_.Exception.Message
    $json = '{"ev":"fatal","error":"' + ($msg -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", ' ' -replace "`n", ' ') + '"}'
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
    exit 1
}
