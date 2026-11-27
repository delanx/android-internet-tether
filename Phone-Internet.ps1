<#
Phone-Internet.ps1 - use the phone's own mobile data on a Windows PC over
a USB cable (not the throttled "hotspot" data).

HOW TO START: double-click  "START Phone Internet.cmd"  in this folder.
A menu appears. No command-line options are needed.

What it does: the phone runs the "Every Proxy" app. This script finds the
phone on the USB link, starts a small local relay (127.0.0.1) that forwards
to the phone, and points Windows' proxy setting at it. Menu option 2 undoes
everything. No admin rights, no installs, no internet needed to run it.
#>
param(
    [string]$Action,        # internal/testing: On, Off, Status, Test
    [switch]$RunRelay,      # internal: run the relay in the foreground
    [int]$RelayPort = 0     # internal
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$PhonePort = 8080                                   # Every Proxy default
$WorkDir   = Join-Path $env:LOCALAPPDATA 'PhoneInternet'
$StateFile = Join-Path $WorkDir 'state.json'
$LocalCopy = Join-Path $WorkDir 'Phone-Internet.ps1'
$RegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$EnvNames  = 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY'
$AdapterRx = 'Remote NDIS|RNDIS|UsbNcm|NCM|Internet Sharing|Tether'
# USB vendor IDs of common Android phone makers, to tell "phone seen,
# tethering off" from "phone not seen at all".
$PhoneVidRx = '^USB\\VID_(04E8|18D1|22B8|2717|2A70|0BB4|12D1|0FCE|1004)'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

public static class PhoneRelay
{
    public static int PhonePort = 8080;
    public static string AdapterRx = "Remote NDIS|RNDIS";
    public static string AuthHeader = null;      // "Basic xxxx" or null

    // Addresses of the phone on the USB tether link, IPv6 link-local first.
    public static IPAddress[] FindTargets()
    {
        var list = new List<IPAddress>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (!Regex.IsMatch(ni.Description, AdapterRx, RegexOptions.IgnoreCase)) continue;
            var props = ni.GetIPProperties();
            long idx = -1;
            try { idx = props.GetIPv6Properties().Index; } catch { }
            foreach (var g in props.GatewayAddresses)
            {
                var a = g.Address;
                if (a.AddressFamily == AddressFamily.InterNetworkV6)
                {
                    if (a.IsIPv6LinkLocal && idx >= 0) a = new IPAddress(a.GetAddressBytes(), idx);
                    list.Insert(0, a);
                }
                else list.Add(a);
            }
        }
        return list.ToArray();
    }

    // Returns the first phone address whose proxy port accepts a connection.
    public static string Probe()
    {
        foreach (var a in FindTargets())
        {
            var c = new TcpClient(a.AddressFamily);
            try
            {
                var t = c.ConnectAsync(a, PhonePort);
                if (t.Wait(2500) && c.Connected) { c.Close(); return a.ToString(); }
            }
            catch { }
            try { c.Close(); } catch { }
        }
        return null;
    }

    static async Task<TcpClient> ConnectUp()
    {
        foreach (var a in FindTargets())
        {
            var c = new TcpClient(a.AddressFamily);
            try
            {
                var t = c.ConnectAsync(a, PhonePort);
                if (await Task.WhenAny(t, Task.Delay(3000)) == t && c.Connected) { c.NoDelay = true; return c; }
            }
            catch { }
            try { c.Close(); } catch { }
        }
        return null;
    }

    static async Task Handle(TcpClient client)
    {
        TcpClient up = null;
        try
        {
            up = await ConnectUp();
            if (up == null) return;
            var cs = client.GetStream();
            var us = up.GetStream();
            if (AuthHeader != null)
            {
                // Add the phone proxy's username/password to the request.
                var buf = new byte[65536];
                int len = 0, end = -1;
                while (len < buf.Length && end < 0)
                {
                    int n = await cs.ReadAsync(buf, len, buf.Length - len);
                    if (n <= 0) return;
                    len += n;
                    for (int i = 0; i + 3 < len; i++)
                        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) { end = i; break; }
                }
                if (end < 0) return;
                var enc = System.Text.Encoding.GetEncoding(28591);
                var lines = enc.GetString(buf, 0, end).Split(new string[] { "\r\n" }, StringSplitOptions.None);
                bool isConnect = lines[0].StartsWith("CONNECT ", StringComparison.OrdinalIgnoreCase);
                var sb = new System.Text.StringBuilder();
                sb.Append(lines[0]).Append("\r\n");
                for (int i = 1; i < lines.Length; i++)
                {
                    var low = lines[i].ToLowerInvariant();
                    if (low.StartsWith("proxy-authorization:")) continue;
                    // Plain (non-HTTPS) requests: one request per connection,
                    // so every request carries the login.
                    if (!isConnect && (low.StartsWith("connection:") || low.StartsWith("proxy-connection:"))) continue;
                    sb.Append(lines[i]).Append("\r\n");
                }
                sb.Append("Proxy-Authorization: ").Append(AuthHeader).Append("\r\n");
                if (!isConnect) sb.Append("Connection: close\r\nProxy-Connection: close\r\n");
                sb.Append("\r\n");
                var hb = enc.GetBytes(sb.ToString());
                await us.WriteAsync(hb, 0, hb.Length);
                if (len > end + 4) await us.WriteAsync(buf, end + 4, len - end - 4);
            }
            var t1 = cs.CopyToAsync(us, 81920);
            var t2 = us.CopyToAsync(cs, 81920);
            await Task.WhenAny(t1, t2);
        }
        catch { }
        finally
        {
            try { client.Close(); } catch { }
            if (up != null) { try { up.Close(); } catch { } }
        }
    }

    // Starts listening (throws if the port is taken) and serves in the background.
    public static void Start(int listenPort)
    {
        var l = new TcpListener(IPAddress.Loopback, listenPort);
        l.Start();
        var th = new System.Threading.Thread(delegate ()
        {
            while (true)
            {
                try
                {
                    var c = l.AcceptTcpClient();
                    c.NoDelay = true;
                    var ignored = Handle(c);
                }
                catch { }
            }
        });
        th.IsBackground = true;
        th.Start();
    }
}

