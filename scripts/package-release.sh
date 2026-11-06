#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="墨读.app"
BUNDLE_ID="local.thomas.inkread"
APP_PATH="$PROJECT_DIR/build/$APP_NAME"
OUTPUT_DIR=""
SKIP_BUILD=0
TEMP_DIR=""
MOUNT_POINT=""
MOUNT_ATTEMPTED=0
PACKAGE_COMMITTED=0
VERSION=""
BUILD_VERSION=""
ARCHITECTURE=""
DMG_NAME=""
ZIP_NAME=""
PYTHON_BIN=""

usage() {
    cat <<'USAGE'
用法：./scripts/package-release.sh [--skip-build] [--output-dir DIR]

构建并验证 build/墨读.app，生成 DMG、ZIP 和 SHA256SUMS.txt。
默认输出到项目 release/版本号/；--output-dir 精确指定输出目录。
--skip-build 使用已有的 build/墨读.app。
已有同名发布文件时直接报错，不覆盖、不安装、不修改书库。
USAGE
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --output-dir)
            [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || fail '--output-dir 需要目录路径'
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}"; [[ -n "$OUTPUT_DIR" ]] || fail '输出目录不能为空'; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "未知参数：$1" ;;
    esac
done

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '此脚本需要 macOS'
PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || fail '需要 Python 3 标准库来验证 ZIP 和 DMG'
for tool in /usr/bin/hdiutil /usr/bin/ditto /usr/bin/codesign /usr/bin/lipo /usr/bin/shasum /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || fail "缺少 macOS 打包工具：$tool"
done

cleanup() {
    local status=$?
    local keep_temp=0
    local name
    trap - EXIT
    if [[ "$MOUNT_ATTEMPTED" -eq 1 && -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        if "$PYTHON_BIN" -c 'import os,sys; sys.exit(0 if os.path.ismount(sys.argv[1]) else 1)' "$MOUNT_POINT"; then
            if ! /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then
                if ! /usr/bin/hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1; then
                    printf '无法卸载本次验证卷，已保留临时目录：%s\n' "$TEMP_DIR" >&2
                    keep_temp=1
                    [[ "$status" -ne 0 ]] || status=1
                fi
            fi
        fi
    fi
    # Final files are exclusive hard links to our own staged files. Roll back
    # only those same inodes if publication fails halfway through.
    if [[ "$PACKAGE_COMMITTED" -eq 0 && -n "$TEMP_DIR" ]]; then
        for name in "$DMG_NAME" "$ZIP_NAME" SHA256SUMS.txt; do
            if [[ -n "$name" && -f "$TEMP_DIR/$name" && ! -L "$OUTPUT_DIR/$name" \
                  && "$TEMP_DIR/$name" -ef "$OUTPUT_DIR/$name" ]]; then
                /bin/rm -f -- "$OUTPUT_DIR/$name"
            fi
        done
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$keep_temp" -eq 0 ]]; then
        case "$TEMP_DIR" in
            "$OUTPUT_DIR"/.InkRead-package.*) /bin/rm -rf -- "$TEMP_DIR" ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "拒绝覆盖已有发布文件：$1"
}

prepare_output_directory() {
    [[ ! -L "$OUTPUT_DIR" ]] || fail '输出目录不能是符号链接'
    /bin/mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
    require_absent "$OUTPUT_DIR/SHA256SUMS.txt"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null \
        || fail "无法读取应用属性：$2"
}

architecture() {
    local slices
    slices="$(/usr/bin/lipo -archs "$1/Contents/MacOS/InkRead")"
    case "$slices" in
        arm64) printf 'arm64\n' ;;
        x86_64) printf 'x86_64\n' ;;
        'arm64 x86_64'|'x86_64 arm64') printf 'universal\n' ;;
        *) fail "不支持的 Mach-O 架构组合：$slices" ;;
    esac
}

