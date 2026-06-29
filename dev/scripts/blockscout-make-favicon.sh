#!/usr/bin/env bash
# 把方形品牌图渲染成完整 favicon 套件，输出到 dev/blockscout/assets/favicon/。
#
# 源文件优先级（从高到低）：
#   1. blockscout/assets/logo512.png  ← 业务方提供的高分辨率方形 PNG（首选）
#   2. blockscout/assets/icon.svg      ← 矢量兜底（librsvg 渲染）
# 哪个新用哪个；都存在就以 logo512.png 为准。
#
# 为什么必须本地预生成而不依赖 Blockscout entrypoint：
#   Blockscout frontend 容器启动时，entrypoint 的 download-assets.sh 会去 fetch
#   NEXT_PUBLIC_NETWORK_ICON 这个 URL 把图下载下来，再调内置 favicons-generator
#   生成全套 favicon。
#
#   反代模式下这个 URL 是 https://demo.example.com/assets/network/icon.svg：
#     - 容器从 docker 网络出去 → 走 host 的 eth0 → 公网 → AWS SG → 回到 host nginx
#     - 这条 hairpin 路径常见会被 AWS 安全组的"只允许特定 IP"规则挡掉
#     - 即便能通，frontend 自己启动时还没绑 :4000，nginx 反代过来也是 502
#   → download 失败 → favicon-generator 拿到空 buffer → 报 "Invalid image buffer"
#   → /app/public/favicon.ico 根本不生成 → 浏览器拿默认/空 favicon
#
#   解决：本地 ImageMagick 一次性预生成全套，docker-compose 把每个文件 mount 到
#   /app/public/<name>.png，绕开 entrypoint 的下载-生成路径，必然有效。
#
# 用法：
#   bash scripts/blockscout-make-favicon.sh         # 检测：缺文件或源文件比 favicon 新就生成
#   bash scripts/blockscout-make-favicon.sh --force # 无条件重新生成
set -euo pipefail

cd "$(dirname "$0")/.."

PNG_SRC=blockscout/assets/logo512.png
SVG_SRC=blockscout/assets/icon.svg
OUT=blockscout/assets/favicon
# 可选：现成的 .ico 文件（仅在用 SVG 源时启用，作为 SVG→ICO 16x16 渲染糊的兜底）。
# PNG 源时无视它，避免业务方换了高分辨率 PNG 但残留的旧 icon.ico 把它"劫持"了
# —— 实测踩过：上次只换 logo512.png 但 icon.ico 还在，结果 favicon.ico 一直是
# 旧 .ico 的拷贝。
ICO_SRC=blockscout/assets/icon.ico

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

# 检测是否需要重新生成：缺文件 / 源图 或 icon.ico 比任一 favicon 新 / --force
NEED=0
if [[ "$FORCE" == "1" ]]; then
  NEED=1
elif [[ ! -d "$OUT" ]]; then
  NEED=1
else
  for f in "${NEEDED[@]}"; do
    if [[ ! -f "$OUT/$f" ]]; then
      NEED=1
      break
    fi
    if [[ "$SRC" -nt "$OUT/$f" ]]; then
      NEED=1
      break
    fi
    # icon.ico 只在 SVG 源模式被用，所以只在那种情况下检查它的新旧
    if [[ "$SRC" == "$SVG_SRC" && -f "$ICO_SRC" && "$ICO_SRC" -nt "$OUT/$f" ]]; then
      NEED=1
      break
    fi
  done
fi

if [[ "$NEED" == "0" ]]; then
  echo "==> favicon 套件已就位且与 $SRC_NAME 同步，跳过生成"
  echo "    要强制重新生成：bash scripts/blockscout-make-favicon.sh --force"
  exit 0
fi

mkdir -p "$OUT"

# ImageMagick 镜像：dpokidov/imagemagick 自带 librsvg，SVG 输入开箱即用
IMAGE="${FAVICON_IMAGEMAGICK_IMAGE:-dpokidov/imagemagick:latest}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> 拉取 ImageMagick 镜像 ($IMAGE，首次约 200MB) ..."
  docker pull "$IMAGE"
fi

# 用当前 user 跑容器，避免生成的文件 owner 变成 root
USER_FLAG=()
if [[ "$(uname -s)" == "Linux" ]]; then
  USER_FLAG=(-u "$(id -u):$(id -g)")
fi

# 显式指定 entrypoint=magick，避开 dpokidov/imagemagick:latest 升到 IMv7 后
# 不同 tag 的 ENTRYPOINT 长得不一样的兼容问题（有的是 ["magick"]，有的是
# ["magick","convert"]，传 convert 会被当成输入文件名而 decode 失败）。
# IMv7 的 `magick` 命令直接吃后面的转换语法，跟旧 `convert` 用法一致。
run_im() {
  docker run --rm "${USER_FLAG[@]}" \
    --entrypoint magick \
    -v "$PWD/blockscout/assets:/w" \
    -w /w \
    "$IMAGE" "$@"
}

# IMv7 的 magick 比 IMv6 的 convert 严格：image operator（-resize 等）必须在
# 输入文件之后才有效。参数顺序统一改成：[settings] input [operators] output。
# -background 是 setting，可以在 input 前；-resize / -define 是 operator，必须在 input 后。
# -background none 对 PNG 输入是 no-op（已有 alpha），对 SVG 输入避免白底，两种源图都安全。
echo "==> 生成 PNG 套件 (16/32/48/96/180/192/512) ← $SRC_NAME"
for size_pair in "16:favicon-16x16" "32:favicon-32x32" "48:favicon-48x48" "96:favicon-96x96" \
                 "180:apple-touch-icon-180x180" "192:android-chrome-192x192" "512:android-chrome-512x512"; do
  size="${size_pair%%:*}"
  name="${size_pair##*:}"
  run_im -background none "$SRC_NAME" -resize "${size}x${size}" "favicon/${name}.png"
done

# PNG 源走 IM 重采样生成 .ico（高分辨率源，重采样质量够用）。
# SVG 源时如果同目录提供了现成 .ico 才用它（SVG→ICO 16x16 容易糊的兜底）。
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
