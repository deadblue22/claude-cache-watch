#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
macos_dir="$project_root/macos"
build_dir="$macos_dir/.build"
app_dir="$project_root/dist/Claude Cache Watch.app"
icon_svg="$project_root/assets/AppIcon.svg"
icon_source="$build_dir/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"
icon_file="$build_dir/AppIcon.icns"
asset_catalog_dir="$build_dir/AppIcon.xcassets"
asset_app_icon_dir="$asset_catalog_dir/AppIcon.appiconset"
asset_partial_plist="$build_dir/AppIconPartialInfo.plist"
uses_asset_catalog=false

swift build --package-path "$macos_dir" -c release
swift "$script_dir/render-app-icon.swift" "$icon_svg" "$icon_source"

/bin/rm -rf "$iconset_dir"
/bin/rm -rf "$asset_catalog_dir"
/bin/rm -f "$icon_file"
/bin/rm -f "$asset_partial_plist"
mkdir -p "$iconset_dir"

make_icon() {
    local size=$1
    local filename=$2
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

if /usr/bin/xcrun --find actool >/dev/null 2>&1; then
    mkdir -p "$asset_app_icon_dir"
    cp "$iconset_dir"/*.png "$asset_app_icon_dir/"
    cp "$macos_dir/AppIconContents.json" "$asset_app_icon_dir/Contents.json"
    uses_asset_catalog=true
else
    /usr/bin/iconutil -c icns "$iconset_dir" -o "$icon_file"
fi

if [[ -e "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/ClaudeCacheWatch" "$app_dir/Contents/MacOS/ClaudeCacheWatch"
cp "$macos_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_root/claude_cache_watch.py" "$app_dir/Contents/Resources/claude_cache_watch.py"

if [[ "$uses_asset_catalog" == true ]]; then
    /usr/bin/xcrun actool "$asset_catalog_dir" \
        --compile "$app_dir/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$asset_partial_plist" \
        --warnings \
        --notices >/dev/null
    /usr/bin/plutil -insert CFBundleIconName -string AppIcon "$app_dir/Contents/Info.plist"
else
    cp "$icon_file" "$app_dir/Contents/Resources/AppIcon.icns"
fi

chmod +x "$app_dir/Contents/MacOS/ClaudeCacheWatch" "$app_dir/Contents/Resources/claude_cache_watch.py"
codesign --force --sign - "$app_dir"

echo "$app_dir"