public static class WinInetRefresh
{
    [DllImport("wininet.dll", SetLastError = true)]
    static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
    public static void Notify()
    {
        InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);
        InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
    }
}
'@

[PhoneRelay]::PhonePort = $PhonePort
[PhoneRelay]::AdapterRx = $AdapterRx

$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName   = 'PhoneInternetCleanup'
$AutoOffNote = Join-Path $WorkDir 'auto-off.txt'

# Username/password for the Every Proxy app (optional). Kept in a small text
# file next to this script so it travels with the folder to other PCs, with
# a copy on the local disk for the background relay.
$LoginName  = 'proxy-login.txt'
$LoginHere  = Join-Path $PSScriptRoot $LoginName
$LoginLocal = Join-Path $WorkDir $LoginName

function Read-Login {
    foreach ($f in $LoginHere, $LoginLocal) {
        if ($f -and (Test-Path $f)) {
            $u = $null; $p = $null
            foreach ($line in Get-Content $f) {
                if ($line -match '^\s*username\s*=(.*)$') { $u = $Matches[1].Trim() }
                if ($line -match '^\s*password\s*=(.*)$') { $p = $Matches[1].Trim() }
            }
            if ($u) { return @{ User = $u; Pass = "$p" } }
        }
    }
    return $null
}

function Save-Login($user, $pass) {
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    foreach ($f in $LoginHere, $LoginLocal) {
        try {
            if ($user) {
                Set-Content $f @(
                    '# Username and password set in the Every Proxy app on the phone.',
                    '# Change them with option 5 of the Phone Internet menu.',
                    "username=$user", "password=$pass") -ErrorAction Stop
            } else { Remove-Item $f -ErrorAction SilentlyContinue }
        } catch { }
    }
}

function Use-Login {
    $l = Read-Login
    if ($l) {
        $raw = [Text.Encoding]::UTF8.GetBytes("$($l.User):$($l.Pass)")
        [PhoneRelay]::AuthHeader = 'Basic ' + [Convert]::ToBase64String($raw)
    } else { [PhoneRelay]::AuthHeader = $null }
}

# ---------------------------------------------------------------- helpers

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Good($t) { Say "  [ OK ] $t" Green }
function Bad($t)  { Say "  [FAIL] $t" Red }
function Info($t) { Say "         $t" Gray }

