$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    $references = 'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'System.Web.Extensions'
    $code = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'helper.cs')
    Add-Type -TypeDefinition $code -ReferencedAssemblies $references
    $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    [Console]::Error.WriteLine($stamp + ' bootstrap ' + $PID + ': compiled helper.cs after ' + $watch.ElapsedMilliseconds + ' ms')

    [Alcove.UiaHelper]::Run()
} catch {
    $text = 'the UI helper could not be prepared in ' + $PSScriptRoot + ': ' + $_.Exception.Message + "; check free space and the folder's access list"
    try { [Console]::Error.WriteLine('bootstrap ' + $PID + ' failed: ' + ($_ | Out-String)) } catch { }
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ ev = 'fatal'; error = $text }))
    [Console]::Out.Flush()
    exit 1
}
