import Foundation
import AlcoveEngine

/// Scripts the host sends through the guest agent's `exec.run` to change guest settings and to probe guest health.
/// PowerShell scripts serve Windows guests, `sh` scripts Linux guests; a setting without a script for an OS returns nil.
enum GuestRecipes {
    /// The scaling percentages Windows offers, in order of the relative steps `SPI_SETLOGICALDPIOVERRIDE` takes (100 % is step 0).
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

    /// Prints `1` when the guest has a TCP listener on `port`, `0` otherwise.
    static func portListening(_ port: Int, os: VMConfig.GuestOS) -> String? {
        switch os {
        case .windows:
            return "if (Get-NetTCPConnection -State Listen -LocalPort \(port) -ErrorAction SilentlyContinue) { '1' } else { '0' }"
        case .linux:
            return "ss -ltn \"sport = :\(port)\" | tail -n +2 | grep -q . && echo 1 || echo 0"
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

    /// Writes the per-monitor scaling step for the percentage nearest to `percent`; Windows applies it at the next sign-in.
    static func setDPIScale(percent: Int, os: VMConfig.GuestOS) -> String? {
        guard os == .windows else { return nil }
        let step = dpiSteps.indices.min { abs(dpiSteps[$0] - percent) < abs(dpiSteps[$1] - percent) } ?? 0
        return windowsPrelude + """
        Add-Type -Namespace Alcove -Name Dpi -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, int param, IntPtr pvParam, uint flags);'
        if (-not [Alcove.Dpi]::SystemParametersInfo(0x009F, \(step), [IntPtr]::Zero, 3)) { throw 'SystemParametersInfo failed' }
        'scale: \(dpiSteps[step]) %, applied at the next sign-in'
        """
    }

    /// Prints one JSON object: `user`, `freeBytes`, `utc`, `dns` and, where the guest can tell, `locked` and `scale`.
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
            $applied = (Get-ItemProperty -Path 'HKCU:\\Control Panel\\Desktop\\WindowMetrics' -Name AppliedDPI).AppliedDPI
            if ($applied) { $o.scale = [int]($applied * 100 / 96) }
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
