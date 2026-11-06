#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=TokenWidget.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/
swiftc -O -parse-as-library -o $APP/Contents/MacOS/TokenWidget TokenWidget.swift
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dh.TokenWidget</string>
<key>CFBundleName</key><string>TokenWidget</string>
<key>CFBundleExecutable</key><string>TokenWidget</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign -s - --force $APP
echo "built $APP"
