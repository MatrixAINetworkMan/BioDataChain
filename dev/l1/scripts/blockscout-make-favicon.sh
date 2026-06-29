#!/usr/bin/env bash
# 把方形品牌图渲染成完整 favicon 套件，输出到 dev/l1/blockscout/assets/favicon/。
#
# 跟 dev/scripts/blockscout-make-favicon.sh（L2 版本）逻辑完全一致，
# 路径前缀换成 dev/l1/blockscout/。
#
# 源文件优先级（从高到低）：
#   1. blockscout/assets/logo512.png   ← 业务方提供的高分辨率方形 PNG（首选）
#   2. blockscout/assets/icon.svg      ← 矢量兜底（librsvg 渲染）
#
# 为什么必须本地预生成而不依赖 Blockscout entrypoint：
#   Blockscout frontend 容器启动时会去 fetch NEXT_PUBLIC_NETWORK_ICON 这个 URL
#   再生成 favicon。反代模式下这个 URL 是 https://devl1.example.com/assets/network/icon.svg，
#   容器自己 hairpin 出去再回来很容易超时 / 拿到 502 → 生成失败 → 浏览器拿默认 logo。
#   本地预生成 + bind mount 进容器，绕开 entrypoint 那条 fetch-then-generate 路径。
#
# 用法：
#   bash scripts/blockscout-make-favicon.sh         # 智能：缺/旧才生成
#   bash scripts/blockscout-make-favicon.sh --force # 无条件重新生成
set -euo pipefail

cd "$(dirname "$0")/.."

PNG_SRC=blockscout/assets/logo512.png
SVG_SRC=blockscout/assets/icon.svg
OUT=blockscout/assets/favicon
ICO_SRC=blockscout/assets/man.ico    # SVG 源时的 .ico 兜底（PNG 源时无视）

# 选源：PNG 优先，SVG 兜底
if [[ -f "$PNG_SRC" ]]; then
  SRC="$PNG_SRC"
  SRC_NAME="$(basename "$PNG_SRC")"
elif [[ -f "$SVG_SRC" ]]; then
  SRC="$SVG_SRC"
  SRC_NAME="$(basename "$SVG_SRC")"
else
  echo "❌ 既没有 $PNG_SRC 也没有 $SVG_SRC" >&2
  exit 1
fi
echo "==> 使用源图：$SRC"

# Blockscout v9 frontend HTML <head> 实际引用的 favicon 文件名
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

# 检测是否需要重新生成
NEED=0
if [[ "$FORCE" == "1" ]]; then
  NEED=1
elif [[ ! -d "$OUT" ]]; then
  NEED=1
else
  for f in "${NEEDED[@]}"; do
    if [[ ! -f "$OUT/$f" ]]; then NEED=1; break; fi
    if [[ "$SRC" -nt "$OUT/$f" ]]; then NEED=1; break; fi
    if [[ "$SRC" == "$SVG_SRC" && -f "$ICO_SRC" && "$ICO_SRC" -nt "$OUT/$f" ]]; then
      NEED=1; break
    fi
  done
fi

if [[ "$NEED" == "0" ]]; then
  echo "==> favicon 套件已就位且与 $SRC_NAME 同步，跳过生成"
  echo "    要强制重新生成：bash scripts/blockscout-make-favicon.sh --force"
  exit 0
fi

mkdir -p "$OUT"

IMAGE="${FAVICON_IMAGEMAGICK_IMAGE:-dpokidov/imagemagick:latest}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> 拉取 ImageMagick 镜像 ($IMAGE，首次约 200MB) ..."
  docker pull "$IMAGE"
fi

USER_FLAG=()
if [[ "$(uname -s)" == "Linux" ]]; then
  USER_FLAG=(-u "$(id -u):$(id -g)")
fi

# IMv7 magick 兼容：显式指定 entrypoint，参数顺序 [settings] input [operators] output
run_im() {
  docker run --rm "${USER_FLAG[@]}" \
    --entrypoint magick \
    -v "$PWD/blockscout/assets:/w" \
    -w /w \
    "$IMAGE" "$@"
}

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
echo ""
echo "下一步：make blockscout-up（已挂载这些文件到容器 /app/public/）"