verify_bundle() {
    local bundle="$1"
    local identifier executable version build signature_identifier arch
    [[ -d "$bundle" && ! -L "$bundle" ]] || fail "不是有效的应用目录：$bundle"
    identifier="$(plist_value "$bundle" CFBundleIdentifier)"
    executable="$(plist_value "$bundle" CFBundleExecutable)"
    version="$(plist_value "$bundle" CFBundleShortVersionString)"
    build="$(plist_value "$bundle" CFBundleVersion)"
    [[ "$identifier" == "$BUNDLE_ID" && "$executable" == InkRead ]] || fail '应用标识或可执行文件不匹配'
    [[ "$version" =~ ^[0-9][0-9A-Za-z.+_-]*$ ]] || fail '版本号必须是可用于文件名的 ASCII 版本号'
    [[ -n "$build" && -x "$bundle/Contents/MacOS/InkRead" ]] || fail '应用缺少构建号或可执行文件'
    [[ -z "$VERSION" || "$version" == "$VERSION" ]] || fail '发布包中的版本号不匹配'
    [[ -z "$BUILD_VERSION" || "$build" == "$BUILD_VERSION" ]] || fail '发布包中的构建号不匹配'
    /usr/bin/codesign --verify --deep --strict "$bundle"
    signature_identifier="$(/usr/bin/codesign --display --verbose=2 "$bundle" 2>&1 \
        | /usr/bin/awk -F= '$1 == "Identifier" { print $2 }')"
    [[ "$signature_identifier" == "$BUNDLE_ID" ]] || fail '代码签名标识不匹配'
    arch="$(architecture "$bundle")"
    [[ -z "$ARCHITECTURE" || "$arch" == "$ARCHITECTURE" ]] || fail '发布包中的架构不匹配'
    if [[ "$bundle" != "$APP_PATH" ]]; then
        /usr/bin/cmp -s "$APP_PATH/Contents/MacOS/InkRead" "$bundle/Contents/MacOS/InkRead" \
            || fail '发布包中的程序与构建结果不一致'
        /usr/bin/cmp -s "$APP_PATH/Contents/Info.plist" "$bundle/Contents/Info.plist" \
            || fail '发布包中的 Info.plist 与构建结果不一致'
    fi
}

if [[ -n "$OUTPUT_DIR" ]]; then prepare_output_directory; fi
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    /bin/bash "$SCRIPT_DIR/build-app.sh"
fi
verify_bundle "$APP_PATH"
VERSION="$(plist_value "$APP_PATH" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value "$APP_PATH" CFBundleVersion)"
ARCHITECTURE="$(architecture "$APP_PATH")"
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$PROJECT_DIR/release/$VERSION"
    prepare_output_directory
fi
DMG_NAME="InkRead-$VERSION-macOS-$ARCHITECTURE.dmg"
ZIP_NAME="InkRead-$VERSION-macOS-$ARCHITECTURE.zip"
require_absent "$OUTPUT_DIR/$DMG_NAME"
require_absent "$OUTPUT_DIR/$ZIP_NAME"
TEMP_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.InkRead-package.XXXXXX")"

printf '正在打包 InkRead %s（%s）…\n' "$VERSION" "$ARCHITECTURE"
/bin/mkdir "$TEMP_DIR/contents" "$TEMP_DIR/zip-check" "$TEMP_DIR/mount"
/usr/bin/ditto "$APP_PATH" "$TEMP_DIR/contents/$APP_NAME"
verify_bundle "$TEMP_DIR/contents/$APP_NAME"
/bin/ln -s /Applications "$TEMP_DIR/contents/Applications"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TEMP_DIR/contents/$APP_NAME" "$TEMP_DIR/$ZIP_NAME"

# Use the archive's actual entry name: macOS ZIP resource-fork/name encoding
# can differ from the Unicode string shown by Finder.
"$PYTHON_BIN" - "$TEMP_DIR/$ZIP_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_VERSION" <<'PY'
import pathlib, plistlib, sys, zipfile
archive_path, bundle_id, version, build = sys.argv[1:]
with zipfile.ZipFile(archive_path) as archive:
    if archive.testzip() is not None:
        raise SystemExit('ZIP CRC 校验失败')
    names = archive.namelist()
    if any(name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts for name in names):
        raise SystemExit('ZIP 含非相对路径')
    plists = [name for name in names if not name.startswith('__MACOSX/')
              and name.endswith('.app/Contents/Info.plist')]
    if len(plists) != 1:
        raise SystemExit('ZIP 中的应用数量不匹配')
    root = plists[0].split('/')[0]
    if any(name.split('/')[0] not in {root, '__MACOSX'} for name in names):
        raise SystemExit('ZIP 含非应用内容')
    info = plistlib.loads(archive.read(plists[0]))
    expected = {'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': version,
                'CFBundleVersion': build, 'CFBundleExecutable': 'InkRead'}
    if any(info.get(key) != value for key, value in expected.items()):
        raise SystemExit('ZIP 应用属性不匹配')
