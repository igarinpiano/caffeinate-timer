#!/bin/bash
# Copyright © 2026 Igarin. All rights reserved.

# ── OS 判定 ─────────────────────────────────────────────────
OS="$(uname -s)"   # Darwin = macOS / Linux = Linux

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
printf '%s\n' "  ${CYAN}1d / 1day${RESET}    → 1日"
printf '%s\n' "  ${CYAN}1h / 1hour${RESET}   → 1時間"
printf '%s\n' "  ${CYAN}45m / 45min${RESET}  → 45分"
printf '%s\n' "  ${CYAN}20s / 20sec${RESET}  → 20秒"
printf '%s\n' "  ${CYAN}1h30m20s${RESET}     → 1時間30分20秒"
printf '%s\n' "  ${CYAN}1h20s${RESET}        → 1時間20秒"
printf '%s\n' "  ${CYAN}1.5h${RESET}         → 1時間30分"
printf '%s\n' "  ${CYAN}1d3h30m${RESET}      → 1日3時間30分"
printf '%s\n' "  ${CYAN}2mo / 2month${RESET} → 2ヶ月"
printf '%s\n' "  ${CYAN}1y / 1year${RESET}   → 1年"
printf '%s\n' "  ${CYAN}1y2mo${RESET}        → 1年2ヶ月"
printf '%s\n' "  ${CYAN}1y2mo3h30m${RESET}   → 1年2ヶ月3時間30分"
printf '\n'
read -r -p "入力: " input
printf '\n'

# ── 前処理①：全角→半角変換（sed s コマンドで1文字ずつ）─
# ※ sed の y コマンドはバイト長一致が必要なため、
#    UTF-8 マルチバイト文字（全角3バイト vs ASCII1バイト）
#    には使用不可。同等の1文字単位変換を s コマンドで実現。
# 対象：全角数字／コロン／小数点／単位 h m s d y o／全角スペース
input=$(printf '%s' "$input" | sed \
  -e 's/０/0/g' -e 's/１/1/g' -e 's/２/2/g' -e 's/３/3/g' -e 's/４/4/g' \
  -e 's/５/5/g' -e 's/６/6/g' -e 's/７/7/g' -e 's/８/8/g' -e 's/９/9/g' \
  -e 's/：/:/g' -e 's/．/./g' \
  -e 's/ｈ/h/g' -e 's/ｍ/m/g' -e 's/ｓ/s/g' -e 's/ｄ/d/g' -e 's/ｙ/y/g' -e 's/ｏ/o/g' \
  -e 's/　/ /g' \
)

# ── 前処理②：半角スペース除去・小文字化（Bash 3.2 互換）─
input="${input// /}"
input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

# ── 単位を正規化（長い表記 → 短い表記）─────────────────
# ※ months / years を先に正規化して minutes / seconds / days と競合しないようにする
input=$(printf '%s' "$input" | sed -E \
  -e 's/months?/mo/g'  \
  -e 's/years?/y/g'    \
  -e 's/yrs?/y/g'      \
  -e 's/hours?/h/g'    \
  -e 's/hrs?/h/g'      \
  -e 's/minutes?/m/g'  \
  -e 's/mins?/m/g'     \
  -e 's/seconds?/s/g'  \
  -e 's/secs?/s/g'     \
  -e 's/days?/d/g'     \
)

# ── 年・月コンポーネントの抽出 ──────────────────────────────────────
# カレンダー演算が必要なため、パターンマッチの前に y / mo を分離する。
# 数字は 10# プレフィックスで8進数誤認を防止。
# 桁数を4桁以内に制限し date コマンドへの過大入力を防ぐ。
year_val=0
month_val=0

