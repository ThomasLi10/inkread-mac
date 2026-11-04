#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="墨读.app"
BUNDLE_ID="local.thomas.inkread"
APP_PATH="$BUILD_DIR/$APP_NAME"
USER_APPLICATIONS="$HOME/Applications"
DO_INSTALL=0
STAGING_DIR=""
INSTALL_STAGING_DIR=""
INSTALL_TARGET=""
INSTALL_BACKUP_APP=""

usage() {
    cat <<'USAGE'
用法：./scripts/build-app.sh [--install]

默认：构建 release、生成图标、打包并本地临时签名 build/墨读.app。
--install：额外安装到 ~/Applications/墨读.app。
           只替换 bundle identifier 相同的旧版本，替换前保留备份。
           不修改本地书库，也不设置默认 PDF 阅读器。
USAGE
}

for argument in "$@"; do
    case "$argument" in
        --install) DO_INSTALL=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf '未知参数：%s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

cleanup() {
    local status=$?
    # If installing the new bundle failed after moving the previous version,
    # restore the old app. User library data is outside every path touched here.
    if [[ "$status" -ne 0 && -n "$INSTALL_BACKUP_APP" && -d "$INSTALL_BACKUP_APP" \
          && -n "$INSTALL_TARGET" && ! -e "$INSTALL_TARGET" ]]; then
        /bin/mv "$INSTALL_BACKUP_APP" "$INSTALL_TARGET" || true
    fi
    if [[ -n "$INSTALL_STAGING_DIR" && -d "$INSTALL_STAGING_DIR" ]]; then
        case "$INSTALL_STAGING_DIR" in
            "$USER_APPLICATIONS"/.InkRead-install.*) /bin/rm -rf -- "$INSTALL_STAGING_DIR" ;;
        esac
    fi
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        case "$STAGING_DIR" in
            "$BUILD_DIR"/.package.*) /bin/rm -rf -- "$STAGING_DIR" ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT

bundle_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

check_replaceable() {
    local destination="$1"
    if [[ -L "$destination" ]]; then
        printf '拒绝替换符号链接：%s\n' "$destination" >&2
        exit 1
    fi
    if [[ -e "$destination" ]]; then
        local existing_id
        existing_id="$(bundle_identifier "$destination" || true)"
        if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
            printf '已有同名文件的标识不匹配，保留原文件：%s\n' "$destination" >&2
            exit 1
        fi
    fi
}

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"
check_replaceable "$APP_PATH"
printf '正在构建 InkRead release…\n'
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
if [[ ! -x "$BIN_DIR/InkRead" ]]; then
    printf '未找到 release 可执行文件：%s\n' "$BIN_DIR/InkRead" >&2
    exit 1
fi

printf '正在生成墨读图标…\n'
xcrun swift "$SCRIPT_DIR/make-icon.swift" "$BUILD_DIR/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
/usr/bin/plutil -lint "$PROJECT_DIR/Resources/Info.plist"

STAGING_DIR="$(mktemp -d "$BUILD_DIR/.package.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/ditto "$BIN_DIR/InkRead" "$STAGED_APP/Contents/MacOS/InkRead"
/usr/bin/ditto "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/bin/ditto "$BUILD_DIR/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/InkRead"

# Ad-hoc signing is fully local; no account, network timestamp or notarization.
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"

if [[ -d "$APP_PATH" ]]; then
    /bin/mv "$APP_PATH" "$STAGING_DIR/previous.app"
fi
if ! /bin/mv "$STAGED_APP" "$APP_PATH"; then
    if [[ -d "$STAGING_DIR/previous.app" ]]; then
        /bin/mv "$STAGING_DIR/previous.app" "$APP_PATH"
    fi
    exit 1
fi
printf '已生成：%s\n' "$APP_PATH"

if [[ "$DO_INSTALL" -eq 1 ]]; then
    mkdir -p "$USER_APPLICATIONS"
    INSTALL_TARGET="$USER_APPLICATIONS/$APP_NAME"
    check_replaceable "$INSTALL_TARGET"
    INSTALL_STAGING_DIR="$(mktemp -d "$USER_APPLICATIONS/.InkRead-install.XXXXXX")"
    /usr/bin/ditto "$APP_PATH" "$INSTALL_STAGING_DIR/$APP_NAME"
    /usr/bin/codesign --verify --strict --verbose=2 "$INSTALL_STAGING_DIR/$APP_NAME"
    if [[ -d "$INSTALL_TARGET" ]]; then
        BACKUP_ROOT="$USER_APPLICATIONS/InkRead Backups"
        mkdir -p "$BACKUP_ROOT"
        BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S').XXXXXX")"
        INSTALL_BACKUP_APP="$BACKUP_DIR/$APP_NAME"
        /bin/mv "$INSTALL_TARGET" "$INSTALL_BACKUP_APP"
        printf '旧版本备份：%s\n' "$INSTALL_BACKUP_APP"
    fi
    /bin/mv "$INSTALL_STAGING_DIR/$APP_NAME" "$INSTALL_TARGET"
    printf '已安装：%s\n' "$INSTALL_TARGET"
    printf '可在 Finder 中双击打开。书库保留在 Application Support/InkRead。\n'
fi
