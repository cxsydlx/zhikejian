#!/bin/bash
# 真机连拍：点一次 → 连续抓 N 帧（一条 hdc shell 里串起来，省掉每帧的往返还）
# 用法: bash _cap.sh <设备> <输出目录> <帧数> [点击x] [点击y]
# 需要 Git Bash 的 sed/grep 等工具。⚠️ 不要写死某人的本机绝对路径
#    （脚本随仓库公开会泄露用户名与目录结构），按需改成自己的。
export PATH="/usr/bin:/bin:$PATH"
export MSYS_NO_PATHCONV=1
HDC="/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
DEV="$1"; OUT="$2"; N="$3"; CX="${4:-1400}"; CY="${5:-507}"
mkdir -p "$OUT"
rm -f "$OUT"/s*.jpeg

# 采集：源路径 /data/local/tmp/... 会被 Git Bash 改写，必须靠 MSYS_NO_PATHCONV 保护，
# 所以这个脚本**整体**都设着它。下面的 recv 因此不能用绝对目标路径（会被当 POSIX 路径解析），
# 只能 cd 过去用相对文件名。
CMD="uitest uiInput click $CX $CY"
for i in $(seq 0 $((N-1))); do
  CMD="$CMD ; snapshot_display -f /data/local/tmp/cap_$i.jpeg"
done

"$HDC" -t "$DEV" shell "$CMD" >/dev/null 2>&1

cd "$OUT" || exit 1
for i in $(seq 0 $((N-1))); do
  "$HDC" -t "$DEV" file recv /data/local/tmp/cap_$i.jpeg "s$i.jpeg" >/dev/null 2>&1
done
ls s*.jpeg 2>/dev/null | wc -l
