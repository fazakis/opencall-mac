#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
BT_VERSION="36.0.0"
BT="$SDK/build-tools/$BT_VERSION"
PLATFORM="$SDK/platforms/android-36/android.jar"
JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export JAVA_HOME="$JBR"
export PATH="$JAVA_HOME/bin:$BT:$PATH"
APPDIR="android-companion/app/src/main"
BUILDDIR="android-companion/build"
OUTDIR="apk"
PKG="com.fazakis.opencallcompanion"
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR/res" "$BUILDDIR/generated" "$BUILDDIR/classes" "$BUILDDIR/dex" "$OUTDIR"
"$BT/aapt2" compile --dir "$APPDIR/res" -o "$BUILDDIR/res/compiled.flata"
"$BT/aapt2" link \
  -o "$BUILDDIR/base-unsigned.apk" \
  -I "$PLATFORM" \
  --manifest "$APPDIR/AndroidManifest.xml" \
  -R "$BUILDDIR/res/compiled.flata" \
  --java "$BUILDDIR/generated" \
  --auto-add-overlay
find "$APPDIR/java" "$BUILDDIR/generated" -name '*.java' > "$BUILDDIR/sources.list"
javac -encoding UTF-8 -source 17 -target 17 \
  -classpath "$PLATFORM" \
  -d "$BUILDDIR/classes" \
  @"$BUILDDIR/sources.list"
jar cf "$BUILDDIR/classes.jar" -C "$BUILDDIR/classes" .
"$BT/d8" --lib "$PLATFORM" --output "$BUILDDIR/dex" "$BUILDDIR/classes.jar"
cp "$BUILDDIR/base-unsigned.apk" "$BUILDDIR/with-dex.apk"
(cd "$BUILDDIR/dex" && zip -qr ../with-dex.apk classes.dex)
"$BT/zipalign" -f 4 "$BUILDDIR/with-dex.apk" "$BUILDDIR/aligned.apk"
KEYSTORE="$OUTDIR/opencall-companion-debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -storepass android -keypass android \
    -alias opencall-companion \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=OpenCall Companion,O=OpenCall,C=GR" >/dev/null
fi
APK="$OUTDIR/OpenCallCompanion-debug.apk"
"$BT/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$APK" \
  "$BUILDDIR/aligned.apk"
"$BT/apksigner" verify --print-certs "$APK" >/dev/null
echo "$PWD/$APK"
