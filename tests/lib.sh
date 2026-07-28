#!/usr/bin/env bash
# 共通アサーションヘルパー。各 test_*.sh から source する。
#
# 各テストファイルは終了時に "<pass> <fail> <skip>" を $CT_TALLY へ追記し、
# 失敗が1件でもあれば非ゼロで終了する（run.sh が集計する）。

CT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CT_PASS=0
CT_FAIL=0
CT_SKIP=0

if [ -t 1 ]; then
  _G=$'\033[0;32m'; _R=$'\033[0;31m'; _Y=$'\033[1;33m'; _B=$'\033[1m'; _N=$'\033[0m'
else
  _G=''; _R=''; _Y=''; _B=''; _N=''
fi

# テストファイル側で trap ... EXIT を張るとこの集計が消えるため、
# 一時ファイルは tmpfile() で確保する（終了時にまとめて削除される）。
CT_TMPFILES=()
tmpfile() { local f; f=$(mktemp); CT_TMPFILES+=("$f"); printf '%s' "$f"; }

_ct_finish() {
  [ "${#CT_TMPFILES[@]}" -gt 0 ] && rm -rf "${CT_TMPFILES[@]}"
  [ -n "${CT_TALLY:-}" ] && printf '%d %d %d\n' "$CT_PASS" "$CT_FAIL" "$CT_SKIP" >> "$CT_TALLY"
  [ "$CT_FAIL" -eq 0 ]
}
trap '_ct_finish' EXIT

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
# 継続時間の行を読んだ時点で sed が終了し、SIGPIPE でスクリプトも止まるため
# タイマー本体は走らない（1件あたり 0.1 秒程度）。
#   戻り値: "OK <秒数>" / "ERR <メッセージ>" / "NONE"
duration() {
  local script="$1" input="$2" out
  out=$(printf '%s\n\n' "$input" 2>/dev/null \
        | timeout 15 bash "$script" 2>&1 \
        | sed -n '/継続時間\|❌/{p;q;}' \
        | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
  case "$out" in
    *継続時間*) printf 'OK %s' "$(printf '%s' "$out" | sed -n 's/.*(\([0-9][0-9]*\)秒).*/\1/p')" ;;
    *❌*)       printf 'ERR %s' "$(printf '%s' "$out" | sed 's/.*❌ *//')" ;;
    *)          printf 'NONE' ;;
  esac
}

# duration() の秒数部分のみ（失敗時は空文字）
duration_secs() {
  local r; r=$(duration "$1" "$2")
  case "$r" in OK\ *) printf '%s' "${r#OK }" ;; *) printf '' ;; esac
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
