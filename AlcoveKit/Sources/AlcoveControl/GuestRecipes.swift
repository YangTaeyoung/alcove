import Foundation
import AlcoveEngine
import AlcoveQMP

/// Scripts the host sends through the guest agent's `exec.run` to change guest settings and to probe guest health.
/// PowerShell scripts serve Windows guests, `sh` scripts Linux guests; a setting without a script for an OS returns nil.
enum GuestRecipes {
    /// The scaling percentages of Windows in ascending order. `SPI_SETLOGICALDPIOVERRIDE` takes a number of steps along
    /// this list, counted from the display's recommended scale.
    static let dpiSteps = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]

    private static let windowsPrelude = "$ErrorActionPreference = 'Stop'\n$WarningPreference = 'SilentlyContinue'\n"

    /// Quotes a value for a single-quoted PowerShell or sh string. Works on Unicode scalars, so a quote
    /// followed by a combining mark is still escaped.
    static func quote(_ s: String, os: VMConfig.GuestOS) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if os == .windows {
                out.append(scalar)
                if powerShellQuotes.contains(scalar.value) { out.append(scalar) }
            } else if scalar == "'" {
                out.append(contentsOf: "'\\''".unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return "'" + String(out) + "'"
    }

    private static let powerShellQuotes: Set<UInt32> = [0x27, 0x2018, 0x2019, 0x201A, 0x201B]

    /// Prints the process id of the process that started the shell running the script.
    static func parentProcessID(windows: Bool) -> String {
        windows ? "(Get-CimInstance Win32_Process -Filter \"ProcessId=$PID\").ParentProcessId" : "echo $PPID"
    }

    /// Prints `1` when the guest has a TCP listener on `port`, `0` otherwise.
    static func portListening(_ port: Int, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return "if (Get-NetTCPConnection -State Listen -LocalPort \(port) -ErrorAction SilentlyContinue) { '1' } else { '0' }"
        case .linux:
            return "command -v ss >/dev/null 2>&1 || { echo \"ss is not installed in the guest; install the iproute2 package\" >&2; exit 127; }\n"
                + "ss -ltn \"sport = :\(port)\" | tail -n +2 | grep -q . && echo 1 || echo 0"
        case .other:
            return nil
        }
    }

    static func setClock(unixSeconds: Int, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return windowsPrelude + "[void](Set-Date -Date ([DateTimeOffset]::FromUnixTimeSeconds(\(unixSeconds)).LocalDateTime))\n"
                + "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"
        case .linux:
            return "date -u -s @\(unixSeconds)"
        case .other:
            return nil
        }
    }

    static func setTimeZone(_ id: String, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows: return windowsPrelude + "Set-TimeZone -Id \(quote(id, os: os))\n(Get-TimeZone).Id"
        case .linux: return "timedatectl set-timezone \(quote(id, os: os))"
        case .other: return nil
        }
    }

    static func setTheme(dark: Bool, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        let value = dark ? 0 : 1
        return windowsPrelude + """
        $p = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'
        Set-ItemProperty -Path $p -Name AppsUseLightTheme -Value \(value) -Type DWord
        Set-ItemProperty -Path $p -Name SystemUsesLightTheme -Value \(value) -Type DWord
        Add-Type -Namespace Alcove -Name Broadcast -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);'
        $r = [UIntPtr]::Zero
        [void][Alcove.Broadcast]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$r)
        'theme: \(dark ? "dark" : "light")'
        """
    }

    /// `tag` is a BCP 47 language tag such as `ko-KR`.
    static func setLocale(_ tag: String, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + """
        $tag = \(quote(tag, os: os))
        Set-Culture $tag
        $list = Get-WinUserLanguageList
        if (-not ($list | Where-Object { $_.LanguageTag -eq $tag })) {
          $list.Insert(0, (New-WinUserLanguageList $tag)[0])
          Set-WinUserLanguageList -LanguageList $list -Force
        }
        "locale: $tag"
        """
    }

    /// The installed input languages become exactly `tags`, in order.
    static func setKeyboardLayouts(_ tags: [String], os: VMConfig.GuestOS) -> String? {
        guard os == .windows, let first = tags.first else { return nil }
        var script = windowsPrelude + "$list = New-WinUserLanguageList \(quote(first, os: os))\n"
        for tag in tags.dropFirst() { script += "$list.Add(\(quote(tag, os: os)))\n" }
        script += "Set-WinUserLanguageList -LanguageList $list -Force\n"
        script += "'layouts: ' + ((Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ', ')"
        return script
    }

    /// The index of the entry of `dpiSteps` nearest to `percent`.
    static func dpiStepIndex(percent: Int) -> Int {
        dpiSteps.indices.min { abs(dpiSteps[$0] - percent) < abs(dpiSteps[$1] - percent) } ?? 0
    }

    /// Asks Windows for the entry of `dpiSteps` nearest to `percent`, as a step counted from the recommended scale of
    /// the first active display, and prints one JSON object: `applied`, the percentage a process started after the
    /// change reads as the system DPI; `recommended`; and `offered`, the percentages the display offers at its resolution.
    /// When the requested entry is above what the display offers, the entry Windows applied becomes the stored setting.
    static func setDPIScale(percent: Int, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        let steps = dpiSteps.map(String.init).joined(separator: ", ")
        let index = dpiStepIndex(percent: percent)
        return windowsPrelude + """
        Add-Type -Namespace Alcove -Name Dpi -MemberDefinition '
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathInfo, ref uint modes, byte[] modeInfo, IntPtr topology);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, int param, IntPtr pvParam, uint flags);
        public static int[] Range() {
          uint paths, modes;
          if (GetDisplayConfigBufferSizes(2, out paths, out modes) != 0 || paths == 0) return null;
          byte[] pathInfo = new byte[72 * paths], modeInfo = new byte[64 * modes];
          if (QueryDisplayConfig(2, ref paths, pathInfo, ref modes, modeInfo, IntPtr.Zero) != 0 || paths == 0) return null;
          byte[] packet = new byte[32];
          BitConverter.GetBytes(-3).CopyTo(packet, 0);
          BitConverter.GetBytes(32).CopyTo(packet, 4);
          Array.Copy(pathInfo, 0, packet, 8, 12);
          if (DisplayConfigGetDeviceInfo(packet) != 0) return null;
          return new int[] { BitConverter.ToInt32(packet, 20), BitConverter.ToInt32(packet, 24), BitConverter.ToInt32(packet, 28) };
        }'
        $steps = \(steps)
        $range = [Alcove.Dpi]::Range()
        if ($null -eq $range) { throw 'the guest did not report the scale range of its display; sign in to the guest desktop and set dpiScale again' }
        $recommended = -$range[0]
        if (-not [Alcove.Dpi]::SystemParametersInfo(0x009F, \(index) - $recommended, [IntPtr]::Zero, 3)) {
          throw 'Windows refused the display scale; sign in to the guest desktop and set dpiScale again'
        }
        $probe = '$ProgressPreference = ''SilentlyContinue''; Add-Type -Namespace Alcove -Name Scale -MemberDefinition ''[DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern uint GetDpiForSystem();''; [void][Alcove.Scale]::SetProcessDPIAware(); [Alcove.Scale]::GetDpiForSystem()'
        $dpi = & powershell.exe -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe)))
        $applied = [int]([int]$dpi * 100 / 96)
        $index = [Array]::IndexOf($steps, $applied)
        if ($index -ge 0 -and \(index) -gt $range[2] - $range[0]) { [void][Alcove.Dpi]::SystemParametersInfo(0x009F, $index - $recommended, [IntPtr]::Zero, 3) }
        [pscustomobject]@{ applied = $applied; recommended = $steps[$recommended]; offered = @($steps[0..($range[2] - $range[0])]) } | ConvertTo-Json -Compress
        """
    }

    /// Whether the scale `setDPIScale` printed as `applied` in `output` is `requested`, and the row detail: `scale: <p> %`,
    /// or the applied scale with the offered scales nearest to the request.
    static func dpiScaleResult(requested: Int, output: String) -> (ok: Bool, detail: String) {
        var printed: JSON?
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let json = try? JSON.parse(Data(line.utf8)), json.objectValue != nil { printed = json; break }
        }
        guard let applied = printed?["applied"]?.intValue, applied > 0 else {
            return (false, "the guest did not report the scale it applied; read the scale row of vm.doctor")
        }
        if applied == requested { return (true, "scale: \(applied) %") }
        let offered = (printed?["offered"]?.arrayValue ?? []).compactMap(\.intValue).sorted()
        let below = offered.last { $0 <= requested }
        let above = offered.first { $0 >= requested }
        let next: String
        switch (below, above) {
        case let (below?, above?) where below == above:
            next = "the guest offers \(requested) % and did not apply it; read the scale row of vm.doctor and set dpiScale again"
        case let (below?, above?):
            next = "the nearest scales the guest offers are \(below) % and \(above) %; request one of them"
        case let (below?, nil) where dpiSteps.contains(requested):
            next = "the largest scale the guest offers at its resolution is \(below) %; request it, or set a larger resolution with vm.set_resolution first"
        case let (below?, nil):
            next = "the nearest scale the guest offers is \(below) %; request it"
        case let (nil, above?):
            next = "the smallest scale the guest offers is \(above) %; request it"
        case (nil, nil):
            next = "request \(applied), or read the scale row of vm.doctor"
        }
        return (false, "scale: \(applied) % was applied, not \(requested) %; \(next)")
    }

    /// Prints one JSON object: `user`, `freeBytes`, `utc`, `dns` and, where the guest can tell, `locked` and `scale`
    /// (on Windows the system DPI a DPI-aware process reads, as a percentage of 96).
    static func doctorProbe(os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return """
            $ErrorActionPreference = 'SilentlyContinue'
            $dns = $false
            try { if ([System.Net.Dns]::GetHostAddresses('example.com').Count -gt 0) { $dns = $true } } catch { }
            $free = (Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
            $o = [ordered]@{
              user = [Environment]::UserName
              locked = [bool](Get-Process LogonUI -ErrorAction SilentlyContinue)
              freeBytes = [int64]$free
              utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
              dns = $dns
            }
            try {
              Add-Type -Namespace Alcove -Name Scale -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern uint GetDpiForSystem();'
              [void][Alcove.Scale]::SetProcessDPIAware()
              $dpi = [Alcove.Scale]::GetDpiForSystem()
              if ($dpi) { $o.scale = [int]($dpi * 100 / 96) }
            } catch { }
            [pscustomobject]$o | ConvertTo-Json -Compress
            """
        case .linux:
            return """
            dns=false; getent hosts example.com >/dev/null 2>&1 && dns=true
            free=$(df -Pk / | awk 'NR==2 { printf "%.0f", $4 * 1024 }')
            printf '{"user":"%s","freeBytes":%s,"utc":"%s","dns":%s}\\n' "$(id -un)" "${free:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dns"
            """
        case .other:
            return nil
        }
    }

    // MARK: - event log and crash dumps

    /// The folder Windows Error Reporting writes crash dumps into.
    static let dumpFolder = "C:\\alcove-dumps"
    /// The most bytes of serialised entries the Windows event log recipe prints.
    static let eventOutputBudget = 150_000
    /// The most characters of one event message the host returns.
    static let eventMessageLimit = 2000
    /// The Windows event levels of `level` and everything more severe; empty for `info`, which names every level.
    static func windowsLevels(_ level: String) -> [Int]? {
        switch level {
        case "critical": return [1]
        case "error": return [1, 2]
        case "warning": return [1, 2, 3]
        case "info": return []
        default: return nil
        }
    }

    /// The journal priority of `level`; the journal reports that priority and every more severe one.
    static func journalPriority(_ level: String) -> Int? {
        ["critical": 2, "error": 3, "warning": 4, "info": 6][level]
    }

    /// Escapes the regular expression metacharacters of `text`.
    static func regexEscaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\.^$*+?()[]{}|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Windows: prints one JSON object `{entries, truncated}` with `entries` in the log's record order, newest record first,
    /// each `{time, id, level, provider, message}`; `time` is ISO 8601 UTC and `message` is cut at `eventMessageLimit`
    /// UTF-16 units, one less when the cut would split a surrogate pair; `truncated` is true when the next entry did not
    /// fit `eventOutputBudget` bytes of serialised output. The log, the time window, the levels and a provider name
    /// without an apostrophe are selected by an XPath query; a provider name with an apostrophe and `contains` are
    /// matched in the pipeline. A log that is missing or closed to the agent's user and a failed read each print one
    /// sentence on stderr and exit with 2.
    /// Linux: prints the journal as one JSON object per line in time order, so a cut output loses the oldest lines.
    /// `level` is `critical`, `error`, `warning` or `info`.
    static func eventLog(log: String, level: String?, provider: String?, sinceMinutes: Int, contains: String?, max: Int,
                         os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            var script = windowsPrelude + "$log = \(quote(log, os: os))\n"
            script += """
            if (-not (Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue -ErrorVariable listErrors)) {
              if ($listErrors | Where-Object { $_.FullyQualifiedErrorId -like 'LogInfoUnavailable*' }) { [Console]::Error.WriteLine("guest tools may not read the event log '$log'; check that alcove-agent runs elevated"); exit 2 }
              [Console]::Error.WriteLine("the guest has no event log named '$log'; list the logs with Get-WinEvent -ListLog *"); exit 2
            }

            """
            var query = "\"*[System[TimeCreated[@SystemTime>='\" + (Get-Date).ToUniversalTime().AddMinutes(-\(sinceMinutes)).ToString('o') + \"']"
            if let level, let levels = windowsLevels(level), !levels.isEmpty {
                query += " and (" + levels.map { "Level=\($0)" }.joined(separator: " or ") + ")"
            }
            query += "\""
            var pipeline = "Get-WinEvent -LogName $log -FilterXPath $query -ErrorAction SilentlyContinue"
            if let provider {
                script += "$provider = \(quote(provider, os: os))\n"
                if provider.unicodeScalars.contains("'") {
                    pipeline += " | Where-Object { $_.ProviderName -eq $provider }"
                } else {
                    query += " + \" and Provider[@Name='\" + $provider + \"']\""
                }
            }
            query += " + ']]'"
            if let contains {
                script += "$needle = \(quote(contains, os: os))\n"
                pipeline += " | Where-Object { $_.Message -and $_.Message.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 }"
            }
            script += """
            $parts = New-Object System.Collections.ArrayList
            $truncated = $false
            try {
              $query = \(query)
              $events = @(\(pipeline) | Select-Object -First \(max))
              $levels = @{ 1 = 'critical'; 2 = 'error'; 3 = 'warning' }
              $bytes = 0
              foreach ($e in $events) {
                $m = [string]$e.Message
                if ($m.Length -gt \(eventMessageLimit)) {
                  $cut = \(eventMessageLimit)
                  if ([char]::IsHighSurrogate($m[$cut - 1])) { $cut = $cut - 1 }
                  $m = $m.Substring(0, $cut)
                }
                $level = $levels[[int]$e.Level]
                if (-not $level) { $level = 'info' }
                $json = [pscustomobject][ordered]@{
                  time = $e.TimeCreated.ToUniversalTime().ToString('o')
                  id = [int]$e.Id
                  level = $level
                  provider = [string]$e.ProviderName
                  message = $m
                } | ConvertTo-Json -Compress -Depth 3
                $size = [Text.Encoding]::UTF8.GetByteCount($json) + 1
                if ($bytes + $size -gt \(eventOutputBudget)) { $truncated = $true; break }
                $bytes += $size
                [void]$parts.Add($json)
              }
            } catch {
              $base = $_.Exception.GetBaseException()
              $hint = '; read the log with vm.exec to see the full error'
              if ($base -is [System.UnauthorizedAccessException] -or $base -is [System.Security.SecurityException]) { $hint = '; check that alcove-agent runs elevated, or read the log with vm.exec' }
              [Console]::Error.WriteLine("could not read the event log '$log': " + ($base.Message -replace '\\s+', ' ') + $hint)
              exit 2
            }
            '{"entries":[' + ($parts -join ',') + '],"truncated":' + $(if ($truncated) { 'true' } else { 'false' }) + '}'
            """
            return script
        case .linux:
            var command = "journalctl -o json --no-pager -n \(max) --since=-\(sinceMinutes)min"
            command += " --output-fields=PRIORITY,SYSLOG_IDENTIFIER,_COMM,_PID,SYSLOG_PID,MESSAGE"
            if let level, let priority = journalPriority(level) { command += " -p \(priority)" }
            if let provider { command += " -t \(quote(provider, os: os))" }
            if let contains { command += " --case-sensitive=false --grep=\(quote(regexEscaped(contains), os: os))" }
            return "command -v journalctl >/dev/null 2>&1 || { echo \"journalctl is not installed in the guest; read the logs with vm.exec instead\" >&2; exit 127; }\n"
                + command
        case .other:
            return nil
        }
    }

    private static func localDumpsKey(_ exe: String) -> String {
        "$root = 'SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps'\n$sub = $root + '\\' + \(quote(exe, os: .windows))\n"
    }

    private static let openLocalMachine =
        "$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)"

    /// Windows only: creates `dumpFolder`, grants the Users group modify rights on it and sets the Windows Error Reporting
    /// local dump values for `exe` (`DumpFolder`, `DumpCount` 5, `DumpType` 1 mini or 2 full). A `LocalDumps` key that
    /// does not exist yet is created with the value `AlcoveCreated` (DWord 1). Prints `{"folder": ..., "createdKey": ...}`
    /// where `createdKey` tells whether it created the `LocalDumps` key.
    /// A failure prints one sentence on stderr and exits with 2.
    static func enableDumps(exe: String, full: Bool, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + localDumpsKey(exe) + """
        $folder = '\(dumpFolder)'
        try {
          [void](New-Item -ItemType Directory -Force -Path $folder)
          if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [Console]::Error.WriteLine('\(dumpFolder) is not a folder; remove or rename that file, then call vm.crash_dumps.enable again'); exit 2 }
          $ErrorActionPreference = 'Continue'
          $null = & icacls.exe $folder /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1
          $ErrorActionPreference = 'Stop'
          if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('could not make \(dumpFolder) writable for the Users group; check that alcove-agent runs elevated and may change the permissions of that folder'); exit 2 }
          \(openLocalMachine)
          $existing = $hklm.OpenSubKey($root)
          if ($existing) { $existing.Close() }
          $createdKey = -not $existing
          if ($createdKey) {
            $parent = $hklm.CreateSubKey($root)
            $parent.SetValue('AlcoveCreated', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $parent.Close()
          }
          $key = $hklm.CreateSubKey($sub)
          $key.SetValue('DumpFolder', $folder, [Microsoft.Win32.RegistryValueKind]::ExpandString)
          $key.SetValue('DumpCount', 5, [Microsoft.Win32.RegistryValueKind]::DWord)
          $key.SetValue('DumpType', \(full ? 2 : 1), [Microsoft.Win32.RegistryValueKind]::DWord)
          $key.Close()
        } catch {
          [Console]::Error.WriteLine('could not set up crash dumps: ' + ($_.Exception.GetBaseException().Message -replace '\\s+', ' ') + '; check that alcove-agent runs elevated')
          exit 2
        }
        [pscustomobject]@{ folder = $folder; createdKey = $createdKey } | ConvertTo-Json -Compress
        """
    }

    /// Windows only: removes the local dump key of `exe`, then the `LocalDumps` key itself when its only value is
    /// `AlcoveCreated` and it holds no subkey; other images keep theirs. A failure to remove the `LocalDumps` key is ignored. A failure prints one sentence on stderr and exits with 2.
    static func disableDumps(exe: String, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + localDumpsKey(exe) + """
        try {
          \(openLocalMachine)
          $hklm.DeleteSubKeyTree($sub, $false)
          if ($hklm.OpenSubKey($sub)) { [Console]::Error.WriteLine('the crash dump setting is still there after its removal; check that alcove-agent runs elevated'); exit 2 }
          $parent = $hklm.OpenSubKey($root)
          if ($parent) {
            $owned = $null -ne $parent.GetValue('AlcoveCreated') -and $parent.ValueCount -eq 1 -and $parent.SubKeyCount -eq 0
            $parent.Close()
            if ($owned) { try { $hklm.DeleteSubKey($root, $false) } catch { } }
          }
        } catch {
          [Console]::Error.WriteLine('could not remove the crash dump setting: ' + ($_.Exception.GetBaseException().Message -replace '\\s+', ' ') + '; check that alcove-agent runs elevated')
          exit 2
        }
        'ok'
        """
    }

    /// Windows only: prints a JSON array of the `.dmp` files in `dumpFolder`, newest first and by name within one time,
    /// each `{file, exe, bytes, time, now}`. `exe` is the image name of a file named `<image>.<pid>.dmp` or
    /// `<image>(<n>).<pid>.dmp`, otherwise empty. `time` is the file's last write and `now` the guest's clock when the
    /// folder was listed, both ISO 8601 UTC. A missing folder prints `[]`. A failure prints one sentence on stderr
    /// and exits with 2.
    static func listDumps(os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + """
        $folder = '\(dumpFolder)'
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $items = @()
        try {
          if (Test-Path -LiteralPath $folder -PathType Container) {
            $items = @(Get-ChildItem -LiteralPath $folder -File -Filter *.dmp | Where-Object { $_.Extension -ieq '.dmp' } | Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } | ForEach-Object {
              $exe = ''
              if ($_.Name -match '^(.+\\.exe)(\\([0-9]+\\))?\\.[0-9]+\\.dmp$') { $exe = $Matches[1] }
              [pscustomobject][ordered]@{ file = $_.Name; exe = $exe; bytes = [int64]$_.Length; time = $_.LastWriteTimeUtc.ToString('o'); now = $now }
            })
          }
        } catch {
          [Console]::Error.WriteLine('could not list the dumps in \(dumpFolder): ' + ($_.Exception.GetBaseException().Message -replace '\\s+', ' ') + '; check the folder permissions')
          exit 2
        }
        ConvertTo-Json -InputObject @($items) -Compress -Depth 4
        """
    }
}
