#!/usr/bin/env bash
# 共通アサーションヘルパー。各 test_*.sh から source する。
#
# 各テストファイルは終了時に "<pass> <fail> <skip>" を $CT_TALLY へ追記し、
# 失敗が1件でもあれば非ゼロで終了する（run.sh が集計する）。
#
# 移植性の方針:
#   - GNU 専用の道具・拡張を使わない。macOS には timeout が無く、BSD sed は
#     \| による選択も \x1b も解釈しない。選択が要る場所は grep -E / awk を使う。
#   - bash 3.2（macOS 標準）で動く構文だけを使う。
#   - Windows（Git Bash）でも静的検査だけは動くようにする。

CT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CT_PASS=0
CT_FAIL=0
CT_SKIP=0

if [ -t 1 ]; then
  _G=$'\033[0;32m'; _R=$'\033[0;31m'; _Y=$'\033[1;33m'; _B=$'\033[1m'; _N=$'\033[0m'
else
  _G=''; _R=''; _Y=''; _B=''; _N=''
fi

ESC=$(printf '\033')

# テストファイル側で trap ... EXIT を張るとこの集計が消えるため、
# 一時ファイルは tmpfile() で確保する（終了時にまとめて削除される）。
CT_TMPFILES=()
tmpfile() { local f; f=$(mktemp "${TMPDIR:-/tmp}/ct.XXXXXX"); CT_TMPFILES+=("$f"); printf '%s' "$f"; }

_ct_finish() {
  [ "${#CT_TMPFILES[@]}" -gt 0 ] && rm -rf "${CT_TMPFILES[@]}"
  [ -n "${CT_TALLY:-}" ] && printf '%d %d %d\n' "$CT_PASS" "$CT_FAIL" "$CT_SKIP" >> "$CT_TALLY"
  [ "$CT_FAIL" -eq 0 ]
}
trap '_ct_finish' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# 実行中のプラットフォーム
case "$(uname -s)" in
  Darwin)                 CT_OS=macos ;;
  Linux)                  CT_OS=linux ;;
  CYGWIN*|MINGW*|MSYS*)   CT_OS=windows ;;
  *)                      CT_OS=other ;;
esac

# 既定の対象（単一スクリプトだけを見るテスト用）
case "$CT_OS" in
  macos) CT_SCRIPT=caffeinate-timer.command ;;
  *)     CT_SCRIPT=caffeinate-timer-universal.sh ;;
esac

# 実行して検証できる対象の一覧。
# universal.sh は macOS / Linux 両対応をうたっているため、macOS では
# .command と .sh の両方を回す（BSD date 経路の分岐が両方に入っている）。
case "$CT_OS" in
  macos) CT_TARGETS="caffeinate-timer.command caffeinate-timer-universal.sh" ;;
  linux) CT_TARGETS="caffeinate-timer-universal.sh" ;;
  *)     CT_TARGETS="" ;;
esac

# 最大秒数の方針はファイルごとに異なる。桁数上限（20/16/14/4）は共通。
#   epoch16  : .command / .sh — 16桁エポック(9999999999999999)まで ≒ 西暦約3億年
#   year9999 : .bat          — .NET の DateTime.MaxValue まで（西暦9999年）
ct_max_policy() {
  case "$1" in
    *windows.bat) printf 'year9999' ;;
    *)            printf 'epoch16' ;;
  esac
}

section() { printf '\n%s%s%s\n' "$_B" "$1" "$_N"; }

pass() { CT_PASS=$((CT_PASS + 1)); printf '  %s✓%s %s\n' "$_G" "$_N" "$1"; }

fail() {
  CT_FAIL=$((CT_FAIL + 1))
  printf '  %s✗%s %s\n' "$_R" "$_N" "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/      /'
  return 0
}

skip() { CT_SKIP=$((CT_SKIP + 1)); printf '  %s−%s %s %s(%s)%s\n' "$_Y" "$_N" "$1" "$_Y" "$2" "$_N"; }

# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else
    fail "$3" "expected: $1
actual:   $2"
  fi
}

# assert_match <ERE> <actual> <label>
assert_match() {
  if printf '%s' "$2" | grep -Eq -- "$1"; then pass "$3"; else
    fail "$3" "pattern: $1
actual:  $2"
  fi
}

# assert_no_match <ERE> <actual> <label>
assert_no_match() {
  if printf '%s' "$2" | grep -Eq -- "$1"; then
    fail "$3" "must NOT match: $1
actual:        $2"
  else pass "$3"; fi
}

# assert_between <min> <max> <actual> <label>   (整数、両端を含む)
assert_between() {
  if [ "$3" -ge "$1" ] 2>/dev/null && [ "$3" -le "$2" ] 2>/dev/null; then
    pass "$4 ($3)"
  else
    fail "$4" "expected: $1 〜 $2
actual:   $3"
  fi
}

# ── 対象スクリプトへ入力を1つ与え、時間解析の結果だけを取り出す ────────
#
# タイマー本体は走らせない。継続時間かエラーの行が出た時点でプロセスを終了させる。
# SIGPIPE に頼ると環境によって終了が遅れる（CI で1件あたり十数秒かかった）ため、
# 明示的に kill する。macOS に timeout が無いので自前でポーリングする。
#   戻り値: "OK <秒数>" / "ERR <メッセージ>" / "NONE"
duration() {
  local script="$1" input="$2" out pid i line
  out=$(tmpfile)
  printf '%s\n\n' "$input" 2>/dev/null | bash "$script" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do          # 最大およそ20秒
    if LC_ALL=C grep -Eq '継続時間|❌' "$out" 2>/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  # スクリプト本体と、その子（caffeinate / systemd-inhibit / sleep）を落とす
  if kill -0 "$pid" 2>/dev/null; then
    have pkill && pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    sleep 0.1
    kill -9 "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null

  line=$(LC_ALL=C awk '/継続時間|❌/{print; exit}' "$out" | sed "s/${ESC}\[[0-9;]*m//g" | tr -d '\r')
  case "$line" in
    *継続時間*) printf 'OK %s' "$(printf '%s' "$line" | sed -n 's/.*(\([0-9][0-9]*\)秒).*/\1/p')" ;;
    *❌*)       printf 'ERR %s' "$(printf '%s' "$line" | sed 's/.*❌ *//')" ;;
    *)          printf 'NONE' ;;
  esac
}

# duration() の秒数部分のみ（失敗時は空文字）
duration_secs() {
  local r; r=$(duration "$1" "$2")
  case "$r" in OK\ *) printf '%s' "${r#OK }" ;; *) printf '' ;; esac
}

# 調整パーサを依存関数ごと切り出す。
# _ct_parse_adj_secs は _ct_fw_to_ascii（全角→半角変換）を呼ぶため、
# 単体で切り出すと未定義になる。依存が増えたらここに追加する。
extract_adj_fn() {
  extract_fn "$1" _ct_fw_to_ascii
  extract_fn "$1" _ct_parse_adj_secs
}

# 対象スクリプト内の関数定義だけを切り出す（行番号に依存しない）
extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$1"
}

DAY=86400
