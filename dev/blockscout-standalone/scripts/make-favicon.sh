#!/usr/bin/env bash
# =============================================================================
# Blockscout standalone —— 从方形品牌图渲染整套 favicon
#
# 这是 dev/scripts/blockscout-make-favicon.sh 的 standalone 版本，路径基准从
# 链仓库的 dev/blockscout/assets/ 改成 standalone 自己的 assets/。
#
# 为什么 standalone 需要自带这一份：
#   1. standalone 目录可以独立 clone 出去给运维用，不依赖整个链仓库
#   2. install.sh 在 docker compose up 前会自动调用本脚本兜底生成 favicon，
#      省去运维"为啥 frontend 起不来报 not a directory"的踩坑
#   3. docker-compose.yml 把 9 个 favicon 文件 bind-mount 到 /app/public/，
#      只要 host 这边缺任意一个，docker 就会自动 mkdir 出同名空目录，再 mount
#      到容器里本来是 file 的位置 → 报 not a directory（坑过一次，加这个脚本兜底）
#
# 源文件优先级（从高到低）：
#   1. assets/logo512.png  ← 业务方提供的高分辨率方形 PNG（首选）
#   2. assets/icon.svg     ← 矢量兜底（librsvg 渲染）
#
# 用法：
#   bash scripts/make-favicon.sh           # 检测：缺文件 / 源比产物新 → 生成
#   bash scripts/make-favicon.sh --force   # 无条件重新生成
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."   # standalone 根目录

PNG_SRC=assets/logo512.png
SVG_SRC=assets/icon.svg
OUT=assets/favicon
# 可选：现成的 .ico 文件（仅在 SVG 源时启用，作为 SVG→ICO 16x16 渲染糊的兜底）。
# PNG 源时无视它，避免业务方换了高分辨率 PNG 但残留的旧 icon.ico 把它"劫持"了。
ICO_SRC=assets/icon.ico

if [[ -f "$PNG_SRC" ]]; then
  SRC="$PNG_SRC"
  SRC_NAME="$(basename "$PNG_SRC")"
elif [[ -f "$SVG_SRC" ]]; then
  SRC="$SVG_SRC"
  SRC_NAME="$(basename "$SVG_SRC")"
else
  echo "❌ 既没有 $PNG_SRC 也没有 $SVG_SRC" >&2
  echo "   先放一张方形品牌图（PNG ≥ 512x512 或 SVG）进 assets/，再跑本脚本。" >&2
  exit 1
fi
echo "==> 使用源图：$SRC"

# Blockscout v9 frontend 的 HTML <head> 实际引用的 favicon 文件名
# （curl http://frontend:3000/ 看 <link rel="icon"> 抓出来的，2026-05-14 实测）：
#   /assets/favicon/favicon-16x16.png
#   /assets/favicon/favicon-32x32.png
#   /assets/favicon/favicon-48x48.png         ← 注意 48 不是 96
#   /assets/favicon/favicon.ico
#   /assets/favicon/apple-touch-icon-180x180.png  ← 文件名带尺寸后缀
#   /assets/favicon/android-chrome-192x192.png
# 顺便保留 favicon-96x96.png + 512x512 给 PWA / 老浏览器兜底
NEEDED=(
  favicon.ico
  favicon-16x16.png
  favicon-32x32.png
  favicon-48x48.png
  favicon-96x96.png
  apple-touch-icon-180x180.png
  android-chrome-192x192.png
  android-chrome-512x512.png
)

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

NEED=0
if [[ "$FORCE" == "1" ]]; then
  NEED=1
elif [[ ! -d "$OUT" ]]; then
  NEED=1
else
  for f in "${NEEDED[@]}"; do
    if [[ ! -f "$OUT/$f" ]]; then NEED=1; break; fi
    # docker bind-mount 失败时会留一个同名空目录，这里也判一下
    if [[ -d "$OUT/$f" ]]; then NEED=1; break; fi
    if [[ "$SRC" -nt "$OUT/$f" ]]; then NEED=1; break; fi
    if [[ "$SRC" == "$SVG_SRC" && -f "$ICO_SRC" && "$ICO_SRC" -nt "$OUT/$f" ]]; then
      NEED=1; break
    fi
  done
fi

if [[ "$NEED" == "0" ]]; then
  echo "==> favicon 套件已就位且与 $SRC_NAME 同步，跳过生成"
  echo "    要强制重新生成：bash scripts/make-favicon.sh --force"
  exit 0
fi

# 清掉可能由 docker bind-mount 自动创建的"伪目录"（src 路径不存在时 docker 默认 mkdir 一个空 dir）
for f in "${NEEDED[@]}"; do
  if [[ -d "$OUT/$f" ]]; then
    echo "==> 清理误创的空目录 $OUT/$f"
    rmdir "$OUT/$f" 2>/dev/null || rm -rf "$OUT/$f"
  fi
done
mkdir -p "$OUT"

# ImageMagick 镜像：dpokidov/imagemagick 自带 librsvg，SVG 输入开箱即用
IMAGE="${FAVICON_IMAGEMAGICK_IMAGE:-dpokidov/imagemagick:latest}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> 拉取 ImageMagick 镜像 ($IMAGE，首次约 200MB) ..."
  docker pull "$IMAGE"
fi

USER_FLAG=()
if [[ "$(uname -s)" == "Linux" ]]; then
  USER_FLAG=(-u "$(id -u):$(id -g)")
fi

# 显式指定 entrypoint=magick，避开 dpokidov/imagemagick:latest 升到 IMv7 后
# 不同 tag 的 ENTRYPOINT 长得不一样的兼容问题（有的是 ["magick"]，有的是
# ["magick","convert"]，传 convert 会被当成输入文件名而 decode 失败）。
run_im() {
  docker run --rm "${USER_FLAG[@]}" \
    --entrypoint magick \
    -v "$PWD/assets:/w" \
    -w /w \
    "$IMAGE" "$@"
}

# IMv7 magick 比 IMv6 convert 严格：image operator（-resize 等）必须在输入文件之后才有效。
# 参数顺序：[settings] input [operators] output
# -background 是 setting，可在 input 前；-resize / -define 是 operator，必须在 input 后。
# -background none 对 PNG 输入是 no-op（已有 alpha），对 SVG 输入避免白底，两种源都安全。
echo "==> 生成 PNG 套件 (16/32/48/96/180/192/512) ← $SRC_NAME"
for size_pair in "16:favicon-16x16" "32:favicon-32x32" "48:favicon-48x48" "96:favicon-96x96" \
                 "180:apple-touch-icon-180x180" "192:android-chrome-192x192" "512:android-chrome-512x512"; do
  size="${size_pair%%:*}"
  name="${size_pair##*:}"
  run_im -background none "$SRC_NAME" -resize "${size}x${size}" "favicon/${name}.png"
done

USE_ICO_SRC=0
if [[ -f "$ICO_SRC" && "$SRC" == "$SVG_SRC" ]]; then
  USE_ICO_SRC=1
fi

if [[ "$USE_ICO_SRC" == "1" ]]; then
  echo "==> 直接复制 $ICO_SRC → $OUT/favicon.ico (SVG 源时启用现成 .ico 兜底)"
  cp "$ICO_SRC" "$OUT/favicon.ico"
else
  echo "==> 生成 favicon.ico (多尺寸 16/32/48 嵌入一个 .ico) ← $SRC_NAME"
  run_im -background none "$SRC_NAME" -define icon:auto-resize=16,32,48 favicon/favicon.ico
fi

echo ""
echo "✅ favicon 套件生成完毕："
ls -la "$OUT"
