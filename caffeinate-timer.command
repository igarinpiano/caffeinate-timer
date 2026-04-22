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

# ── バージョン・アップデート設定 ─────────────────────────
CURRENT_VERSION="v1.3.3"
_CT_VERSIONS_URL="https://raw.githubusercontent.com/igarinpiano/caffeinate-timer/main/versions.txt"
_CT_RELEASES_BASE="https://github.com/igarinpiano/caffeinate-timer/releases/download"
_CT_SCRIPT_FILENAME="caffeinate-timer.command"

# 自分自身のパスを解決（シンボリックリンク追跡、Bash 3.2 互換）
# realpath は macOS 12.3 以降で標準搭載。それ以前は手動でディレクトリ + basename から構成する。
if command -v realpath &>/dev/null; then
  _CT_SCRIPT_PATH="$(realpath "$0")"
else
  _CT_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
fi

# ── アップデート: バージョン文字列バリデーション ──────────
# v + 数字.数字.数字 のみ許可。コマンドインジェクション防止のため
# URL 組み立てに使用する前に必ず通す。
_ct_validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ── アップデート: versions.txt 取得 ──────────────────────
# curl のみ使用（macOS 標準搭載）。
# --proto '=https' で HTTPS のみ許可（HTTP へのダウングレード防止）。
# --max-redirs 5 でリダイレクトループを防止。
# 取得内容が空の場合は失敗扱い。
_ct_fetch_versions() {
  local _content
  _content=$(curl -fsSL \
    --proto '=https' \
    --max-time 15 \
    --max-redirs 5 \
    "$_CT_VERSIONS_URL" 2>/dev/null) || return 1
  [ -n "$_content" ] || return 1
  printf '%s' "$_content" | tr -d '\r'
}

