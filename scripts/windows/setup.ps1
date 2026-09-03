# Alcove guest setup, run once at first logon from the ALCOVE volume.
# Installs virtio drivers from the virtio-win CD, enables OpenSSH server with
# key auth for the test harness, disables sleep, and writes a ready marker.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\alcove-setup.log' -Append

$self = (Get-Volume | Where-Object FileSystemLabel -eq 'ALCOVE' | Select-Object -First 1).DriveLetter
$vio  = (Get-Volume | Where-Object { $_.FileSystemLabel -like 'virtio-win*' } | Select-Object -First 1).DriveLetter
Write-Output "ALCOVE volume: $self  virtio-win volume: $vio"

if ($vio) {
    foreach ($d in 'NetKVM','viostor','vioscsi','vioserial','viogpudo','vioinput','Balloon','viorng','viofs','pvpanic','viosock','viomem') {
        $inf = "$($vio):\$d\w11\ARM64\*.inf"
        if (Test-Path $inf) {
            Write-Output "installing $d"
            pnputil /add-driver $inf /install | Out-Null
        }
    }
}

# wait for the NAT gateway to become reachable (NetKVM + DHCP)
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    if (Test-Connection -ComputerName 10.0.2.2 -Count 1 -Quiet) { break }
    Start-Sleep -Seconds 5
}
Write-Output "network: $(Test-Connection -ComputerName 10.0.2.2 -Count 1 -Quiet)"

# OpenSSH server (capability download needs internet through the NAT)
for ($i = 0; $i -lt 20; $i++) {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -eq 'Installed') { break }
    try { Add-WindowsCapability -Online -Name $cap.Name | Out-Null } catch { Write-Output "sshd install retry: $_" }
    Start-Sleep -Seconds 30
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
New-NetFirewallRule -Name 'alcove-sshd' -DisplayName 'OpenSSH Server (Alcove)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

$pub = "$($self):\authorized_keys"
if (Test-Path $pub) {
    New-Item -ItemType Directory -Path 'C:\ProgramData\ssh' -Force | Out-Null
    Copy-Item $pub 'C:\ProgramData\ssh\administrators_authorized_keys' -Force
    icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    Restart-Service sshd
}

powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Set-Content -Path 'C:\alcove-ready.txt' -Value (Get-Date -Format o)
Write-Output 'alcove setup complete'
Stop-Transcript
