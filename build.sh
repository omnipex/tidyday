#!/bin/bash
# 用法：./build.sh          只打包到 build/TidyDay.app
#       ./build.sh install  打包後安裝到 ~/Applications 並啟動
#       ./build.sh dist     打包成 build/TidyDay-<版本>.dmg 給別人安裝
#
# 有 Apple Developer ID 時可以正式簽章＋公證，別人安裝就不會被 Gatekeeper 擋：
#   SIGN_ID="Developer ID Application: 名字 (TEAMID)" NOTARY_PROFILE=notary ./build.sh dist
#   （NOTARY_PROFILE 先用 xcrun notarytool store-credentials notary 建立）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/TidyDay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TidyDay "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "打包完成：$APP"

if [[ "${1:-}" == "dist" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/TidyDay-$VERSION.dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp 安裝說明.txt "$STAGE/"
    hdiutil create -volname "TidyDay" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    if [[ -n "${SIGN_ID:-}" ]]; then
        codesign --force --sign "$SIGN_ID" "$DMG"
        if [[ -n "${NOTARY_PROFILE:-}" ]]; then
            xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$DMG"
        fi
    fi
    echo "安裝檔：$DMG"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x TidyDay || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/TidyDay.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/TidyDay.app
    echo "已安裝並啟動：~/Applications/TidyDay.app"
fi
