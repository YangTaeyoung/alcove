$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Stop-WithFatal([string]$text, $failure) {
    try { [Console]::Error.WriteLine('bootstrap ' + $PID + ' failed: ' + ($failure | Out-String)) } catch { }
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject @{ ev = 'fatal'; error = $text }))
    [Console]::Out.Flush()
    exit 1
}

try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $references = 'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase', 'System.Web.Extensions'
    $code = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'helper.cs')
} catch {
    Stop-WithFatal ('the UI helper could not be prepared in ' + $PSScriptRoot + ': ' + $_.Exception.Message + "; check free space and the folder's access list") $_
}

try {
    Add-Type -TypeDefinition $code -ReferencedAssemblies $references
    $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    [Console]::Error.WriteLine($stamp + ' bootstrap ' + $PID + ': compiled helper.cs after ' + $watch.ElapsedMilliseconds + ' ms')
} catch {
    $first = ($_.Exception.Message -split "\r?\n")[0] -replace '^.*\.cs\((\d+)\) : ', 'helper.cs line $1: '
    Stop-WithFatal ('the UI helper could not be compiled: ' + $first + '; reinstall the guest tools') $_
}

try {
    [Alcove.UiaHelper]::Run()
} catch {
    $failure = $_.Exception
    if ($failure.InnerException) { $failure = $failure.InnerException }
    Stop-WithFatal ('the UI helper stopped: ' + $failure.Message + '; retry, and restart alcove-agent if it repeats') $_
}
