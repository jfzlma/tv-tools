#!/bin/sh
# Builds MiniLauncher.apk without Gradle: aapt2 -> javac -> d8 -> zipalign -> apksigner.
set -eu
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.1.0"
JAR="$SDK/platforms/android-36/android.jar"
KS="${KEYSTORE:-$PWD/minilauncher.keystore}"

rm -rf build && mkdir -p build/classes build/dex

if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias minilauncher -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Mini Launcher" >/dev/null 2>&1
fi

"$BT/aapt2" link -o build/base.apk -I "$JAR" --manifest AndroidManifest.xml \
  --min-sdk-version 21 --target-sdk-version 28 --version-code 1 --version-name 1.0

javac --release 8 -Xlint:-options -classpath "$JAR" -d build/classes $(find src -name '*.java')

"$BT/d8" --release --min-api 21 --lib "$JAR" --output build/dex $(find build/classes -name '*.class')

cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q -j ../unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out MiniLauncher.apk build/aligned.apk
"$BT/apksigner" verify MiniLauncher.apk
ls -l MiniLauncher.apk
