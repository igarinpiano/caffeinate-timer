#!/usr/bin/env bash
# バージョン表記の整合性。
#
# v1.4.10 の準備中に、versions.txt へ行を追加し忘れたまま各スクリプトの
# CURRENT_VERSION だけを上げた状態が発生した。アップデート判定は等値比較なので
# /update が一つ前のバージョンを「最新版」として提示し、承諾するとダウングレード
# してしまう。このファイルはその状態を検出する。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

LATEST=$(head -1 versions.txt | awk '{print $1}')

section "versions.txt の書式"

assert_match '^v[0-9]+\.[0-9]+\.[0-9]+[a-z]?$' "$LATEST" "先頭行のバージョンが正しい形式"

bad_lines=$(grep -vE '^v[0-9]+\.[0-9]+\.[0-9]+[a-z]? [0-9]{4}-[0-9]{2}-[0-9]{2} .+$' versions.txt || true)
assert_eq "" "$bad_lines" "全行が '<version> <YYYY-MM-DD> <説明>' 形式"

dupes=$(awk '{print $1}' versions.txt | sort | uniq -d)
assert_eq "" "$dupes" "バージョンの重複がない"

section "CURRENT_VERSION が versions.txt の先頭と一致"

for f in caffeinate-timer-universal.sh caffeinate-timer.command; do
  v=$(sed -n 's/^CURRENT_VERSION="\(v[^"]*\)"$/\1/p' "$f" | head -1)
  assert_eq "$LATEST" "$v" "$f"
done

bat_v=$(grep -a -o '^\$CURRENT_VERSION = "v[^"]*"' caffeinate-timer-windows.bat | sed 's/.*"\(v[^"]*\)".*/\1/')
assert_eq "$LATEST" "$bat_v" "caffeinate-timer-windows.bat"

pkg_v=$(node -p 'require("./package.json").version' 2>/dev/null)
assert_eq "${LATEST#v}" "$pkg_v" "package.json (先頭の v を除いた形)"

section "スクリプト自身の検証関数が現行バージョンを受理する"

for f in caffeinate-timer-universal.sh caffeinate-timer.command; do
  if out=$(extract_fn "$f" _ct_validate_version) && [ -n "$out" ]; then
    if ( eval "$out"; _ct_validate_version "$LATEST" ); then
      pass "$f: _ct_validate_version '$LATEST'"
    else
      fail "$f: _ct_validate_version '$LATEST'" "検証関数が現行バージョンを拒否している"
    fi
  else
    skip "$f: _ct_validate_version" "関数が見つからない"
  fi
done

section "package.json の体裁"

if [ -n "$(tail -c 1 package.json)" ]; then
  fail "末尾が改行で終わっている" "最終バイトが改行ではない"
else
  pass "末尾が改行で終わっている"
fi

section "配布ファイルの指定"

for f in $(node -p 'require("./package.json").files.join("\n")'); do
  if [ -e "$f" ]; then pass "files[] の $f が存在する"
  else fail "files[] の $f が存在する" "package.json が存在しないパスを指している"; fi
done

bin=$(node -p 'require("./package.json").bin["caffeinate-timer"]')
if [ -f "$bin" ]; then pass "bin の $bin が存在する"
else fail "bin の $bin が存在する"; fi

assert_match '^#!/usr/bin/env node' "$(head -1 "$bin")" "bin に shebang がある"