# ── アップデート: ダウンロード・自己置換 ─────────────────
# 処理順: tmpファイル作成 → DL → 非空チェック → shebang確認
#         → 実行権限付与 → アトミック mv → exec で再起動
# 各ステップ失敗時は tmp を削除して中断（スクリプト本体は変更されない）。
_ct_download_replace() {
  local _version="$1"

  # 再バリデーション（念のため）
  _ct_validate_version "$_version" || {
    printf '%s\n' "${RED}❌ 不正なバージョン文字列です。アップデートを中止します。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }

  # URL はバリデーション済みバージョン文字列からのみ構成する
  local _url="${_CT_RELEASES_BASE}/${_version}/${_CT_SCRIPT_FILENAME}"

  # 一時ファイル作成
  # スクリプト本体と同一ディレクトリへの作成を優先し、mv のアトミック性を保証する。
  # ディレクトリへの書き込みが不可の場合のみ /tmp にフォールバックする。
  local _tmp
  local _script_dir
  _script_dir="$(dirname "$_CT_SCRIPT_PATH")"
  if ! _tmp=$(mktemp "${_script_dir}/.ct-update.XXXXXX" 2>/dev/null); then
    _tmp=$(mktemp /tmp/caffeinate-timer.XXXXXX) || {
      printf '%s\n' "${RED}❌ 一時ファイルの作成に失敗しました。ディスクの空き容量を確認してください。${RESET}"
      printf '\n'
      read -r -p "Enterで閉じる..." _
      exit 1
    }
  fi

  printf '%s\n' "  ${BOLD}${_version}${RESET} をダウンロードしています..."

  curl -fL \
    --progress-bar \
    --proto '=https' \
    --max-time 60 \
    --max-redirs 5 \
    "$_url" -o "$_tmp"
  local _curl_exit=$?

  printf '\n'

  if [ "$_curl_exit" -ne 0 ]; then
    rm -f "$_tmp"
    printf '%s\n' "${RED}❌ ダウンロードに失敗しました。（curl 終了コード: ${_curl_exit}）${RESET}"
    printf '%s\n' "  ・ネットワーク接続を確認してください。"
    printf '%s\n' "  ・バージョン ${_version} がリリースに存在しない可能性があります。"
    printf '%s\n' "  手動DL: ${_CT_RELEASES_BASE}/${_version}/${_CT_SCRIPT_FILENAME}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi

  # 空ファイルチェック
  if [ ! -s "$_tmp" ]; then
    rm -f "$_tmp"
    printf '%s\n' "${RED}❌ ダウンロードしたファイルが空です。アップデートを中止します。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi

  # shebang チェック（HTMLエラーページなど非スクリプトファイルの混入を防止）
  local _first_line
  IFS= read -r _first_line < "$_tmp"
  case "$_first_line" in
    '#!/bin/bash'|'#!/usr/bin/env bash'|'#!/bin/sh'|'#!/usr/bin/env sh') ;;
    *)
      rm -f "$_tmp"
      printf '%s\n' "${RED}❌ ダウンロードしたファイルの形式が不正です。アップデートを中止します。${RESET}"
      printf '%s\n' "  （予期しない内容: ${_first_line:0:60}）"
      printf '\n'
      read -r -p "Enterで閉じる..." _
      exit 1
      ;;
  esac

  # 元ファイルのパーミッションを取得し、新ファイルに引き継ぐ
  # stat が失敗した場合は 755 をデフォルトとする
  local _orig_perms
  _orig_perms=$(stat -f "%A" "$_CT_SCRIPT_PATH" 2>/dev/null) || _orig_perms="755"
  chmod "$_orig_perms" "$_tmp" || {
    rm -f "$_tmp"
    printf '%s\n' "${RED}❌ 実行権限の付与に失敗しました。アップデートを中止します。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }

  # 自己置換: 同一ファイルシステム内では mv（アトミック）を優先する。
  # /tmp フォールバック時など異なるファイルシステムでは mv が失敗するため、
  # cp + rm にフォールバックしてクロスデバイスエラーを回避する。
  if ! mv "$_tmp" "$_CT_SCRIPT_PATH" 2>/dev/null; then
    cp "$_tmp" "$_CT_SCRIPT_PATH" 2>/dev/null || {
      rm -f "$_tmp"
      printf '%s\n' "${RED}❌ ファイルの書き換えに失敗しました。アップデートを中止します。${RESET}"
      printf '%s\n' "  ・書き込み権限を確認してください。"
      printf '%s\n' "  ・スクリプトのパス: ${_CT_SCRIPT_PATH}"
      printf '\n'
      read -r -p "Enterで閉じる..." _
      exit 1
    }
    rm -f "$_tmp"
  fi

  printf '%s\n' "${GREEN}✅ バージョン ${_version} にアップデートしました。再起動します。${RESET}"
  sleep 1

  # exec で現プロセスを新バージョンに置き換えて再起動
  exec "$_CT_SCRIPT_PATH" || {
    printf '%s\n' "${RED}❌ 再起動に失敗しました。スクリプトを手動で再度起動してください。${RESET}"
    printf '%s\n' "  パス: ${_CT_SCRIPT_PATH}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }
}

# ── アップデート: 自動アップデート (/update) ─────────────
_ct_auto_update() {
  trap 'printf "\n${YELLOW}⚠️  アップデートをキャンセルしました。${RESET}\n\n"; read -r -p "Enterで閉じる..." _; exit 0' INT

  printf '\n'
  printf '%s\n' "バージョン情報を取得中..."

  local _vc
  _vc=$(_ct_fetch_versions) || {
    printf '%s\n' "${RED}❌ バージョン情報の取得に失敗しました。ネットワーク接続を確認してください。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }

  # 1行目の第1フィールドが最新バージョン
  local _latest
  _latest=$(printf '%s\n' "$_vc" | head -1 | awk '{print $1}')

  # バージョン文字列検証
  _ct_validate_version "$_latest" || {
    printf '%s\n' "${RED}❌ 取得したバージョン情報が不正です。versions.txt を確認してください。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }

  if [ "$_latest" = "$CURRENT_VERSION" ]; then
    printf '%s\n' "${GREEN}✅ すでに最新版（${CURRENT_VERSION}）です。${RESET}"
    printf '\n'
    read -r -p "Enterで戻る..." _
    exec "$_CT_SCRIPT_PATH" || exit 0
  fi

  printf '%s\n' "最新版: ${GREEN}${_latest}${RESET}（現在: ${CURRENT_VERSION}）"
  printf '\n'
  read -r -p "アップデートしますか？ [y/N]: " _confirm
  case "$_confirm" in
    y|Y) ;;
    *)
      exec "$_CT_SCRIPT_PATH" || exit 0
      ;;
  esac

  _ct_download_replace "$_latest"
}

# ── アップデート: 手動バージョン選択 (/update --manual) ──
_ct_manual_update() {
  trap 'printf "\n${YELLOW}⚠️  アップデートをキャンセルしました。${RESET}\n\n"; read -r -p "Enterで閉じる..." _; exit 0' INT

  printf '\n'
  printf '%s\n' "バージョン一覧を取得中..."

  local _vc
  _vc=$(_ct_fetch_versions) || {
    printf '%s\n' "${RED}❌ バージョン情報の取得に失敗しました。ネットワーク接続を確認してください。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  }

  # versions.txt をパースして配列に格納（bash 3.2 互換）
  # 不正な行・100行超過分はスキップ
  local _ct_vers=()
  local _ct_descs=()
  local _ct_line
  while IFS= read -r _ct_line; do
    [ -z "$_ct_line" ] && continue
    [ "${#_ct_vers[@]}" -ge 100 ] && break
    local _ct_v
    _ct_v=$(printf '%s' "$_ct_line" | awk '{print $1}')
    local _ct_d
    _ct_d=$(printf '%s' "$_ct_line" | cut -d' ' -f2-)
    _ct_validate_version "$_ct_v" || continue
    _ct_vers+=("$_ct_v")
    _ct_descs+=("$_ct_d")
  done <<< "$_vc"

  if [ "${#_ct_vers[@]}" -eq 0 ]; then
    printf '%s\n' "${RED}❌ 利用可能なバージョンが見つかりませんでした。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi

  printf '\n'
  printf '%s\n' "${BOLD}利用可能なバージョン:${RESET}"
  printf '\n'
  local _ct_i
  for (( _ct_i=0; _ct_i<${#_ct_vers[@]}; _ct_i++ )); do
    local _ct_marker=""
    [ "${_ct_vers[$_ct_i]}" = "$CURRENT_VERSION" ] && _ct_marker=" ${YELLOW}← 現在${RESET}"
    printf "  ${CYAN}[$(( _ct_i + 1 ))]${RESET}  %-10s  %s%b\n" \
      "${_ct_vers[$_ct_i]}" "${_ct_descs[$_ct_i]}" "$_ct_marker"
  done
  printf '\n'

  read -r -p "番号を入力 (Ctrl+C でキャンセル): " _ct_sel
  printf '\n'

  # 入力検証: 数字のみ・1〜N の範囲内
  if ! [[ "$_ct_sel" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${RED}❌ 数字を入力してください。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi

  local _ct_idx=$(( _ct_sel - 1 ))
  if [ "$_ct_idx" -lt 0 ] || [ "$_ct_idx" -ge "${#_ct_vers[@]}" ]; then
    printf '%s\n' "${RED}❌ 範囲外の番号です（1〜${#_ct_vers[@]}）。${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi

  local _ct_target="${_ct_vers[$_ct_idx]}"

  if [ "$_ct_target" = "$CURRENT_VERSION" ]; then
    printf '%s\n' "${GREEN}✅ すでにバージョン ${CURRENT_VERSION} です。${RESET}"
    printf '\n'
    read -r -p "Enterで戻る..." _
    exec "$_CT_SCRIPT_PATH" || exit 0
  fi

  printf '%s\n' "バージョン ${_ct_target} に切り替えます。（現在: ${CURRENT_VERSION}）"
  printf '\n'
  read -r -p "続行しますか？ [y/N]: " _ct_confirm
  case "$_ct_confirm" in
    y|Y) ;;
    *)
      exec "$_CT_SCRIPT_PATH" || exit 0
      ;;
  esac

  _ct_download_replace "$_ct_target"
}

# ── 設定メニュー (/settings) ─────────────────────────────
_ct_show_settings() {
  trap 'printf "\n${YELLOW}⚠️  キャンセルしました。${RESET}\n\n"; read -r -p "Enterで閉じる..." _; exit 0' INT

  clear
  printf '%s\n' "${BOLD}${CYAN}⚙️  設定${RESET}"
  printf '%s\n' "${CYAN}────────────────────────────────────────${RESET}"
  printf '\n'
  printf '%s\n' "  現在のバージョン: ${GREEN}${CURRENT_VERSION}${RESET}"
  printf '\n'
  printf '%s\n' "  ${CYAN}/update${RESET}           最新版に自動アップデート"
  printf '%s\n' "  ${CYAN}/update --manual${RESET}  バージョンを選んでアップデート/ダウングレード"
  printf '%s\n' "  ${CYAN}/back${RESET}             メインメニューに戻る"
  printf '\n'
  read -r -p "入力: " _scmd
  printf '\n'

  case "$_scmd" in
    "/update")          _ct_auto_update ;;
    "/update --manual") _ct_manual_update ;;
    "/back")
      exec "$_CT_SCRIPT_PATH" || exit 0
      ;;
    *)
      printf '%s\n' "${RED}❌ 不明なコマンドです。${RESET}"
      printf '\n'
      read -r -p "Enterで閉じる..." _
      exit 1
      ;;
  esac
}

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
printf '%s\n' "  ${CYAN}1:2:3:4${RESET}      → 1日2時間3分4秒"
printf '%s\n' "  ${CYAN}1:2:3:4:5${RESET}    → 1ヶ月2日3時間4分5秒"
printf '%s\n' "  ${CYAN}1:2:3:4:5:6${RESET}  → 1年2ヶ月3日4時間5分6秒"
printf '%s\n' "  ${CYAN}1y / 1year${RESET}   → 1年"
printf '%s\n' "  ${CYAN}2mo / 2month${RESET} → 2ヶ月"
printf '%s\n' "  ${CYAN}1d / 1day${RESET}    → 1日"
printf '%s\n' "  ${CYAN}1h / 1hour${RESET}   → 1時間"
printf '%s\n' "  ${CYAN}45m / 45min${RESET}  → 45分"
printf '%s\n' "  ${CYAN}20s / 20sec${RESET}  → 20秒"
printf '%s\n' "  ${CYAN}1h30m20s${RESET}     → 1時間30分20秒"
printf '%s\n' "  ${CYAN}1h20s${RESET}        → 1時間20秒"
printf '%s\n' "  ${CYAN}1.5h${RESET}         → 1時間30分"
printf '%s\n' "  ${CYAN}1y2mo${RESET}        → 1年2ヶ月"
printf '%s\n' "  ${CYAN}1y2mo3h30m${RESET}   → 1年2ヶ月3時間30分"
printf '%s\n' "  ${CYAN}1d3h30m${RESET}      → 1日3時間30分"
printf '%s\n' "  ${CYAN}/settings${RESET}    → 設定"
printf '\n'
read -r -p "入力: " input
printf '\n'

# ── /settings コマンド ────────────────────────────────────
# 前処理を通す前に検出する（スペース除去・小文字化の影響を受けないよう先に処理）
if [ "$input" = "/settings" ]; then
  _ct_show_settings
  exit 0
fi

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

# ── 前処理③：各数値グループの先頭ゼロを除去 ──────────────────────────
# 10# で8進数誤認は防いでいるが、文字列長チェックが先頭ゼロで
# 誤判定しないよう正規化する（例: 000001h → 1h、00:05 → 0:5）。
# bash の =~ は macOS デフォルトの 3.2 では交替 (^|X) の ^ が
# 正しく動作しないため、外部コマンド sed を使用する。
input=$(printf '%s' "$input" | sed -E 's/(^|[^0-9])0+([0-9])/\1\2/g')

# ── 年・月コンポーネントの抽出 ──────────────────────────────────────
# カレンダー演算が必要なため、パターンマッチの前に y / mo を分離する。
# 数字は 10# プレフィックスで8進数誤認を防止。
# 桁数を4桁以内に制限し BSD date -v への過大入力を防ぐ。
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

# 4.1) W:X:Y:Z → 日:時:分:秒
elif [[ "$input" =~ ^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$ ]]; then
  seconds=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))

