# tv-tools

Tools for the HiDPT Hi3751V350 Android 9 TV (512 MB RAM, root adb at `192.168.220.110:5555`).

## minilauncher/

Minimal D-pad home screen: clock, TV Settings tile, then every launchable app (banners for TV apps).
OK opens an app; hold OK or press Menu for its app info. ~12 MB RAM vs ~31 MB for Projectivy.

```sh
minilauncher/build.sh                       # aapt2 + javac + d8 + apksigner, no Gradle
adb -s 192.168.220.110:5555 install -r minilauncher/MiniLauncher.apk
adb -s 192.168.220.110:5555 shell cmd package set-home-activity local.minilauncher/.MainActivity
```

Revert to Projectivy:

```sh
adb -s 192.168.220.110:5555 shell cmd package set-home-activity com.spocky.projengmenu/.ui.home.MainActivity
```

`minilauncher.keystore` signs the APK. Keep it: `install -r` over the installed app only works with the same key.

## tvremote/

macOS remote (SwiftUI, built with `swiftc`). Keeps one root `adb shell` open and writes raw
`struct input_event`s to the TV's virtual "Hi keyboard" (`/dev/input/event0`), about 30 ms per key
instead of ~1.2 s for `input keyevent`. Press and release are sent separately, so holding a button
auto-repeats on the TV.

```sh
tvremote/build.sh          # -> tvremote/build/TV Remote.app
```

Trackpad: click the pad to capture the Mac pointer; motion, clicks and two-finger scroll then go to
the TV's virtual "Hi mouse" (right-click = Back). Esc releases. Events are written with mksh's
builtin `print` (~0.2 ms, no process spawn) and motion is coalesced to 60 Hz.

Keyboard: arrows, Return = OK, Esc/Delete = Back, H Home, M Menu, Space Play/Pause,
`=`/`-` volume, `;` mute, S Source, I Info. The text box types on the TV via `input text`.

Key codes come from the TV's `/vendor/usr/keylayout/Vendor_0001_Product_0001.kl`
(e.g. 250 = Source, 248 = Picture Mode).

## tv-shell.sh

`tv-shell.sh '<command>'` runs a command in the TV's root shell.