function Show-PhoneSteps {
    Say ''
    Say '  PHONE SETTINGS (Android)' Cyan
    Say '  ------------------------' Cyan
    Say '  NEEDED ONCE, while the phone still has internet: install the' Yellow
    Say '  "Every Proxy" app from the Play Store. (Any other Android app' Yellow
    Say '  that runs an HTTP proxy server on port 8080 also works.)' Yellow
    Say ''
    Say '  Plug the unlocked phone into this PC with a USB cable, then do' White
    Say '  these TWO things on the phone:' White
    Say ''
    Say '  1. Turn ON USB tethering:' White
    Say '       Settings > Network & internet > Hotspot & tethering >'
    Say '       USB tethering'
    Say '       (Menu names differ between phone makers; searching'
    Say '       Settings for "USB tethering" finds it.)'
    Say '     (It switches itself OFF every time the cable is unplugged, so'
    Say '     redo this after each re-plug.)'
    Say ''
    Say '  2. Open the "Every Proxy" app and turn ON "HTTP Proxy"' White
    Say '     (SERVER tab; it must show Port: 8080).'
    Say ''
    Say '  Then choose option 1 in this menu. That is normally all.' Green
    Say ''
    Say '  IF IT DOES NOT WORK, check these on the phone:' Yellow
    Say '   - VPN: disconnect any VPN app on the phone. With a VPN connected'
    Say '     the phone can silently refuse connections from the PC.'
    Say '   - Wi-Fi OFF, Mobile data ON, Airplane mode OFF, so the phone'
    Say '     uses its mobile data.'
    Say '   - USB tethering greyed out: the cable only charges. Use another'
    Say '     cable, and a USB port directly on the PC (not a hub or dock).'
    Say '   - Every Proxy: use the SERVER tab only, leave the CLIENT tab'
    Say '     off. If a banner says "Action required", tap Fix and allow'
    Say '     it, so Android does not stop the app in the background.'
    Say '   - Username/password: if authentication is switched on in Every'
    Say '     Proxy (pencil icon next to "HTTP Proxy"), the same username'
    Say '     and password must be saved on this PC with menu option 5.'
    Say ''
}

function Read-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Get-RelayProcess($state) {
    if (-not $state -or -not $state.RelayPid) { return $null }
    $p = Get-Process -Id ([int]$state.RelayPid) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like 'powershell*') { return $p }
    return $null
}

function Test-PortListening([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $ok = $c.ConnectAsync('127.0.0.1', $port).Wait(700) -and $c.Connected } catch { $ok = $false }
    $c.Close()
    return $ok
}

function Get-FreePort {
    foreach ($p in 8787..8799) {
        try {
            $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $p
            $l.Start(); $l.Stop(); return $p
        } catch { }
    }
    return 0
}

function Test-InternetVia([int]$port) {
    $proxy = "http://127.0.0.1:$port"
    foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt',
                   'https://www.google.com/generate_204',
                   'https://www.cloudflare.com/cdn-cgi/trace') {
        try {
            $r = Invoke-WebRequest $u -Proxy $proxy -UseBasicParsing -TimeoutSec 10
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
        } catch { }
    }
    return $false
}

# $true when the phone's proxy answers "407 - username/password required".
function Test-LoginRejected([int]$port) {
    try {
        $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Proxy = New-Object Net.WebProxy("http://127.0.0.1:$port")
        $req.Timeout = 8000
        $req.GetResponse().Close()
    } catch [Net.WebException] {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 407) { return $true }
    } catch { }
    return $false
}

function Show-LoginFix {
    Bad 'The phone''s proxy rejected the username/password.'
    if (Read-Login) {
        Info 'A username/password is saved on this PC, but it does not match'
        Info 'the one set in the Every Proxy app.'
    } else {
        Info 'The Every Proxy app asks for a username/password, but none is'
        Info 'saved on this PC.'
    }
    Info 'FIX: go back to the menu (type M) and choose option 5 to type the'
    Info '     same username and password that are set in Every Proxy'
    Info '     (pencil icon next to "HTTP Proxy" on the phone).'
}

function Measure-SpeedVia([int]$port) {
    try {
        $req = [Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__down?bytes=50000000')
        $req.Proxy = New-Object Net.WebProxy("http://127.0.0.1:$port")
        $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
        $resp = $req.GetResponse(); $s = $resp.GetResponseStream()
        $buf = New-Object byte[] 262144; $total = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 8) {
            $n = $s.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
        }
        $sw.Stop(); $resp.Close()
        if ($total -gt 0) { return [math]::Round($total * 8 / 1e6 / $sw.Elapsed.TotalSeconds, 1) }
    } catch { }
    return $null
}

