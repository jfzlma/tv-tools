# tv-tools

Tools for a HiSilicon Android TV (built on a HiDPT Hi3751V350, Android 9, 512 MB RAM) controlled
from a Mac over network adb.

## 1. Connect the TV

### Turn on network debugging

1. On the TV: **Settings → Device Preferences → About**, then press OK on **Build** 7 times
   to unlock Developer options.
2. **Settings → Device Preferences → Developer options**: turn on **USB debugging**
   (on many TV boxes this also enables **Network debugging / ADB over network**; turn that on too if listed).
3. Install adb on the Mac: `brew install android-platform-tools`
   (or use the Android SDK's `platform-tools/adb`).

### Find the TV's IP address

Any one of these works:

- **On the TV:** Settings → Network & Internet → select the connected Wi-Fi/Ethernet network,
  or Settings → Device Preferences → About → Status. Look for **IP address** (e.g. `192.168.1.50`).
- **On the Mac:** `./find-tv.sh` scans your network for devices with adb open and prints each
  one's address and model:

  ```
  $ ./find-tv.sh
  Scanning 192.168.1.1-254 for adb (port 5555)…
  192.168.1.50:5555  HiDPTAndroid Hi3751V350
  ```

  Pass a subnet if the Mac is on several networks: `./find-tv.sh 192.168.0`.
- **On your router:** its admin page lists connected devices; look for an Android/HiSilicon device.

### Connect

```sh
export TV=192.168.1.50:5555      # your TV's address
adb connect $TV
```

If the TV shows **"Allow USB debugging?"**, choose **Always allow from this computer**.

The TV's address can change when it reconnects to Wi-Fi. To keep it fixed, reserve it for the TV
in your router's DHCP settings.

## 2. TV Remote (tvremote/)

macOS remote (SwiftUI, built with `swiftc`, no Xcode project).

```sh
tvremote/build.sh          # -> tvremote/build/TV Remote.app
```

**Choosing the TV:** on first launch the app scans the network and connects automatically if it
finds exactly one TV. Otherwise click **Find TV** and pick yours from the list, or type its IP
(`192.168.1.50` or `192.168.1.50:5555`) and press **Connect**. The choice is remembered.
If the TV's address changes, click **Find TV** again.

macOS may ask to let TV Remote **find devices on your local network**: allow it, or the scan and
connection fail.

It keeps one root `adb shell` open and writes raw `struct input_event`s to the TV's virtual
"Hi keyboard" input device, about 30 ms per key instead of ~1.2 s for `input keyevent`. Press
and release are sent separately, so holding a button auto-repeats on the TV.

Trackpad: click the pad to capture the Mac pointer; motion, clicks and two-finger scroll then go to
the TV's virtual "Hi mouse" (right-click = Back). Esc releases. Events are written with mksh's
builtin `print` (~0.2 ms, no process spawn) and motion is coalesced to 60 Hz.

Keyboard: arrows, Return = OK, Esc/Delete = Back, H Home, M Menu, Space Play/Pause,
`=`/`-` volume, `;` mute, S Source, I Info. The text box types on the TV via `input text`.

Key codes come from the TV's `/vendor/usr/keylayout/Vendor_0001_Product_0001.kl`
(e.g. 250 = Source, 248 = Picture Mode).

**Requirements:** raw input injection needs a root adb shell (true on this TV's `eng` firmware).
On a TV whose adb shell isn't root, the app shows "No root access to input device".

## Scripts

- `find-tv.sh [subnet]` lists TVs on the network with adb open.
- `tv-shell.sh '<command>'` runs a command in the TV's shell (uses `$TV`, or adb's only device).