if [[ "$input" =~ ^([0-9]+)y(.*)$ ]]; then
  if [ "${#BASH_REMATCH[1]}" -gt 4 ]; then
    printf '%s\n' "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
    printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi
  year_val=$(( 10#${BASH_REMATCH[1]} ))
  input="${BASH_REMATCH[2]}"
fi

if [[ "$input" =~ ^([0-9]+)mo(.*)$ ]]; then
  if [ "${#BASH_REMATCH[1]}" -gt 4 ]; then
    printf '%s\n' "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
    printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi
  month_val=$(( 10#${BASH_REMATCH[1]} ))
  input="${BASH_REMATCH[2]}"
fi

# ── 入力文字数チェック ───────────────────────────────────
# 正規化後16文字を超えると時間単位×乗数の乗算がint64を超える
# （例: 16桁×3600は桁あふれし、0秒チェックでも補足できない正のゴミ値を生じる）
# ※ d 単位（×86400）の単体入力は別途14桁以内チェックを追加（後述）
if [ "${#input}" -gt 16 ]; then
  printf '%s\n' "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
  printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

seconds=0

# ── パターンマッチング ───────────────────────────────────

# 0) 年・月のみ（d/h/m/s なし）
if [[ -z "$input" ]] && (( year_val > 0 || month_val > 0 )); then
  : # d/h/m/s 分は 0 秒として扱う（年・月のみ指定）

# 1) 整数のみ → 分
elif [[ "$input" =~ ^([0-9]+)$ ]]; then
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

# 6) XdYhZmWs（最も長いものを先に）
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)h([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))

# 7) XdYhZm
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)h([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 ))

# 8) XdYhZs（分なし）
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)h([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} ))

# 9) XdYmZs（時なし）
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))

# 10) XdYh
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)h$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 ))

# 11) XdYm
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 60 ))

# 12) XdYs（時分なし）
elif [[ "$input" =~ ^([0-9]+)d([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} ))

# 13) Xd のみ
# ※ 16文字制限内でも15桁×86400はint64を超えるため14桁以内に制限する
elif [[ "$input" =~ ^([0-9]+)d$ ]]; then
  d_val=${BASH_REMATCH[1]}
  if [ "${#d_val}" -gt 14 ]; then
    printf '%s\n' "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
    printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi
  seconds=$(( 10#${d_val} * 86400 ))

# 14) XhYmZs
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))

# 15) XhYm
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 ))