PY
/usr/bin/ditto -x -k "$TEMP_DIR/$ZIP_NAME" "$TEMP_DIR/zip-check"
verify_bundle "$TEMP_DIR/zip-check/$APP_NAME"

/usr/bin/hdiutil create -quiet -format UDZO -fs HFS+ -volname "InkRead $VERSION" \
    -srcfolder "$TEMP_DIR/contents" "$TEMP_DIR/$DMG_NAME"
/usr/bin/hdiutil verify -quiet "$TEMP_DIR/$DMG_NAME"
/usr/bin/hdiutil imageinfo -plist "$TEMP_DIR/$DMG_NAME" > "$TEMP_DIR/image-info.plist"
MOUNT_POINT="$TEMP_DIR/mount"
MOUNT_ATTEMPTED=1
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" \
    -plist "$TEMP_DIR/$DMG_NAME" > "$TEMP_DIR/attachment.plist"
"$PYTHON_BIN" - "$TEMP_DIR/image-info.plist" "$TEMP_DIR/attachment.plist" "$MOUNT_POINT" "$APP_NAME" <<'PY'
import os, pathlib, plistlib, sys
image_info, attachment, mount_path, app_name = sys.argv[1:]
with open(image_info, 'rb') as handle:
    if plistlib.load(handle).get('Format') != 'UDZO':
        raise SystemExit('DMG 不是只读 UDZO 格式')
with open(attachment, 'rb') as handle:
    entities = plistlib.load(handle).get('system-entities', [])
    if not any(item.get('mount-point') == mount_path for item in entities):
        raise SystemExit('DMG 未挂载到本次验证目录')
if not os.statvfs(mount_path).f_flag & os.ST_RDONLY:
    raise SystemExit('DMG 验证卷不是只读挂载')
mount = pathlib.Path(mount_path)
allowed = {app_name, 'Applications', '.HFS+ Private Directory Data\r', '.Trashes', '.fseventsd', '.Spotlight-V100'}
if any(item.name not in allowed for item in mount.iterdir()):
    raise SystemExit('DMG 含非预期内容')
link = mount / 'Applications'
if not link.is_symlink() or os.readlink(link) != '/Applications':
    raise SystemExit('DMG 缺少正确的 Applications 链接')
PY
verify_bundle "$MOUNT_POINT/$APP_NAME"
/usr/bin/hdiutil detach -quiet "$MOUNT_POINT"
MOUNT_ATTEMPTED=0

(
    cd "$TEMP_DIR"
    /usr/bin/shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)
# link(2) creates each final name exclusively, including when a competing
# process creates a file, directory, or dangling symlink at that name.
for name in "$DMG_NAME" "$ZIP_NAME" SHA256SUMS.txt; do
    "$PYTHON_BIN" - "$TEMP_DIR/$name" "$OUTPUT_DIR/$name" <<'PY'
import os, sys
try:
    os.link(sys.argv[1], sys.argv[2], follow_symlinks=False)
except FileExistsError:
    raise SystemExit('拒绝覆盖已有发布文件：' + sys.argv[2])
except OSError as error:
    raise SystemExit('发布文件失败：' + error.strerror)
PY
done
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
PACKAGE_COMMITTED=1
printf '已验证版本、签名、架构、ZIP CRC 和只读 DMG。\n'
printf 'DMG：%s\nZIP：%s\nSHA256：%s\n' \
    "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME" "$OUTPUT_DIR/SHA256SUMS.txt"
