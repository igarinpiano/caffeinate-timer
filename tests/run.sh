#!/usr/bin/env bash
# 全テストを実行して集計する。
#   使い方: tests/run.sh            すべて実行
#           tests/run.sh version    名前に version を含むものだけ実行
set -uo pipefail

cd "$(dirname "$0")"
FILTER="${1:-}"

CT_TALLY="$(mktemp)"
export CT_TALLY
trap 'rm -f "$CT_TALLY"' EXIT

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; N=$'\033[0m'
else B=''; G=''; R=''; Y=''; N=''; fi

files=()
for f in test_*.sh; do
  [ -e "$f" ] || continue
  [ -n "$FILTER" ] && case "$f" in *"$FILTER"*) ;; *) continue ;; esac
  files+=("$f")
done

if [ "${#files[@]}" -eq 0 ]; then
  printf 'テストが見つかりません%s\n' "${FILTER:+ (filter: $FILTER)}"
  exit 1
fi

rc=0
for f in "${files[@]}"; do
  printf '\n%s━━━ %s %s\n' "$B" "$f" "$N"
  bash "$f" || rc=1
done

P=0; F=0; S=0
while read -r p fl s; do
  P=$((P + p)); F=$((F + fl)); S=$((S + s))
done < "$CT_TALLY"

printf '\n%s────────────────────────────────────────%s\n' "$B" "$N"
printf '%s%d passed%s' "$G" "$P" "$N"
[ "$F" -gt 0 ] && printf ' / %s%d failed%s' "$R" "$F" "$N"
[ "$S" -gt 0 ] && printf ' / %s%d skipped%s' "$Y" "$S" "$N"
printf '\n'

[ "$F" -eq 0 ] || rc=1
exit $rc
