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

    /// Quotes a value for a single-quoted PowerShell or sh string, one Unicode scalar at a time: for PowerShell it
    /// doubles `'` and U+2018 to U+201B, for sh it writes `'\''` in place of `'`.
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
            printf '{"user":"%s","freeBytes":%s,"utc":"%s","dns":%s}\\n' "$(id -un)" "${free:-null}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dns"
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
    /// Linux: prints the journal as one JSON object per line, oldest first.
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

    /// The values `enableDumps` sets in the local dump key of an image.
    private static let dumpValues = "'DumpFolder', 'DumpCount', 'DumpType'"

    /// Windows only: makes `dumpFolder` a folder owned by the Administrators group that Administrators and SYSTEM
    /// control fully and the Users group can add files to, with no inherited entries, and sets the Windows Error
    /// Reporting local dump values for `exe` (`DumpFolder`, `DumpCount` 5, `DumpType` 1 mini or 2 full).
    /// An existing `dumpFolder` that is a link (a reparse point) or is owned by anyone but Administrators or SYSTEM is
    /// refused; `icacls` changes the folder itself, never what a link points to. A `LocalDumps` key that does not exist
    /// yet is created with the value `AlcoveCreated` (DWord 1), and so is an image key that does not exist yet. An
    /// existing image key without `AlcoveCreated` or `AlcovePrior` keeps a copy of each of its dump values as
    /// `AlcovePrior<name>` of the same kind and gets `AlcovePrior` (DWord 1). Prints `{"folder": ..., "createdKey": ...}`
    /// where `createdKey` tells whether it created the `LocalDumps` key.
    /// A failure prints one sentence on stderr and exits with 2.
    static func enableDumps(exe: String, full: Bool, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + localDumpsKey(exe) + """
        $folder = '\(dumpFolder)'
        try {
          $item = Get-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
          $createdFolder = -not $item
          if ($createdFolder) {
            [void](New-Item -ItemType Directory -Path $folder)
            $item = Get-Item -LiteralPath $folder -Force
          }
          if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [Console]::Error.WriteLine('\(dumpFolder) is a link; delete that link with vm.exec (Remove-Item without -Recurse), then call vm.crash_dumps.enable again'); exit 2 }
          if (-not $item.PSIsContainer) { [Console]::Error.WriteLine('\(dumpFolder) is not a folder; remove or rename that file, then call vm.crash_dumps.enable again'); exit 2 }
          if (-not $createdFolder) {
            $owner = (Get-Acl -LiteralPath $folder).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne 'S-1-5-32-544' -and $owner -ne 'S-1-5-18') { [Console]::Error.WriteLine('\(dumpFolder) belongs to ' + $owner + ', not to Administrators or SYSTEM, so another user may have changed it; delete that folder with vm.exec, then call vm.crash_dumps.enable again'); exit 2 }
          }
          $ErrorActionPreference = 'Continue'
          $null = & icacls.exe $folder /L /setowner '*S-1-5-32-544' 2>&1
          $owned = $LASTEXITCODE
          $null = & icacls.exe $folder /L /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)(IO)M' 2>&1
          $locked = $LASTEXITCODE
          $null = & icacls.exe $folder /L /grant '*S-1-5-32-545:(RX,WD)' 2>&1
          $writable = $LASTEXITCODE
          $ErrorActionPreference = 'Stop'
          if ($owned -ne 0 -or $locked -ne 0 -or $writable -ne 0) { [Console]::Error.WriteLine('could not lock \(dumpFolder) and make it writable for the Users group; check that alcove-agent runs elevated and may change the owner and the permissions of that folder'); exit 2 }
          if ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { [Console]::Error.WriteLine('\(dumpFolder) became a link while its permissions were set; delete that link with vm.exec, then call vm.crash_dumps.enable again'); exit 2 }
          \(openLocalMachine)
          $existing = $hklm.OpenSubKey($root)
          if ($existing) { $existing.Close() }
          $createdKey = -not $existing
          if ($createdKey) {
            $parent = $hklm.CreateSubKey($root)
            $parent.SetValue('AlcoveCreated', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $parent.Close()
          }
          $image = $hklm.OpenSubKey($sub)
          $createdImage = -not $image
          $marked = $false
          if ($image) {
            $marked = $null -ne $image.GetValue('AlcoveCreated') -or $null -ne $image.GetValue('AlcovePrior')
            $image.Close()
          }
          $key = $hklm.CreateSubKey($sub)
          if ($createdImage) {
            $key.SetValue('AlcoveCreated', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
          } elseif (-not $marked) {
            foreach ($name in \(dumpValues)) {
              if ($key.GetValueNames() -contains $name) {
                $key.SetValue('AlcovePrior' + $name, $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames), $key.GetValueKind($name))
              }
            }
            $key.SetValue('AlcovePrior', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
          }
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

    /// Windows only: undoes `enableDumps` for `exe`. An image key with `AlcoveCreated`, or without any `Alcove` value
    /// whose `DumpFolder` is `dumpFolder`, is removed; one with `AlcovePrior` gets back each dump value it had (a value
    /// it did not have is removed) and loses the `Alcove` values; any other image key is left as it is. Then the
    /// `LocalDumps` key itself is removed when its only value is `AlcoveCreated` and it holds no subkey. A failure to
    /// remove the `LocalDumps` key is ignored. A failure prints one sentence on stderr and exits with 2.
    static func disableDumps(exe: String, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + localDumpsKey(exe) + """
        $folder = '\(dumpFolder)'
        try {
          \(openLocalMachine)
          $key = $hklm.OpenSubKey($sub, $true)
          if ($key) {
            $names = $key.GetValueNames()
            $setFolder = [string]$key.GetValue('DumpFolder', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $remove = $names -contains 'AlcoveCreated' -or (-not ($names -contains 'AlcovePrior') -and -not ($names | Where-Object { $_ -like 'Alcove*' }) -and $setFolder -eq $folder)
            if ($remove) {
              $key.Close()
              $hklm.DeleteSubKeyTree($sub, $false)
              if ($hklm.OpenSubKey($sub)) { [Console]::Error.WriteLine('the crash dump setting is still there after its removal; check that alcove-agent runs elevated'); exit 2 }
            } elseif ($names -contains 'AlcovePrior') {
              foreach ($name in \(dumpValues)) {
                if ($names -contains ('AlcovePrior' + $name)) {
                  $key.SetValue($name, $key.GetValue('AlcovePrior' + $name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames), $key.GetValueKind('AlcovePrior' + $name))
                  $key.DeleteValue('AlcovePrior' + $name, $false)
                } else {
                  $key.DeleteValue($name, $false)
                }
              }
              $key.DeleteValue('AlcovePrior', $false)
              $key.Close()
            } else {
              $key.Close()
            }
          }
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

    // MARK: - HTTP capture: proxy CA and system proxy

    /// The address a guest on the user-mode network reaches the host at.
    static let proxyHost = "10.0.2.2"
    /// Where the proxy's CA certificate is kept in a Windows guest.
    static let windowsProxyCAPath = "C:\\ProgramData\\Alcove\\proxy-ca.pem"
    /// Where a Windows guest keeps the proxy settings from before a capture, the capture's port and its CA thumbprint.
    static let windowsProxyStatePath = "C:\\ProgramData\\Alcove\\proxy-previous.json"
    /// Where the proxy's CA certificate is kept in a Linux guest.
    static let linuxProxyCAPath = "/usr/local/share/ca-certificates/alcove-proxy.crt"
    /// Where a Linux guest keeps the proxy's CA certificate while its removal waits for the CA bundle to be rebuilt.
    static let linuxProxyCAAsidePath = "/usr/local/share/alcove-proxy.crt.removing"

    /// The guest path the proxy's CA certificate is pushed to; nil for a guest OS without a CA recipe.
    static func proxyCAPath(os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows: return windowsProxyCAPath
        case .linux: return linuxProxyCAPath
        case .other: return nil
        }
    }

    private static let proxyPaths = #"""
        $caPath = 'C:\ProgramData\Alcove\proxy-ca.pem'
        $statePath = 'C:\ProgramData\Alcove\proxy-previous.json'
        $inet = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $conn = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
        function AlcoveBool($value) { if ($value) { return 'true' }; return 'false' }

        """#

    /// `AlcoveCA`: the certificate of the PEM file at `$caPath`; nothing when the file holds no certificate block.
    private static let proxyCAReader = #"""
        function AlcoveCA {
          $m = [regex]::Match([System.IO.File]::ReadAllText($caPath), '-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----')
          if (-not $m.Success) { return $null }
          [byte[]]$der = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
          return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
        }

        """#

    /// `AlcoveRoot <flags>`: the machine's trusted root store, opened with the `OpenFlags` value named `flags`.
    /// `$byThumbprint`: the find type that selects a certificate by its thumbprint.
    private static let proxyRootStore = #"""
        function AlcoveRoot($flags) {
          $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
          $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]$flags)
          return $store
        }
        $byThumbprint = [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint

        """#

    /// The sentence a recipe fails with when the state file is there and does not hold a readable version 1 state.
    static let unreadableProxyState = "the stored proxy settings in C:\\ProgramData\\Alcove\\proxy-previous.json cannot be read; "
        + "put the proxy settings right by hand, delete that file and call vm.http.stop again"

    /// `AlcoveState`: the object stored in `$statePath`; nothing when the file is missing; the text `unreadable` when
    /// the file is there and does not hold a version 1 state with a thumbprint, a port and `systemProxy`. A read that
    /// fails is tried three times, 200 ms apart; a file that is gone after the last failed read counts as missing.
    /// `AlcoveSafe`: a string of base64 characters as it is, nothing for any other value.
    /// `AlcoveKindText`: `String`, `ExpandString` or `DWord` when the value is one of these names, nothing otherwise.
    private static let proxyStateReader = #"""
        function AlcoveState {
          if (-not [System.IO.File]::Exists($statePath)) { return $null }
          $text = $null
          foreach ($attempt in 1, 2, 3) {
            try { $text = [System.IO.File]::ReadAllText($statePath); break } catch { Start-Sleep -Milliseconds 200 }
          }
          if (($null -eq $text) -and (-not [System.IO.File]::Exists($statePath))) { return $null }
          $s = $null
          try { $s = ConvertFrom-Json $text } catch { $s = $null }
          if (($s -is [System.Management.Automation.PSCustomObject]) -and ([string]$s.version -ceq '1') -and ([string]$s.thumbprint -match '^[0-9A-Fa-f]{40}\z') -and ([string]$s.port -match '^[1-9][0-9]{0,4}\z') -and ($s.systemProxy -is [bool])) {
            if ([int]$s.port -le 65535) { return $s }
          }
          return 'unreadable'
        }
        function AlcoveSafe($value) { if ($value -is [string] -and $value -match '^[A-Za-z0-9+/=]*\z') { return $value }; return $null }
        function AlcoveKindText($name) { foreach ($known in 'String', 'ExpandString', 'DWord') { if ($name -ceq $known) { return $known } }; return $null }

        """#

    /// The lines that end a recipe with `unreadableProxyState` when `$state` is the text `unreadable`.
    private static let refuseUnreadableState = "  if ($state -is [string]) { [Console]::Error.WriteLine('\(unreadableProxyState)'); exit 2 }\n"

    /// `AlcoveBlobText`: the bytes of a registry value as Latin-1 text without NUL characters.
    /// `AlcovePort`: the port of a `10.0.2.2:<port>` that stands in a text as a whole address, with no name, address
    /// or proxy list around it (no letter, digit, `.`, `;`, `:`, `-`, space or comma right next to it, nor `=` or `/`
    /// right before it); 0 when the text holds none.
    private static let proxyAddressReader = #"""
        function AlcoveBlobText($raw) {
          if ($raw -isnot [byte[]]) { return '' }
          return [System.Text.Encoding]::GetEncoding(28591).GetString($raw).Replace([string][char]0, '')
        }
        function AlcovePort($text) {
          $m = [regex]::Match([string]$text, '(?<![0-9A-Za-z.=;:/ ,-])10\.0\.2\.2:([0-9]{1,5})(?![0-9A-Za-z.;: ,-])')
          if ($m.Success) { return [int]$m.Groups[1].Value }
          return 0
        }

        """#

    /// `AlcoveRefresh`: tells WinINET that the proxy settings changed; true when both calls succeeded.
    private static let proxyRefresh = #"""
        function AlcoveRefresh {
          try {
            Add-Type -Namespace Alcove -Name Inet -MemberDefinition '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);'
            $changed = [Alcove.Inet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
            $reread = [Alcove.Inet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
            return ($changed -and $reread)
          } catch { return $false }
        }

        """#

    /// Opens the current user's and the machine's registry hive in the 64-bit view as `$hkcu` and `$hklm`.
    private static let openRegistryHives = """
          $hkcu = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
          $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        """

    /// The WinINET values a capture changes: the registry value name and its field in the state file.
    private static let wininetTextValues = [("ProxyServer", "proxyServer"), ("ProxyOverride", "proxyOverride"), ("AutoConfigURL", "autoConfigURL")]

    /// Windows: refuses a state file that cannot be read before anything else, gives the pushed CA file the access list
    /// "Administrators and SYSTEM: full control, Users: read" without inheritance, checks that its certificate has
    /// `thumbprint` (the SHA-1 of the certificate as 40 hexadecimal digits) and adds it to the machine's trusted roots
    /// unless it is there. Prints `{"installed":true,"added":<bool>}`.
    /// Linux: makes the pushed CA file world-readable and runs `update-ca-certificates`. Prints
    /// `{"installed":<bool>,"bundle":"<path>"}`: `installed` is false when the guest has no `update-ca-certificates`;
    /// `bundle` is the system bundle that holds the CA, or the CA file when there is none.
    /// A failure prints one sentence on stderr and exits with 2.
    static func installProxyCA(thumbprint: String, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return windowsPrelude + proxyPaths + proxyCAReader + proxyRootStore + proxyStateReader + "$thumb = \(quote(thumbprint, os: os))\n" + #"""
            $added = $false
            try {
              $state = AlcoveState
            \#(refuseUnreadableState)  if (-not [System.IO.File]::Exists($caPath)) { [Console]::Error.WriteLine('the proxy CA file C:\ProgramData\Alcove\proxy-ca.pem is missing in the guest; call vm.http.start again'); exit 2 }
              $allow = [System.Security.AccessControl.AccessControlType]::Allow
              $acl = New-Object System.Security.AccessControl.FileSecurity
              $acl.SetAccessRuleProtection($true, $false)
              $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), [System.Security.AccessControl.FileSystemRights]::FullControl, $allow))
              $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [System.Security.AccessControl.FileSystemRights]::FullControl, $allow))
              $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), [System.Security.AccessControl.FileSystemRights]::Read, $allow))
              [System.IO.File]::SetAccessControl($caPath, $acl)
              $cert = AlcoveCA
              if ($null -eq $cert -or $cert.Thumbprint -ne $thumb) { [Console]::Error.WriteLine('the proxy CA file in the guest is not the certificate the host sent; call vm.http.start again'); exit 2 }
              $store = AlcoveRoot 'ReadWrite'
              if ($store.Certificates.Find($byThumbprint, $thumb, $false).Count -eq 0) { $store.Add($cert); $added = $true }
              $store.Close()
            } catch {
              [Console]::Error.WriteLine('could not install the proxy CA in the guest: ' + ($_.Exception.GetBaseException().Message -replace '\s+', ' ') + '; check that alcove-agent runs elevated')
              exit 2
            }
            '{"installed":true,"added":' + (AlcoveBool $added) + '}'
            """#
        case .linux:
            return #"""
            ca=\#(linuxProxyCAPath)
            [ -f "$ca" ] || { echo "the proxy CA file $ca is missing in the guest; call vm.http.start again" >&2; exit 2; }
            chmod 644 "$ca" || { echo "could not make $ca readable; check that alcove-agent runs as root" >&2; exit 2; }
            if ! command -v update-ca-certificates >/dev/null 2>&1; then printf '{"installed":false,"bundle":"%s"}\n' "$ca"; exit 0; fi
            update-ca-certificates >/dev/null 2>&1 || { echo "update-ca-certificates failed in the guest; run it with vm.exec to see why" >&2; exit 2; }
            bundle=/etc/ssl/certs/ca-certificates.crt
            [ -f "$bundle" ] || bundle=$ca
            printf '{"installed":true,"bundle":"%s"}\n' "$bundle"
            """#
        case .other:
            return nil
        }
    }

    /// Windows: removes the certificate with `thumbprint` from the machine's trusted roots, or without a thumbprint the
    /// certificate of the CA file, and deletes the CA file. Linux: moves the CA file to `linuxProxyCAAsidePath`, outside
    /// the folder `update-ca-certificates` reads, runs `update-ca-certificates --fresh` when the guest has it, and
    /// deletes the aside file once that worked; an aside file that is there is refreshed and deleted the same way.
    /// Prints `{"removed":<bool>,"fileRemoved":<bool>}`: whether a certificate left the trusted roots and whether the
    /// file was there. A failure prints one sentence on stderr and exits with 2.
    static func removeProxyCA(thumbprint: String?, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return windowsPrelude + proxyPaths + proxyCAReader + proxyRootStore + "$thumb = \(quote(thumbprint ?? "", os: os))\n" + #"""
            $removed = $false
            $fileRemoved = $false
            try {
              if (-not $thumb -and [System.IO.File]::Exists($caPath)) {
                try { $cert = AlcoveCA; if ($cert) { $thumb = $cert.Thumbprint } } catch { }
              }
              if ($thumb) {
                $store = AlcoveRoot 'ReadWrite'
                foreach ($found in @($store.Certificates.Find($byThumbprint, $thumb, $false))) { $store.Remove($found); $removed = $true }
                $store.Close()
              }
              if ([System.IO.File]::Exists($caPath)) { [System.IO.File]::Delete($caPath); $fileRemoved = $true }
            } catch {
              [Console]::Error.WriteLine('could not remove the proxy CA from the guest: ' + ($_.Exception.GetBaseException().Message -replace '\s+', ' ') + '; check that alcove-agent runs elevated, then call vm.http.stop again')
              exit 2
            }
            '{"removed":' + (AlcoveBool $removed) + ',"fileRemoved":' + (AlcoveBool $fileRemoved) + '}'
            """#
        case .linux:
            return #"""
            ca=\#(linuxProxyCAPath)
            gone=\#(linuxProxyCAAsidePath)
            if [ -e "$ca" ]; then mv -f "$ca" "$gone" || { echo "could not move $ca aside; check that alcove-agent runs as root, then call vm.http.stop again" >&2; exit 2; }; fi
            [ -e "$gone" ] || { printf '{"removed":false,"fileRemoved":false}\n'; exit 0; }
            if command -v update-ca-certificates >/dev/null 2>&1; then
              update-ca-certificates --fresh >/dev/null 2>&1 || { echo "update-ca-certificates --fresh failed in the guest, so the guest still trusts the proxy CA; run it with vm.exec to see why, then call vm.http.stop again" >&2; exit 2; }
            fi
            rm -f "$gone" || { echo "could not delete $gone; check that alcove-agent runs as root, then call vm.http.stop again" >&2; exit 2; }
            printf '{"removed":true,"fileRemoved":true}\n'
            """#
        case .other:
            return nil
        }
    }

    /// `AlcoveKindName`: the kind of a registry value as `String`, `ExpandString` or `DWord`; nothing when the value is absent.
    /// `AlcoveWriteState`: writes the state file through `<state file>.new` in the same folder, which then replaces it.
    private static let proxyStateWriter = #"""
        function AlcoveKindName($key, $name) {
          if ($null -eq $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) { return $null }
          $kind = $key.GetValueKind($name)
          if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) { return 'ExpandString' }
          if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { return 'DWord' }
          return 'String'
        }
        function AlcoveWriteState($json) {
          $new = $statePath + '.new'
          [System.IO.File]::WriteAllText($new, $json)
          if ([System.IO.File]::Exists($statePath)) { [System.IO.File]::Replace($new, $statePath, [NullString]::Value) } else { [System.IO.File]::Move($new, $statePath) }
        }

        """#

    /// `AlcoveRestoreText`: puts a remembered text value back with its remembered kind, or deletes the value when it
    /// is remembered as absent.
    /// `AlcoveRestore`: puts back what the state remembers, where the settings are still the ones its capture set: the
    /// four WinINET values when `ProxyServer` is exactly `10.0.2.2:<port of the state>`, `ProxyServer` last, and the raw
    /// `WinHttpSettings` value when it holds exactly that address. Returns whether a value was put back.
    private static let proxyStateRestorer = #"""
        function AlcoveRestoreText($key, $name, $stored, $kindName) {
          if ($null -eq $stored) { $key.DeleteValue($name, $false); return }
          $kind = [Microsoft.Win32.RegistryValueKind]::String
          if ((AlcoveKindText $kindName) -ceq 'ExpandString') { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
          $key.SetValue($name, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stored)), $kind)
        }
        function AlcoveRestore($state, $hkcu, $hklm) {
          $restored = $false
          $key = $hkcu.CreateSubKey($inet)
          $serverNow = $key.GetValue('ProxyServer', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          if (($serverNow -is [string]) -and ($serverNow -ceq ('10.0.2.2:' + [int]$state.port))) {
            if ($null -eq $state.proxyEnable) { $key.DeleteValue('ProxyEnable', $false) } elseif ((AlcoveKindText $state.proxyEnableKind) -ceq 'String') { $key.SetValue('ProxyEnable', [string][int]$state.proxyEnable, [Microsoft.Win32.RegistryValueKind]::String) } else { $key.SetValue('ProxyEnable', [int]$state.proxyEnable, [Microsoft.Win32.RegistryValueKind]::DWord) }
            AlcoveRestoreText $key 'ProxyOverride' (AlcoveSafe $state.proxyOverride) $state.proxyOverrideKind
            AlcoveRestoreText $key 'AutoConfigURL' (AlcoveSafe $state.autoConfigURL) $state.autoConfigURLKind
            AlcoveRestoreText $key 'ProxyServer' (AlcoveSafe $state.proxyServer) $state.proxyServerKind
            $restored = $true
          }
          $key.Close()
          $ck = $hklm.OpenSubKey($conn, $true)
          if ($ck) {
            if ((AlcovePort (AlcoveBlobText ($ck.GetValue('WinHttpSettings')))) -eq [int]$state.port) {
              $blob = AlcoveSafe $state.winhttp
              if ($null -eq $blob) { $ck.DeleteValue('WinHttpSettings', $false) } else { [byte[]]$raw = [Convert]::FromBase64String($blob); $ck.SetValue('WinHttpSettings', $raw, [Microsoft.Win32.RegistryValueKind]::Binary) }
              $restored = $true
            }
            $ck.Close()
          }
          return $restored
        }

        """#

    /// Windows only. Writes the state file: `port`, `thumbprint`, `systemProxy` (the value of `apply`) and the four
    /// WinINET values with their registry kinds and the raw `WinHttpSettings` value from before the capture, each
    /// absent or present; without `apply` these are all null. The certificate of an earlier state file with another
    /// thumbprint leaves the trusted roots.
    ///
    /// With `apply` it then points the per-user WinINET proxy (`ProxyEnable` 1, `ProxyServer`, `ProxyOverride`
    /// `<local>`, no `AutoConfigURL`) and, through `netsh winhttp set proxy`, the WinHTTP proxy at `10.0.2.2:<port>`.
    /// Settings count as set by an earlier capture only when its state file says `systemProxy` and they are exactly
    /// `10.0.2.2:<port of that file>`: then the values that file remembers are kept. Any other settings, with or
    /// without a state file, are remembered as they are.
    ///
    /// Without `apply` it first puts back what an earlier state file with `systemProxy` remembers, as
    /// `clearSystemProxy` does.
    ///
    /// Prints `{"set":<apply>,"keptPrevious":<bool>,"restored":<bool>,"winhttp":<bool>,"refreshed":<bool>}`:
    /// `restored` tells whether a value of an earlier capture was put back, `winhttp` is false when netsh failed or
    /// was not run, `refreshed` is false when WinINET was not told about a change.
    /// A failure prints one sentence on stderr and exits with 2; an unreadable state file is left as it is.
    static func setSystemProxy(port: Int, thumbprint: String, apply: Bool, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        let remembered = wininetTextValues.map { "      $\($0.1) = AlcoveSafe $state.\($0.1)\n      $\($0.1)Kind = $state.\($0.1)Kind\n" }.joined()
        let current = wininetTextValues.map {
            "      $\($0.1) = AlcoveText ($key.GetValue('\($0.0)', $null, $asStored))\n      $\($0.1)Kind = AlcoveKindName $key '\($0.0)'\n"
        }.joined()
        let none = wininetTextValues.map { "$\($0.1) = $null; $\($0.1)Kind = $null; " }.joined()
        let fields = wininetTextValues.map {
            " + ',\"\($0.1)\":' + (AlcoveField $\($0.1)) + ',\"\($0.1)Kind\":' + (AlcoveField (AlcoveKindText $\($0.1)Kind))"
        }.joined()
        return windowsPrelude + proxyPaths + proxyRootStore + proxyStateReader + proxyAddressReader + proxyStateWriter + proxyStateRestorer
            + proxyRefresh + "$server = '\(proxyHost):\(port)'\n$thumb = \(quote(thumbprint, os: os))\n$apply = $\(apply)\n" + #"""
            function AlcoveText($value) { if ($null -eq $value) { return $null }; return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$value)) }
            function AlcoveField($value) { if ($null -eq $value) { return 'null' }; return '"' + $value + '"' }
            $kept = $false
            $restored = $false
            $winhttp = $false
            $refreshed = $false
            try {
            \#(openRegistryHives)
              $state = AlcoveState
            \#(refuseUnreadableState)  if ($state) {
                $old = [string]$state.thumbprint
                if ($old -ne $thumb) {
                  $store = AlcoveRoot 'ReadWrite'
                  foreach ($found in @($store.Certificates.Find($byThumbprint, $old, $false))) { $store.Remove($found) }
                  $store.Close()
                }
              }
              $enable = $null; $enableKind = $null; \#(none)$blob = $null
              if ($apply) {
                $key = $hkcu.CreateSubKey($inet)
                $asStored = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                $raw = $null
                $ck = $hklm.OpenSubKey($conn)
                if ($ck) { $raw = $ck.GetValue('WinHttpSettings'); $ck.Close() }
                $inetOurs = $false
                $httpOurs = $false
                if ($state -and $state.systemProxy) {
                  $serverNow = $key.GetValue('ProxyServer', $null, $asStored)
                  $inetOurs = ($serverNow -is [string]) -and ($serverNow -ceq ('10.0.2.2:' + [int]$state.port))
                  $httpOurs = (AlcovePort (AlcoveBlobText $raw)) -eq [int]$state.port
                }
                if ($inetOurs) {
                  $kept = $true
                  $enable = $state.proxyEnable
                  $enableKind = $state.proxyEnableKind
            \#(remembered)    } else {
                  $enable = $key.GetValue('ProxyEnable')
                  $enableKind = AlcoveKindName $key 'ProxyEnable'
            \#(current)    }
                if ($httpOurs) {
                  $kept = $true
                  $blob = AlcoveSafe $state.winhttp
                } elseif ($raw -is [byte[]]) {
                  $blob = [Convert]::ToBase64String($raw)
                }
              } elseif ($state -and $state.systemProxy) {
                $restored = AlcoveRestore $state $hkcu $hklm
              }
              $enableText = 'null'
              if ($null -ne $enable) { try { $enableText = [string][int]$enable } catch { $enableText = '0' } }
              $json = '{"version":1,"thumbprint":"' + $thumb + '","port":\#(port),"systemProxy":' + (AlcoveBool $apply) + ',"proxyEnable":' + $enableText + ',"proxyEnableKind":' + (AlcoveField (AlcoveKindText $enableKind))\#(fields) + ',"winhttp":' + (AlcoveField $blob) + '}'
              AlcoveWriteState $json
              if ($apply) {
                $key.SetValue('ProxyServer', $server, [Microsoft.Win32.RegistryValueKind]::String)
                $key.SetValue('ProxyOverride', '<local>', [Microsoft.Win32.RegistryValueKind]::String)
                $key.DeleteValue('AutoConfigURL', $false)
                $key.SetValue('ProxyEnable', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                $key.Close()
                $netsh = $env:SystemRoot + '\System32\netsh.exe'
                $ErrorActionPreference = 'Continue'
                $null = & $netsh winhttp set proxy ('proxy-server=' + $server) 'bypass-list=<local>' 2>&1
                $ErrorActionPreference = 'Stop'
                $winhttp = $LASTEXITCODE -eq 0
                $refreshed = AlcoveRefresh
              } elseif ($restored) {
                $refreshed = AlcoveRefresh
              }
            } catch {
              [Console]::Error.WriteLine('could not set the system proxy of the guest: ' + ($_.Exception.GetBaseException().Message -replace '\s+', ' ') + '; check that alcove-agent runs elevated, or call vm.http.start with systemProxy false')
              exit 2
            }
            '{"set":' + (AlcoveBool $apply) + ',"keptPrevious":' + (AlcoveBool $kept) + ',"restored":' + (AlcoveBool $restored) + ',"winhttp":' + (AlcoveBool $winhttp) + ',"refreshed":' + (AlcoveBool $refreshed) + '}'
            """#
    }

    /// Windows only: puts back what the state file remembers and deletes the file and a `<state file>.new` left by a
    /// write that did not finish. With `systemProxy` in the state file, the WinINET values come back, with their kinds,
    /// when `ProxyServer` is still exactly `10.0.2.2:<port of the state file>`, and the raw `WinHttpSettings` value
    /// when it still holds exactly that address; a value remembered as absent is deleted. Settings that are anything
    /// else stay as they are, and without a state file nothing is changed.
    /// Prints `{"state":<bool>,"restored":<bool>,"thumbprint":"<of the state file, or empty>","refreshed":<bool>}`:
    /// whether a state file was there, whether a registry value was put back, and whether WinINET was told.
    /// A failure prints one sentence on stderr and exits with 2; an unreadable state file is left as it is.
    static func clearSystemProxy(os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        return windowsPrelude + proxyPaths + proxyStateReader + proxyAddressReader + proxyStateRestorer + proxyRefresh + #"""
            $had = $false
            $restored = $false
            $refreshed = $false
            $thumb = ''
            try {
            \#(openRegistryHives)
              $state = AlcoveState
            \#(refuseUnreadableState)  if ($state) {
                $had = $true
                $thumb = ([string]$state.thumbprint).ToUpper()
                if ($state.systemProxy) { $restored = AlcoveRestore $state $hkcu $hklm }
                [System.IO.File]::Delete($statePath)
              }
              if ([System.IO.File]::Exists($statePath + '.new')) { [System.IO.File]::Delete($statePath + '.new') }
              if ($restored) { $refreshed = AlcoveRefresh }
            } catch {
              [Console]::Error.WriteLine('could not restore the proxy settings of the guest: ' + ($_.Exception.GetBaseException().Message -replace '\s+', ' ') + '; check that alcove-agent runs elevated, then call vm.http.stop again')
              exit 2
            }
            '{"state":' + (AlcoveBool $had) + ',"restored":' + (AlcoveBool $restored) + ',"thumbprint":"' + $thumb + '","refreshed":' + (AlcoveBool $refreshed) + '}'
            """#
    }

    /// Reads what a capture leaves in the guest without changing it.
    /// Windows prints `{"previous":<bool>,"previousUnreadable":<bool>,"previousPort":<n>,"previousSystemProxy":<bool>,
    /// "caFile":<bool>,"caInStore":<bool>,"wininetEnabled":<bool>,"wininetServer":"<base64 of the UTF-8 text>",
    /// "winhttpPort":<n>}`: whether a readable state file is there, whether one is there that cannot be read, the port
    /// and `systemProxy` of a readable one, whether the CA file is there, whether the certificate of the CA file or
    /// of the state file's thumbprint is among the machine's trusted roots, the per-user WinINET proxy, and the port
    /// of a `10.0.2.2` address that is the whole WinHTTP proxy (0 without one).
    /// Linux prints `{"caFile":<bool>,"caRemoving":<bool>}`: whether the CA file or the aside file of its removal
    /// (`linuxProxyCAAsidePath`) is there, and whether the aside file is.
    /// A failure prints one sentence on stderr and exits with 2.
    static func readSystemProxy(os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return windowsPrelude + proxyPaths + proxyCAReader + proxyRootStore + proxyStateReader + proxyAddressReader + #"""
            $previous = $false
            $unreadable = $false
            $previousPort = 0
            $previousSystem = $false
            $caFile = $false
            $caInStore = $false
            $enabled = $false
            $server = ''
            $winhttpPort = 0
            try {
              $thumbs = @()
              $state = AlcoveState
              if ($state -is [string]) {
                $unreadable = $true
              } elseif ($state) {
                $previous = $true
                $previousPort = [int]$state.port
                $previousSystem = [bool]$state.systemProxy
                $thumbs += [string]$state.thumbprint
              }
              if ([System.IO.File]::Exists($caPath)) {
                $caFile = $true
                try { $cert = AlcoveCA; if ($cert) { $thumbs += $cert.Thumbprint } } catch { }
              }
              if ($thumbs.Count -gt 0) {
                $store = AlcoveRoot 'ReadOnly'
                foreach ($thumb in $thumbs) { if ($store.Certificates.Find($byThumbprint, $thumb, $false).Count -gt 0) { $caInStore = $true } }
                $store.Close()
              }
            \#(openRegistryHives)
              $key = $hkcu.OpenSubKey($inet)
              if ($key) {
                $server = [string]$key.GetValue('ProxyServer', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                try { $enabled = ([int]$key.GetValue('ProxyEnable', 0) -ne 0) -and ($server.Length -gt 0) } catch { }
                $key.Close()
              }
              $ck = $hklm.OpenSubKey($conn)
              if ($ck) {
                $winhttpPort = AlcovePort (AlcoveBlobText ($ck.GetValue('WinHttpSettings')))
                $ck.Close()
              }
            } catch {
              [Console]::Error.WriteLine('could not read the proxy settings of the guest: ' + ($_.Exception.GetBaseException().Message -replace '\s+', ' ') + '; check that alcove-agent runs elevated')
              exit 2
            }
            '{"previous":' + (AlcoveBool $previous) + ',"previousUnreadable":' + (AlcoveBool $unreadable) + ',"previousPort":' + $previousPort + ',"previousSystemProxy":' + (AlcoveBool $previousSystem) + ',"caFile":' + (AlcoveBool $caFile) + ',"caInStore":' + (AlcoveBool $caInStore) + ',"wininetEnabled":' + (AlcoveBool $enabled) + ',"wininetServer":"' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($server)) + '","winhttpPort":' + $winhttpPort + '}'
            """#
        case .linux:
            return #"""
            ca=\#(linuxProxyCAPath)
            gone=\#(linuxProxyCAAsidePath)
            file=false
            removing=false
            if [ -e "$gone" ]; then file=true; removing=true; fi
            if [ -e "$ca" ]; then file=true; fi
            printf '{"caFile":%s,"caRemoving":%s}\n' "$file" "$removing"
            """#
        case .other:
            return nil
        }
    }
}