function Stop-Relay($state) {
    $p = Get-RelayProcess $state
    if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

function Start-Relay {
    # Run the relay from a copy on the local disk, so it keeps working even
    # if this folder is on a cloud/network drive that goes offline.
    $port = Get-FreePort
    if ($port -eq 0) { return $null }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    $src = $PSCommandPath
    $run = $src
    try {
        if ((Resolve-Path $src).Path -ne $LocalCopy) { Copy-Item $src $LocalCopy -Force }
        $run = $LocalCopy
    } catch { $run = $src }
    try {
        if ((Test-Path $LoginHere) -and $LoginHere -ne $LoginLocal) { Copy-Item $LoginHere $LoginLocal -Force }
    } catch { }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$run`"", '-RunRelay', '-RelayPort', $port)
    foreach ($i in 1..40) {                       # up to ~20 s on a slow PC
        if (Test-PortListening $port) { return @{ Pid = $p.Id; Port = $port } }
        if ($p.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    return $null
}

function Set-WindowsProxy([int]$port) {
    Set-ItemProperty $RegPath ProxyServer "127.0.0.1:$port"
    Set-ItemProperty $RegPath ProxyOverride 'localhost;127.*;10.*;192.168.*;<local>'
    Set-ItemProperty $RegPath ProxyEnable 1 -Type DWord
    [WinInetRefresh]::Notify()
    $url = "http://127.0.0.1:$port"
    [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $url, 'User')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $url, 'User')
    [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,::1', 'User')
}

function Restore-WindowsProxy($state) {
    $prev = $null
    if ($state) { $prev = $state.Previous }
    if ($prev) {
        if ($null -ne $prev.ProxyServer) { Set-ItemProperty $RegPath ProxyServer $prev.ProxyServer }
        else { Remove-ItemProperty $RegPath ProxyServer -ErrorAction SilentlyContinue }
        if ($null -ne $prev.ProxyOverride) { Set-ItemProperty $RegPath ProxyOverride $prev.ProxyOverride }
        else { Remove-ItemProperty $RegPath ProxyOverride -ErrorAction SilentlyContinue }
        Set-ItemProperty $RegPath ProxyEnable ([int]$prev.ProxyEnable) -Type DWord
        foreach ($n in $EnvNames) { [Environment]::SetEnvironmentVariable($n, $prev.Env.$n, 'User') }
    } else {
        Set-ItemProperty $RegPath ProxyEnable 0 -Type DWord
        foreach ($n in $EnvNames) {
            $v = [Environment]::GetEnvironmentVariable($n, 'User')
            if ($v -and ($v -match '127\.0\.0\.1:87\d\d' -or $n -eq 'NO_PROXY')) {
                [Environment]::SetEnvironmentVariable($n, $null, 'User')
            }
        }
    }
    [WinInetRefresh]::Notify()
}

function Get-ProxyIsOurs {
    $reg = Get-ItemProperty $RegPath
    return ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -match '^127\.0\.0\.1:87\d\d$')
}

# ------------------------------------------------------------- the checks

# Returns $true when the phone's proxy is reachable over USB. Prints what is
# wrong and exactly what to do on the phone when it is not.
function Test-PhoneLink {
    Say ''
    Say '  Checking the USB link to the phone...' Cyan

    # 1. Does Windows see a USB tethering network adapter?
    $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match $AdapterRx -or $_.PnPDeviceID -like 'USB\*' })
    $up = @($ad | Where-Object Status -eq 'Up')
    if ($up.Count -eq 0) {
        Bad 'Windows does not see the phone as a network connection.'
        $seen = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            $_.Class -eq 'WPD' -or $_.InstanceId -match $PhoneVidRx })
        if ($seen.Count -gt 0) {
            Info 'The PC DOES see the phone on the cable, so the cable is fine.'
            Info 'FIX: on the phone turn ON USB tethering (Settings > Network &'
            Info '     internet > Hotspot & tethering, or search Settings for'
            Info '     "USB tethering").'
            Info '     (It turns itself off whenever the cable is unplugged.)'
        } else {
            Info 'The PC does not see the phone on USB at all.'
            Info 'FIX: 1. Unlock the phone.'
            Info '     2. Use a different USB cable - many cables only charge.'
            Info '     3. Use a USB port directly on the PC, not a hub or dock.'
            Info '     4. Then turn ON USB tethering on the phone.'
        }
        return $false
    }
    Good "USB tethering adapter found: $($up[0].InterfaceDescription)"

    # 2. Has the phone given this PC an address yet?
    $targets = @()
    foreach ($i in 1..10) {
        $targets = @([PhoneRelay]::FindTargets())
        if ($targets.Count -gt 0) { break }
        Start-Sleep 1
    }
    if ($targets.Count -eq 0) {
        Bad 'The adapter is up but the phone has not handed out an address.'
        Info 'FIX: turn USB tethering OFF and ON again on the phone, wait 10'
        Info '     seconds, then try again. If it repeats, unplug and re-plug.'
        return $false
    }
    Good 'Phone address on the USB link found.'

    # 3. Is the proxy app answering?
    $addr = $null
    foreach ($i in 1..3) {
        $addr = [PhoneRelay]::Probe()
        if ($addr) { break }
        Start-Sleep 1
    }
    if (-not $addr) {
        Bad "The phone is connected, but nothing answers on port $PhonePort."
        Info 'FIX (most likely first):'
        Info ' 1. A VPN is connected on the phone. Open the VPN app and'
        Info '    DISCONNECT it. Then wait 15 seconds.'
        Info ' 2. Open the Every Proxy app > SERVER tab > turn ON "HTTP Proxy".'
        Info "    It must say Port: $PhonePort."
        Info ' 3. Android stopped the app: open Every Proxy again, switch'
        Info '    HTTP Proxy off and on. Tap "Fix" on any "Action required"'
        Info '    banner.'
        return $false
    }
    Good "Every Proxy is answering on the phone ($addr)."
    return $true
}

# ------------------------------------------------------------ ON / OFF

function Invoke-On {
    $state = Read-State
    if ($state -and (Get-RelayProcess $state) -and (Get-ProxyIsOurs)) {
        Say ''
        Say '  Phone internet is already ON. Re-checking it...' Cyan
        if (Test-PhoneLink) {
            if (Test-InternetVia $state.Port) { Good 'Internet through the phone is working.'; return $true }
            Bad 'The phone answers but has no internet. See option 4 for phone steps.'
        }
        return $false
    }
    if ($state -or (Get-ProxyIsOurs)) { Invoke-Off -Quiet }

    if (-not (Test-PhoneLink)) { return $false }

    $relay = Start-Relay
    if (-not $relay) {
        Bad 'Could not start the local relay on this PC.'
        Info 'FIX: close this window, start it again and retry. If it still'
        Info '     fails, restart the PC. (Security software blocking'
        Info '     PowerShell can also cause this.)'
        return $false
    }

    # 4. Does the phone actually have internet?
    if (-not (Test-InternetVia $relay.Port)) {
        $rejected = Test-LoginRejected $relay.Port
        Stop-Process -Id $relay.Pid -Force -ErrorAction SilentlyContinue
        if ($rejected) { Show-LoginFix; Info 'Nothing was changed on this PC.'; return $false }
        Bad 'The proxy app answers, but the phone itself has no internet.'
        Info 'FIX: on the phone check Mobile data is ON, Airplane mode is OFF,'
        Info '     and there is signal. Open a web page in the phone''s own'
        Info '     browser - if that fails, the phone has no service here.'
        Info 'Nothing was changed on this PC.'
        return $false
    }
    Good 'Internet through the phone is working.'

    $reg = Get-ItemProperty $RegPath
    $prevEnv = @{}
    foreach ($n in $EnvNames) { $prevEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'User') }
    $new = @{
        RelayPid = $relay.Pid
        Port     = $relay.Port
        Started  = (Get-Date -Format s)
        Previous = @{
            ProxyEnable   = [int]$reg.ProxyEnable
            ProxyServer   = $reg.ProxyServer
            ProxyOverride = $reg.ProxyOverride
            Env           = $prevEnv
        }
    }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    $new | ConvertTo-Json -Depth 5 | Set-Content $StateFile
    Set-WindowsProxy $relay.Port
    Remove-Item $AutoOffNote -ErrorAction SilentlyContinue
    # If the PC is restarted while ON, reset to OFF automatically at sign-in.
    if (Test-Path $LocalCopy) {
        Set-ItemProperty $RunKey $RunName ("powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LocalCopy`" -Action Repair")
    }

    $mbps = Measure-SpeedVia $relay.Port
    Say ''
    Say '  PHONE INTERNET IS ON.' Green
    if ($mbps) { Say "  Measured download speed: $mbps Mbps" Green }
    Say '  - Browsers and most apps now use the phone''s data. If a browser'
    Say '    was already open and still fails, close and reopen it.'
    Say '  - Command-line tools started from NEW terminal windows also use it.'
    Say '  - Keep the phone plugged in, with Every Proxy running.'
    Say '  - You can close this window; it stays ON.'
    Say '  - When done, choose option 2 (turn OFF). If you forget and just' Yellow
    Say '    unplug the phone, it turns itself OFF after about 15 seconds' Yellow
    Say '    and the PC goes back to its normal connection.' Yellow
    return $true
}