# 16) XhYs（分なし）
elif [[ "$input" =~ ^([0-9]+)h([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} ))

# 17) XmYs
elif [[ "$input" =~ ^([0-9]+)m([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))

# 18) Xh のみ
elif [[ "$input" =~ ^([0-9]+)h$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 3600 ))

# 19) Xm のみ
elif [[ "$input" =~ ^([0-9]+)m$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 60 ))

# 20) Xs のみ
elif [[ "$input" =~ ^([0-9]+)s$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} ))

# 21) パース失敗
else
  printf '%s\n' "${RED}❌ 入力形式がわかりませんでした。${RESET}"
  printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 年・月のカレンダー演算（秒への変換）────────────────────────────
# macOS: BSD date -v で月・年を加算。Linux: GNU date -d "@EPOCH +N years +M months"。
# sub_seconds は d/h/m/s 分のみの秒数（表示用に保持）。
# _now_epoch を先頭で一度だけ取得し、以降の全時刻計算の基点として使い回す。
# これにより、カレンダー演算・表示・最大秒数チェックの各ステップ間で
# システム時計が1秒進むことによるドリフトを防ぐ。
sub_seconds=$seconds
_now_epoch=$(date +%s)
if [ "$year_val" -gt 0 ] || [ "$month_val" -gt 0 ]; then
  if [[ "$OS" == "Darwin" ]]; then
    if [ "$year_val" -gt 0 ] && [ "$month_val" -gt 0 ]; then
      _end_cal=$(date -r "$_now_epoch" -v "+${year_val}y" -v "+${month_val}m" +%s) || {
        printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
        printf '\n'
        read -r -p "Enterで閉じる..." _
        exit 1
      }
    elif [ "$year_val" -gt 0 ]; then
      _end_cal=$(date -r "$_now_epoch" -v "+${year_val}y" +%s) || {
        printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
        printf '\n'
        read -r -p "Enterで閉じる..." _
        exit 1
      }
    else
      _end_cal=$(date -r "$_now_epoch" -v "+${month_val}m" +%s) || {
        printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
        printf '\n'
        read -r -p "Enterで閉じる..." _
        exit 1
      }
    fi
  else
    _date_str="@${_now_epoch}"
    [ "$year_val" -gt 0 ] && _date_str="$_date_str +${year_val} years"
    [ "$month_val" -gt 0 ] && _date_str="$_date_str +${month_val} months"
    _end_cal=$(date -d "$_date_str" +%s) || {
      printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
      printf '\n'
      read -r -p "Enterで閉じる..." _
      exit 1
    }
  fi
  seconds=$(( _end_cal - _now_epoch + sub_seconds ))
fi

# ── 0秒チェック ─────────────────────────────────────────
if [ "$seconds" -le 0 ]; then
  printf '%s\n' "${RED}❌ 0秒以下の値は設定できません。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 最大秒数チェック ─────────────────────────────────────
# end_epoch = now + seconds が date コマンドの処理可能な上限(16桁エポック)を超えないよう
# 実行時刻から動的に算出する
_MAX_SECONDS=$(( 9999999999999999 - _now_epoch ))
if [ "$seconds" -gt "$_MAX_SECONDS" ]; then
  printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 時刻・継続時間の表示 ─────────────────────────────────
# date -r はmacOS（BSD date）専用。Linuxでは date -d @EPOCH を使用。
if [[ "$OS" == "Darwin" ]]; then
  now_time=$(date -r "$_now_epoch" "+%Y-%m-%d %H:%M:%S")
else
  now_time=$(date -d "@${_now_epoch}" "+%Y-%m-%d %H:%M:%S")
fi
end_epoch=$(( _now_epoch + seconds ))

# date -r はmacOS（BSD date）専用。Linuxでは date -d @EPOCH を使用。
if [[ "$OS" == "Darwin" ]]; then
  end_time=$(date -r "$end_epoch" "+%Y-%m-%d %H:%M:%S")
else
  end_time=$(date -d "@${end_epoch}" "+%Y-%m-%d %H:%M:%S")
fi

_disp_S=$(( sub_seconds % 60 ))
_disp_M=$(( (sub_seconds % 3600) / 60 ))
_disp_H=$(( (sub_seconds % 86400) / 3600 ))
_disp_D=$(( sub_seconds / 86400 ))
if [ "$year_val" -gt 0 ]; then
  duration_str=$(printf "%02d:%02d:%02d:%02d:%02d:%02d" "$year_val" "$month_val" "$_disp_D" "$_disp_H" "$_disp_M" "$_disp_S")
elif [ "$month_val" -gt 0 ]; then
  duration_str=$(printf "%02d:%02d:%02d:%02d:%02d" "$month_val" "$_disp_D" "$_disp_H" "$_disp_M" "$_disp_S")
elif [ "$sub_seconds" -ge 86400 ]; then
  duration_str=$(printf "%02d:%02d:%02d:%02d" "$_disp_D" "$_disp_H" "$_disp_M" "$_disp_S")
else
  duration_str=$(printf "%02d:%02d:%02d" "$_disp_H" "$_disp_M" "$_disp_S")
fi

printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
printf '%s\n' "  ${BOLD}現在時刻:${RESET} ${GREEN}${now_time}${RESET}"
printf '%s\n' "  ${BOLD}終了時刻:${RESET} ${GREEN}${end_time}${RESET}"
printf '%s\n' "  ${BOLD}継続時間:${RESET} ${CYAN}${duration_str}${RESET}  (${seconds}秒)"
printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
printf '\n'
printf '%s\n' "${YELLOW}💡 スリープを防止しています... (Ctrl+C で中断)${RESET}"
printf '\n'

# ── Caffeinate 実行 ─────────────────────────────────────
# macOS: caffeinate（標準搭載）
# Linux: systemd-inhibit（systemd 環境で標準搭載）
if [[ "$OS" == "Darwin" ]]; then
  caffeinate -u -d -t "$seconds"
else
  # systemd-inhibit が存在するか確認
  if ! command -v systemd-inhibit &>/dev/null; then
    printf '%s\n' "${YELLOW}⚠️  systemd-inhibit が見つかりません。スリープ防止機能は使えないため、タイマーとしてのみ続行します。${RESET}"
    printf '\n'
    sleep "$seconds"
  elif ! systemd-inhibit \
    --what=sleep:idle \
    --who="Caffeinate Timer" \
    --why="User requested caffeinate timer" \
    --mode=block \
    sleep "$seconds" 2>/dev/null; then
    printf '%s\n' "${YELLOW}⚠️  スリープ防止の実行に失敗しました。この環境では権限がない可能性があります。${RESET}"
    printf '%s\n' "   タイマーとしてのみ続行します..."
    printf '\n'
    sleep "$seconds"
  fi
fi

# ── 正常終了 ─────────────────────────────────────────────
printf '%s\n' "${GREEN}✅ 終了しました。 ($(date "+%H:%M:%S"))${RESET}"
printf '\n'
read -r -p "Enterで閉じる..." _
