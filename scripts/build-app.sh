#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
macos_dir="$project_root/macos"
build_dir="$macos_dir/.build"
app_dir="$project_root/dist/Claude Cache Watch.app"

swift build --package-path "$macos_dir" -c release

if [[ -e "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/ClaudeCacheWatch" "$app_dir/Contents/MacOS/ClaudeCacheWatch"
cp "$macos_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_root/claude_cache_watch.py" "$app_dir/Contents/Resources/claude_cache_watch.py"
chmod +x "$app_dir/Contents/MacOS/ClaudeCacheWatch" "$app_dir/Contents/Resources/claude_cache_watch.py"
codesign --force --sign - "$app_dir"

echo "$app_dir"