function Invoke-Off([switch]$Quiet) {
    $state = Read-State
    Restore-WindowsProxy $state
    Stop-Relay $state
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    Remove-ItemProperty $RunKey $RunName -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        Say ''
        Say '  PHONE INTERNET IS OFF.' Green
        Say '  The PC now uses Wi-Fi if it is connected. With no Wi-Fi and the'
        Say '  phone still tethered, it uses the slow (throttled) tether.'
    }
}

function Show-Status {
    $state = Read-State
    $relay = Get-RelayProcess $state
    $ours  = Get-ProxyIsOurs
    Say ''
    if ($relay -and $ours) {
        Say "  Current state: ON  (since $($state.Started))" Green
    } elseif ($ours -or $state) {
        Say '  Current state: BROKEN - left on from an earlier session.' Yellow
    } else {
        Say '  Current state: OFF' Gray
        if (Test-Path $AutoOffNote) {
            Say "  (It turned itself OFF at $((Get-Content $AutoOffNote -Raw).Trim()).)" Yellow
            Remove-Item $AutoOffNote -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Test {
    $state = Read-State
    $relay = Get-RelayProcess $state
    if ($relay -and (Get-ProxyIsOurs)) {
        if (-not (Test-PhoneLink)) { return }
        if (Test-InternetVia $state.Port) { Good 'Internet through the phone is working.' }
        else { Bad 'Phone answers but has no internet (mobile data / signal?).'; return }
        $m = Measure-SpeedVia $state.Port
    } else {
        if (-not (Test-PhoneLink)) { return }
        $tmp = Start-Relay
        if (-not $tmp) { Bad 'Could not start the local relay for the test.'; return }
        if (Test-InternetVia $tmp.Port) { Good 'Internet through the phone is working.' }
        elseif (Test-LoginRejected $tmp.Port) { Show-LoginFix }
        else { Bad 'Phone answers but has no internet (mobile data / signal?).' }
        $m = Measure-SpeedVia $tmp.Port
        Stop-Process -Id $tmp.Pid -Force -ErrorAction SilentlyContinue
        Info '(Test only - nothing was changed on this PC.)'
    }
    if ($m) { Say "  Download speed through the phone: $m Mbps" Green }
    else { Info 'Speed could not be measured (speed-test site not reachable).' }
}

# A previous session can leave the proxy set with no relay running (PC was
# restarted or the phone unplugged without turning OFF). Clean that up.
function Repair-StaleState {
    $state = Read-State
    $relay = Get-RelayProcess $state
    if (((Get-ProxyIsOurs) -or $state) -and -not $relay) {
        Invoke-Off -Quiet
        Say ''
        Say '  NOTE: phone internet had been left ON from an earlier session' Yellow
        Say '  (PC restarted, or phone unplugged). It has been reset to OFF.' Yellow
    }
}

# ------------------------------------------------- relay (background)

# The hidden relay process. Besides forwarding, it watches the phone: if the
# USB link disappears (phone unplugged, tethering switched off) or the proxy
# app stops answering, it turns everything OFF by itself so the PC falls
# back to its normal connection instead of showing proxy errors.
if ($RunRelay) {
    Use-Login
    [PhoneRelay]::Start($RelayPort)
    $linkGone = 0; $proxyGone = 0; $tick = 0
    while ($true) {
        Start-Sleep 3
        $tick++
        if (@([PhoneRelay]::FindTargets()).Count -eq 0) { $linkGone += 3 } else { $linkGone = 0 }
        if ($tick % 5 -eq 0) {                       # every 15 s
            if ($linkGone -eq 0 -and -not [PhoneRelay]::Probe()) { $proxyGone += 15 } else { $proxyGone = 0 }
        }
        $why = $null
        if ($linkGone -ge 15)  { $why = 'the phone was unplugged or USB tethering was switched off' }
        if ($proxyGone -ge 60) { $why = 'the Every Proxy app on the phone stopped answering' }
        if ($why) {
            $state = Read-State
            if ($state -and [int]$state.RelayPid -eq $PID) {
                Restore-WindowsProxy $state
                Remove-Item $StateFile -ErrorAction SilentlyContinue
                Remove-ItemProperty $RunKey $RunName -ErrorAction SilentlyContinue
                Set-Content $AutoOffNote "$(Get-Date -Format 'yyyy-MM-dd HH:mm'): $why"
            }
            exit
        }
    }
}

# --------------------------------------------------------------- run

if ($Action -eq 'Repair') {          # run silently at sign-in after a restart
    $st = Read-State
    if (((Get-ProxyIsOurs) -or $st) -and -not (Get-RelayProcess $st)) {
        Invoke-Off -Quiet
        New-Item -ItemType Directory -Force $WorkDir | Out-Null
        Set-Content $AutoOffNote "$(Get-Date -Format 'yyyy-MM-dd HH:mm'): the PC was restarted while it was ON"
    }
    Remove-ItemProperty $RunKey $RunName -ErrorAction SilentlyContinue
    exit 0
}

if ($Action) {
    Repair-StaleState
    switch ($Action) {
        'On'     { if (Invoke-On) { exit 0 } else { exit 1 } }
        'Off'    { Invoke-Off; exit 0 }
        'Test'   { Invoke-Test; exit 0 }
        'Status' { Show-Status; exit 0 }
        default  { Say "Unknown action '$Action'"; exit 2 }
    }
}

try { $Host.UI.RawUI.WindowTitle = 'Phone Internet over USB' } catch { }
Repair-StaleState
while ($true) {
    Say ''
    Say '  ==========================================================' Cyan
    Say '   PHONE INTERNET OVER USB  (uses the phone''s own mobile data)' Cyan
    Say '  ==========================================================' Cyan
    Show-Status
    Say ''
    Say '   1  Turn ON   - use the phone''s internet on this PC'
    Say '   2  Turn OFF  - stop using the phone''s fast data (PC returns to'
    Say '                  Wi-Fi, or the slow tether if there is no Wi-Fi)'
    Say '   3  Test      - check the phone link and speed, change nothing'
    Say '   4  Show the phone settings, step by step'
    $lg = Read-Login
    if ($lg) { Say "   5  Change the proxy username/password (saved: user '$($lg.User)')" }
    else     { Say '   5  Set a proxy username/password (none saved; only needed if' ; Say '      you turned on authentication in the Every Proxy app)' }
    Say '   6  Quit'
    Say ''
    $choice = Read-Host '  Type a number and press Enter'
    switch ($choice.Trim()) {
        '1' {
            while (-not (Invoke-On)) {
                Say ''
                $again = Read-Host '  Fix the item above, then press Enter to retry (or type M for menu)'
                if ($again.Trim() -match '^[mM]') { break }
            }
        }
        '2' { Invoke-Off }
        '3' { Invoke-Test }
        '4' { Show-PhoneSteps }
        '5' {
            Say ''
            Say '  Type the SAME username and password that are set in the Every' Cyan
            Say '  Proxy app on the phone (pencil icon next to "HTTP Proxy").' Cyan
            Say '  Leave the username empty and press Enter to remove the saved one.'
            $u = (Read-Host '  Username').Trim()
            if ($u) {
                $p = (Read-Host '  Password').Trim()
                Save-Login $u $p
                Say "  Saved for user '$u'." Green
            } else {
                Save-Login $null $null
                Say '  Saved username/password removed.' Green
            }
            $st = Read-State
            if ($st -and (Get-RelayProcess $st)) {
                Say '  Restarting phone internet with the new setting...'
                Invoke-Off -Quiet
                [void](Invoke-On)
            }
        }
        '6' {
            $st = Read-State
            if ($st -and (Get-RelayProcess $st)) {
                Say ''
                Say '  Phone internet stays ON after this window closes.' Yellow
                Say '  Start this again and choose 2 to turn it OFF.' Yellow
                Start-Sleep 3
            }
            exit 0
        }
        default { Say '  Please type 1, 2, 3, 4, 5 or 6.' Yellow }
    }
}
