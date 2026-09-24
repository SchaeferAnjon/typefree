#!/bin/bash
# 构建并启动开发版 Typefree Dev（bundle id com.voicepolish.app.dev），不打扰正式版：
# - 配置在 ~/.config/voicepolish-dev，密钥存该目录下的 dev_secrets.json，不读写钥匙串
# - 不装进 /Applications，不自动更新，不登记登录项，不碰正在运行的正式版
#
# 用法：
#   bash mac/scripts/dev_run.sh [选项] [App 启动参数...]
#   选项：--no-build  跳过构建，直接重启上次编好的开发版
#         --onboarding 不自动加 -skipOnboarding（要看首次引导时用）
#         --stop       只结束正在运行的开发版
#   App 启动参数原样透传，例如 -openPage settings
#   环境变量里的 API Key（ARK_API_KEY、DASHSCOPE_API_KEY、ZHIPU_API_KEY 等）会带进开发版。
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$MAC_DIR/VoicePolish.xcodeproj"
SCHEME="VoicePolish"
# 不放 ~/Documents 下：那里的 iCloud 扩展属性会让 codesign 失败
DERIVED_DATA_PATH="/private/tmp/typefree-dev-dd"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Debug/Typefree.app"
DEV_APP="$DERIVED_DATA_PATH/Typefree Dev.app"
DEV_BUNDLE_ID="com.voicepolish.app.dev"
DEV_BINARY="$DEV_APP/Contents/MacOS/Typefree"

DO_BUILD=1
SKIP_ONBOARDING=1
APP_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --onboarding) SKIP_ONBOARDING=0 ;;
        --stop) DO_BUILD=-1 ;;
        *) APP_ARGS+=("$arg") ;;
    esac
done

stop_dev_app() {
    # 只按开发版可执行文件路径结束进程；正式版在 /Applications/Typefree.app，不会匹配
    if pgrep -f "$DEV_BINARY" >/dev/null 2>&1; then
        pkill -TERM -f "$DEV_BINARY" || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "$DEV_BINARY" >/dev/null 2>&1 || break
            sleep 0.3
        done
        pkill -KILL -f "$DEV_BINARY" 2>/dev/null || true
        echo "Stopped running Typefree Dev"
    fi
}

if [ "$DO_BUILD" = "-1" ]; then
    stop_dev_app
    exit 0
fi

if [ -f "$MAC_DIR/local.build.env" ]; then
    # shellcheck disable=SC1091
    . "$MAC_DIR/local.build.env"
fi
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"

if [ -n "$DEVELOPER_ID_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVELOPER_ID_IDENTITY"; then
    SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
    # 证书名末尾括号里是 Team ID，例如 "Developer ID Application: Name (ABCDE12345)"
    TEAM_ID="$(printf '%s' "$DEVELOPER_ID_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    SIGN_NOTE="Developer ID ($SIGN_IDENTITY)"
else
    SIGN_IDENTITY="-"
    TEAM_ID=""
    SIGN_NOTE="ad hoc"
fi

if [ "$DO_BUILD" = "1" ]; then
    echo "Building Typefree Dev (Debug, signing: $SIGN_NOTE)..."
    # xcodebuild 默认要 Mac Development 证书，这里显式指定签名身份，走 Manual
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        VP_TRIAL_API_BASE="" \
        VP_TRIAL_CERT_SHA256="" \
        -quiet \
        build

    if [ ! -d "$BUILT_APP" ]; then
        echo "ERROR: xcodebuild finished without producing $BUILT_APP" >&2
        exit 1
    fi

    stop_dev_app
    rm -rf "$DEV_APP"
    ditto "$BUILT_APP" "$DEV_APP"

    # 开发版身份：独立 bundle id 与显示名；Info.plist 写死了正式版 id，这里在拷贝上改
    PLIST="$DEV_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Typefree Dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Typefree Dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :TFSelfBuilt true" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :TFSelfBuilt bool true" "$PLIST"
    # 彻底断开 Sparkle 更新源
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :SUAutomaticallyUpdate false" "$PLIST" 2>/dev/null || true

    xattr -cr "$DEV_APP" 2>/dev/null || true
    # 改了 Info.plist 要重签外层 App（内部 framework / dylib 已由 xcodebuild 用同一身份签好）
    codesign --force --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements,flags \
        "$DEV_APP"
    codesign --verify --strict "$DEV_APP"
else
    if [ ! -d "$DEV_APP" ]; then
        echo "ERROR: $DEV_APP not found; run without --no-build first" >&2
        exit 1
    fi
    stop_dev_app
fi

if [ "$SKIP_ONBOARDING" = "1" ]; then
    APP_ARGS=(-skipOnboarding "${APP_ARGS[@]+"${APP_ARGS[@]}"}")
fi

ENV_ARGS=()
for name in ARK_API_KEY DASHSCOPE_API_KEY ZHIPU_API_KEY \
            BIGASR_API_KEY BIGASR_ACCESS_TOKEN BIGASR_APP_ID BIGASR_VERSION; do
    if [ -n "${!name:-}" ]; then
        ENV_ARGS+=(--env "$name=${!name}")
    fi
done

# -n：总是起新实例；用 open 启动，App 自己是 TCC 的责任进程，不挂在终端下面
open -n "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" "$DEV_APP" --args "${APP_ARGS[@]+"${APP_ARGS[@]}"}"

for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(pgrep -f "$DEV_BINARY" | head -1 || true)"
    [ -n "$pid" ] && break
    sleep 0.5
done
echo "Typefree Dev running (pid ${pid:-?}, signing: $SIGN_NOTE)"
echo "  App:    $DEV_APP"
echo "  Config: $HOME/.config/voicepolish-dev"
echo "  Log:    $HOME/Library/Logs/VoicePolish-dev.log"
echo "  Stop:   bash \"$MAC_DIR/scripts/dev_run.sh\" --stop"