# 4.2) V:W:X:Y:Z → ヶ月:日:時:分:秒
elif [[ "$input" =~ ^([0-9]+):([0-9]+):([0-9]+):([0-9]+):([0-9]+)$ ]]; then
  if [ "${#BASH_REMATCH[1]}" -gt 4 ]; then
    printf '%s\n' "${RED}❌ 入力が長すぎます（月の値は4桁以内）。${RESET}"
    printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 1:2:3:4 / 1:2:3:4:5 / 45m / 1h / 1d${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi
  month_val=$(( 10#${BASH_REMATCH[1]} ))
  seconds=$(( 10#${BASH_REMATCH[2]} * 86400 + 10#${BASH_REMATCH[3]} * 3600 + 10#${BASH_REMATCH[4]} * 60 + 10#${BASH_REMATCH[5]} ))

# 4.3) U:V:W:X:Y:Z → 年:ヶ月:日:時:分:秒
elif [[ "$input" =~ ^([0-9]+):([0-9]+):([0-9]+):([0-9]+):([0-9]+):([0-9]+)$ ]]; then
  if [ "${#BASH_REMATCH[1]}" -gt 4 ] || [ "${#BASH_REMATCH[2]}" -gt 4 ]; then
    printf '%s\n' "${RED}❌ 入力が長すぎます（年・月の値は4桁以内）。${RESET}"
    printf '%s\n' "例: ${CYAN}90 / 1:30 / 1:30:00 / 1:2:3:4 / 1:2:3:4:5:6 / 45m / 1h / 1d${RESET}"
    printf '\n'
    read -r -p "Enterで閉じる..." _
    exit 1
  fi
  year_val=$(( 10#${BASH_REMATCH[1]} ))
  month_val=$(( 10#${BASH_REMATCH[2]} ))
  seconds=$(( 10#${BASH_REMATCH[3]} * 86400 + 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))

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
# BSD date の -v オプションでカレンダーを考慮した月・年の加算を行う。
# sub_seconds は d/h/m/s 分のみの秒数（表示用に保持）。
# _now_epoch を先頭で一度だけ取得し、以降の全時刻計算の基点として使い回す。
# これにより、カレンダー演算・表示・最大秒数チェックの各ステップ間で
# システム時計が1秒進むことによるドリフトを防ぐ。
sub_seconds=$seconds
_now_epoch=$(date +%s)
if [ "$year_val" -gt 0 ] || [ "$month_val" -gt 0 ]; then
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
# end_epoch = now + seconds が date -r の処理可能な上限(16桁エポック)を超えないよう
# 実行時刻から動的に算出する
_MAX_SECONDS=$(( 9999999999999999 - _now_epoch ))
if [ "$seconds" -gt "$_MAX_SECONDS" ]; then
  printf '%s\n' "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
  printf '\n'
  read -r -p "Enterで閉じる..." _
  exit 1
fi

# ── 時刻・継続時間の表示 ─────────────────────────────────
now_time=$(date -r "$_now_epoch" "+%Y-%m-%d %H:%M:%S")
end_epoch=$(( _now_epoch + seconds ))
end_time=$(date -r "$end_epoch" "+%Y-%m-%d %H:%M:%S")

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
caffeinate -u -d -t "$seconds"

# ── 正常終了 ─────────────────────────────────────────────
printf '%s\n' "${GREEN}✅ 終了しました。 ($(date "+%H:%M:%S"))${RESET}"
printf '\n'
read -r -p "Enterで閉じる..." _
