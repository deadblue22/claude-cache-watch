#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
macos_dir="$project_root/macos"
build_dir="$macos_dir/.build"
app_dir="$project_root/dist/Claude Cache Watch.app"
icon_source="$project_root/assets/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"
icon_file="$build_dir/AppIcon.icns"

swift build --package-path "$macos_dir" -c release

/bin/rm -rf "$iconset_dir"
/bin/rm -f "$icon_file"
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
/usr/bin/iconutil -c icns "$iconset_dir" -o "$icon_file"

if [[ -e "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/ClaudeCacheWatch" "$app_dir/Contents/MacOS/ClaudeCacheWatch"
cp "$macos_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_root/claude_cache_watch.py" "$app_dir/Contents/Resources/claude_cache_watch.py"
cp "$icon_file" "$app_dir/Contents/Resources/AppIcon.icns"
chmod +x "$app_dir/Contents/MacOS/ClaudeCacheWatch" "$app_dir/Contents/Resources/claude_cache_watch.py"
codesign --force --sign - "$app_dir"

echo "$app_dir"
