<#
Check-Tether.ps1 - find the Android USB tethering adapter and report whether
this PC is actually sending its internet traffic through the phone.

  Check only (no admin needed):
    powershell -ExecutionPolicy Bypass -File .\Check-Tether.ps1

  Make the phone the preferred route while Wi-Fi stays connected (needs an
  elevated / "Run as administrator" PowerShell):
    powershell -ExecutionPolicy Bypass -File .\Check-Tether.ps1 -PreferTether

  Keep Wi-Fi as the main route but leave the phone link up for testing (elevated):
    powershell -ExecutionPolicy Bypass -File .\Check-Tether.ps1 -PreferWifi

  Undo either (back to Windows automatic metric):
    powershell -ExecutionPolicy Bypass -File .\Check-Tether.ps1 -ResetMetric
#>
param(
    [switch]$PreferTether,
    [switch]$PreferWifi,
    [switch]$ResetMetric
)

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A USB-tethered phone shows up as a USB-attached network adapter
# (usually "Remote NDIS Compatible Device" or a UsbNcm adapter).
$tether = @(Get-NetAdapter | Where-Object {
    $_.PnPDeviceID -like 'USB\*' -or
    $_.InterfaceDescription -match 'Remote NDIS|RNDIS|UsbNcm|NCM|Android'
})

if ($tether.Count -eq 0) {
    Write-Host "NO TETHER ADAPTER FOUND." -ForegroundColor Red
    Write-Host "Windows does not see a USB network adapter. Check, in order:"
    Write-Host "  1. Phone is unlocked and plugged in with a DATA cable (not charge-only)."
    Write-Host "  2. USB tethering is switched ON on the phone (it turns off on every unplug)."
    Write-Host "  3. Try another USB port, directly on the PC (no hub)."
    $wpd = Get-PnpDevice -PresentOnly -Class WPD -ErrorAction SilentlyContinue
    if ($wpd) {
        Write-Host ""
        Write-Host "The phone IS visible as a storage/media device:" -ForegroundColor Yellow
        $wpd | ForEach-Object { Write-Host "    $($_.FriendlyName)" }
        Write-Host "  -> cable is fine; USB tethering is just not switched on."
    }
    $bad = Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -like 'USB\*' }
    if ($bad) {
        Write-Host ""
        Write-Host "USB devices with driver problems:" -ForegroundColor Yellow
        $bad | Format-Table Class, FriendlyName, Status, InstanceId -AutoSize
    }
    exit 1
}

$exit = 0
foreach ($a in $tether) {
    Write-Host ""
    Write-Host "Tether adapter: $($a.Name)  [$($a.InterfaceDescription)]" -ForegroundColor Cyan
    Write-Host "  Status: $($a.Status)   Link speed: $($a.LinkSpeed)"
    if ($a.Status -ne 'Up') {
        Write-Host "  Adapter is not Up - toggle USB tethering off/on on the phone." -ForegroundColor Red
        $exit = 1
        continue
    }

    if ($ResetMetric -or $PreferTether -or $PreferWifi) {
        if (-not (Test-IsAdmin)) {
            Write-Host "  -PreferTether / -ResetMetric need an elevated PowerShell. Skipping." -ForegroundColor Red
            $exit = 1
        } elseif ($ResetMetric) {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AutomaticMetric Enabled
            Write-Host "  Metric reset to automatic." -ForegroundColor Green
        } elseif ($PreferWifi) {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AutomaticMetric Disabled -InterfaceMetric 1000
            Write-Host "  Interface metric set to 1000 (Wi-Fi preferred; phone link stays up for testing)." -ForegroundColor Green
        } else {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AutomaticMetric Disabled -InterfaceMetric 5
            Write-Host "  Interface metric set to 5 (phone preferred over Wi-Fi)." -ForegroundColor Green
        }
    }

    $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $ip) {
        Write-Host "  No IPv4 address from the phone yet (DHCP). Wait 10s and re-run, or toggle tethering." -ForegroundColor Red
        $exit = 1
        continue
    }
    Write-Host "  PC address on phone link: $($ip.IPAddress)"

    # Does traffic forced out of the phone link reach the internet?
    $out = & curl.exe -s -m 10 --interface $ip.IPAddress http://www.msftconnecttest.com/connecttest.txt 2>$null
    if ($out -match 'Microsoft Connect Test') {
        Write-Host "  Internet through the phone: WORKING" -ForegroundColor Green
        $pub = & curl.exe -s -m 10 --interface $ip.IPAddress https://api.ipify.org 2>$null
        if ($pub) { Write-Host "  Public IP via phone: $pub" }
    } else {
        Write-Host "  Internet through the phone: FAILED" -ForegroundColor Red
        Write-Host "    Link is up but no data flows. Check mobile data is on, and that the"
        Write-Host "    mobile plan includes hotspot/tethering data."
        $exit = 1
    }
}

Write-Host ""
Write-Host "Default routes (lowest total metric wins):" -ForegroundColor Cyan
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NextHop,
        @{n='TotalMetric'; e={ $_.RouteMetric + $_.InterfaceMetric }} |
    Sort-Object TotalMetric
$routes | Format-Table -AutoSize

$winner = $routes | Select-Object -First 1
if ($winner -and ($tether.Name -contains $winner.InterfaceAlias)) {
    Write-Host "RESULT: this PC's internet traffic is going through the PHONE." -ForegroundColor Green
} elseif ($winner) {
    Write-Host "RESULT: traffic is still going through '$($winner.InterfaceAlias)', not the phone." -ForegroundColor Yellow
    Write-Host "  Either disconnect that network (e.g. turn Wi-Fi off), or re-run this"
    Write-Host "  script elevated with -PreferTether."
    if ($exit -eq 0) { $exit = 2 }
}
exit $exit
