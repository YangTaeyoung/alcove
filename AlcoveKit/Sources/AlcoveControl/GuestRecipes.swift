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
            return "command -v ss >/dev/null 2>&1 || { echo \"ss is not installed in the guest\" >&2; exit 127; }\n"
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
}
