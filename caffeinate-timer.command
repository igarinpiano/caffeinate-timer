#!/bin/bash
# Copyright © 2026 Igarin. All rights reserved.

# ── 色定義（$'...' 形式で ESC を事前展開）───────────────
BOLD=$'\033[1m'
CYAN=$'\033[0;36m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

# ── Ctrl+C ハンドラ ─────────────────────────────────────
trap_handler() {
  printf '\n'
  printf '%s\n' "${YELLOW}⚠️  中断されました。スリープ防止を解除します。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 0
}
trap trap_handler INT

# ── ヘッダー ────────────────────────────────────────────
clear
printf '%s\n' "${BOLD}${CYAN}☕  Caffeinate タイマー${RESET}"
printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
printf '\n'
printf '%s\n' "${BOLD}時間を入力してください。${RESET}"
printf '%s\n' "例:"
printf '%s\n' "  ${CYAN}90${RESET}           → 90分"
printf '%s\n' "  ${CYAN}1:30:00${RESET}      → 1時間30分0秒"
printf '%s\n' "  ${CYAN}1:30${RESET}         → 1分30秒"
printf '%s\n' "  ${CYAN}1h / 1hour${RESET}   → 1時間"
printf '%s\n' "  ${CYAN}45m / 45min${RESET}  → 45分"
printf '%s\n' "  ${CYAN}20s / 20sec${RESET}  → 20秒"
printf '%s\n' "  ${CYAN}1h30m20s${RESET}     → 1時間30分20秒"
printf '%s\n' "  ${CYAN}1h20s${RESET}        → 1時間20秒"
printf '%s\n' "  ${CYAN}1.5h${RESET}         → 1時間30分"
printf '\n'
read -r -p "入力: " input
printf '\n'

# ── 前処理①：全角→半角変換（sed s コマンドで1文字ずつ）─
# ※ sed の y コマンドはバイト長一致が必要なため、
#    UTF-8 マルチバイト文字（全角3バイト vs ASCII1バイト）
#    には使用不可。同等の1文字単位変換を s コマンドで実現。
# 対象：全角数字／コロン／小数点／単位 h m s／全角スペース
input=$(printf '%s' "$input" | sed \
  -e 's/０/0/g' -e 's/１/1/g' -e 's/２/2/g' -e 's/３/3/g' -e 's/４/4/g' \
  -e 's/５/5/g' -e 's/６/6/g' -e 's/７/7/g' -e 's/８/8/g' -e 's/９/9/g' \
  -e 's/：/:/g' -e 's/．/./g' \
  -e 's/ｈ/h/g' -e 's/ｍ/m/g' -e 's/ｓ/s/g' \
  -e 's/　/ /g' \
)

# ── 前処理②：半角スペース除去・小文字化（Bash 3.2 互換）─
input="${input// /}"
input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

# ── 単位を正規化（長い表記 → 短い表記）─────────────────
input=$(printf '%s' "$input" | sed -E \
  -e 's/hours?/h/g'   \
  -e 's/hrs?/h/g'     \
  -e 's/minutes?/m/g' \
  -e 's/mins?/m/g'    \
  -e 's/seconds?/s/g' \
  -e 's/secs?/s/g'    \
)

# ── 入力文字数チェック ───────────────────────────────────
# 正規化後16文字を超えると時間単位×乗数の乗算がint64を超える
# （例: 16桁×3600は桁あふれし、0秒チェックでも補足できない正のゴミ値を生じる）
if [ ${#input} -gt 16 ]; then
  printf '%s\n' "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
  printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

seconds=0

# ── パターンマッチング ───────────────────────────────────

# 1) 整数のみ → 分
if [[ "$input" =~ ^([0-9]+)$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 ))

# 2) 小数のみ → 分（例: 1.5 → 90秒）
elif [[ "$input" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  ip=${BASH_REMATCH[1]}; dp=${BASH_REMATCH[2]:0:9}; dl=${#dp}
  seconds=$(( (10#$ip * (10**dl) + 10#$dp) * 60 / (10**dl) ))

# 3) X:Y → 分:秒
elif [[ "$input" =~ ^([0-9]+):([0-9]+)$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))

# 4) X:Y:Z → 時:分:秒
elif [[ "$input" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))

# 5) 小数h → 時間（例: 1.5h）
elif [[ "$input" =~ ^([0-9]+)\.([0-9]+)h$ ]]; then
  ip=${BASH_REMATCH[1]}; dp=${BASH_REMATCH[2]:0:9}; dl=${#dp}
  seconds=$(( (10#$ip * (10**dl) + 10#$dp) * 3600 / (10**dl) ))

# 6) XhYmZs（最も長いものを先に）
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))

# 7) XhYm
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 ))

# 8) XhYs（分なし）
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} ))

# 9) XmYs
elif [[ "$input" =~ ^([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))

# 10) Xh のみ
elif [[ "$input" =~ ^([0-9]+)h$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 ))

# 11) Xm のみ
elif [[ "$input" =~ ^([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 ))

# 12) Xs のみ
elif [[ "$input" =~ ^([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} ))

# 13) パース失敗
else
  printf '%s\n' "${RED}❌ 入力形式がわかりませんでした。${RESET}"
  printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 0秒チェック ─────────────────────────────────────────
if [ "$seconds" -le 0 ]; then
  printf '%s\n' "${RED}❌ 0秒以下の値は設定できません。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 最大秒数チェック ─────────────────────────────────────
# int64算術およびdate -r のエポック加算がオーバーフローしない上限
_MAX_SECONDS=9000000000000000000
if [ "$seconds" -gt "$_MAX_SECONDS" ]; then
  printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 時刻・継続時間の表示 ─────────────────────────────────
now_time=$(date "+%Y-%m-%d %H:%M:%S")
end_epoch=$(( $(date +%s) + seconds ))
end_time=$(date -r "$end_epoch" "+%Y-%m-%d %H:%M:%S")

H=$(( seconds / 3600 ))
M=$(( (seconds % 3600) / 60 ))
S=$(( seconds % 60 ))
duration_str=$(printf "%02d:%02d:%02d" $H $M $S)

printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
printf '%s\n' "  ${BOLD}現在時刻:${RESET} ${GREEN}${now_time}${RESET}"
printf '%s\n' "  ${BOLD}終了時刻:${RESET} ${GREEN}${end_time}${RESET}"
printf '%s\n' "  ${BOLD}継続時間:${RESET} ${CYAN}${duration_str}${RESET}  (${seconds}秒)"
printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
printf '\n'
printf '%s\n' "${YELLOW}💡 スリープを防止しています... (Ctrl+C で中断)${RESET}"
printf '\n'

# ── Caffeinate 実行 ─────────────────────────────────────
caffeinate -u -d -t "$seconds"

# ── 正常終了 ─────────────────────────────────────────────
printf '%s\n' "${GREEN}✅ 終了しました。 ($(date "+%H:%M:%S"))${RESET}"
printf '\n'
read -r -p "Enterで閉じる..." _
