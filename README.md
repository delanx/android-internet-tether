# Phone internet over USB (Android phone -> Windows PC)

Uses an Android phone's own mobile data on a Windows PC over a USB cable,
instead of the separate "hotspot" allowance that some mobile plans limit or
slow down.

## What you need

Get these ready **before** you are somewhere without internet:

1. **An Android phone with mobile data.**
2. **A proxy app installed on the phone.** Install **Every Proxy** from the
   Play Store (free, with ads); the script and its messages are written for
   it. See "Using a different proxy app" below for alternatives.
3. **This folder copied to the PC's local disk** (for example the Desktop).
   On a cloud drive the files may not be readable when the PC is offline.
4. **A Windows PC** (Windows 10 or later).
5. **A USB cable that carries data**, not a charge-only cable.

iPhone is not supported: Every Proxy is Android-only, and the script only
looks for an Android USB tethering connection.

Nothing has to be installed on the PC, no administrator rights are needed,
and the PC needs no internet connection to run it.

## How to use it

1. **Double-click `START Phone Internet.cmd`.** A menu opens.
2. Choose **4** to read the phone settings, and do them on the phone.
3. Choose **1** to turn it on. It checks each step and, if something is
   wrong, says exactly what to change on the phone. Fix it and press Enter
   to retry.
4. Choose **2** to turn it off when you are done. If you forget and just
   unplug the phone, it turns itself off after about 15 seconds.

You can close the menu window at any time; it stays on in the background.

## Phone settings (also shown by menu option 4)

Plug the unlocked phone into the PC with a USB cable, then do these two
things on the phone:

1. Turn on **USB tethering**: Settings > Network & internet > Hotspot &
   tethering > USB tethering. The menu names differ between phone makers;
   searching Settings for "USB tethering" finds it. It switches itself off
   every time the cable is unplugged, so redo it after each re-plug.
2. Open the **Every Proxy** app and turn on **HTTP Proxy** (Server tab,
   Port 8080).

That is normally all. If it does not work, check these on the phone:

- **VPN:** disconnect any VPN app. With a VPN connected the phone can
  silently refuse connections from the PC.
- **Data:** Wi-Fi OFF, Mobile data ON, Airplane mode OFF.
- **USB tethering greyed out:** the cable only charges; use another cable
  and a USB port directly on the PC.
- **Every Proxy:** use the Server tab only. If a banner says "Action
  required", tap Fix and allow it.
- **Username/password:** if authentication is switched on in Every Proxy,
  the same username and password must be saved on the PC with menu option 5.

### Proxy username and password (optional)

Every Proxy can require a username and password, so that other people on a
network the phone is connected to cannot use it as a proxy. Set them in the
app (pencil icon next to "HTTP Proxy"), then choose **5** in the menu and
type the same two values. They are stored as plain text in
`proxy-login.txt` in this folder, which git ignores. Browsers and apps on
the PC are never asked for them; the script adds them automatically.

### Using a different proxy app

Any Android app that runs an **HTTP proxy server** on the phone should work
(only Every Proxy has been tested). It must:

- accept connections from the USB tethering link, not only from the phone
  itself (in Every Proxy this is Host `0.0.0.0`);
- listen on port **8080**, or change `$PhonePort` near the top of
  `Phone-Internet.ps1` to the app's port;
- support HTTPS through the standard `CONNECT` method;
- use either no login or HTTP Basic username/password.

The script's messages will still say "Every Proxy"; read them as "your
proxy app".

## What to expect

- Browsers and most apps use the phone's data. Reopen a browser that was
  already open if it still fails.
- Command-line tools started from a **new** terminal window use it too
  (the script sets `HTTP_PROXY` / `HTTPS_PROXY` for your user account and
  removes them again on OFF).
- Programs that ignore proxy settings (some games, VPN clients) still use
  the plain tether path.
- OFF means the PC uses Wi-Fi if connected; with no Wi-Fi and the phone
  still tethered it uses the plain tether.
- It turns itself OFF automatically when:
  - the phone is unplugged or USB tethering is switched off (after ~15 s);
  - the Every Proxy app stops answering for a minute;
  - the PC is restarted while it was ON (reset at the next sign-in).
  The menu shows a note saying when and why this happened.

## Check your mobile plan first

Many mobile plans restrict tethering, and this method routes the PC's
traffic so that it looks like the phone's own. That may be against your
carrier's terms of service. Check your plan; you use this at your own risk.

## How it works

The phone is reached over the USB tether link, preferring its IPv6
link-local address. The script runs a small relay on `127.0.0.1` (port 8787 or the next free one) that
finds the phone's current address and forwards to Every Proxy on port 8080,
then points the Windows proxy setting at the relay. The relay runs from a
copy in `%LOCALAPPDATA%\PhoneInternet`, where the ON/OFF state is also kept.

Speed depends on the phone's mobile connection and plan.

## Files

- `START Phone Internet.cmd` - double-click to start.
- `Phone-Internet.ps1` - the menu script it runs.
- `Check-Tether.ps1` - checks the plain USB tether link and routing
  (diagnostic). Its options that change route priority need an
  administrator PowerShell.
