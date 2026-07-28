#!/usr/bin/env bash
# bin/caffeinate-timer.js（npm 経由の起動）のプラットフォーム分岐。
#
# spawn を差し替えて引数だけを取り出すので、Windows 実機なしで win32 経路も
# 検証できる。ここで守りたい前提:
#   - cmd.exe を絶対パスで解決する（カレントディレクトリからの乗っ取り防止）
#   - /d /s /c と二重引用符で括る（括弧やスペースを含むパスでも起動できる）
#   - windowsVerbatimArguments を有効にする（Node 側の再引用を止める）
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"
PROBE=tests/fixtures/launcher-probe.js

if ! command -v node >/dev/null 2>&1; then
  skip "ランチャーの分岐" "node が無い"
  exit 0
fi

probe() { PROBE_PLATFORM="$1" node "$PROBE" 2>/dev/null | head -1; }
jq_get() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const o=JSON.parse(s);const f=process.argv[1];
      let v=f.split(".").reduce((a,k)=>a===undefined?a:a[/^\d+$/.test(k)?Number(k):k],o);
      process.stdout.write(v===undefined?"":String(v));}catch(e){}
  });' "$2"; }

section "構文チェック"
if node --check bin/caffeinate-timer.js 2>/dev/null; then pass "bin/caffeinate-timer.js の構文が正しい"
else fail "bin/caffeinate-timer.js の構文が正しい"; fi

section "win32: cmd.exe の解決と引数"
W=$(probe win32)
if [ -z "$W" ]; then fail "win32 で spawn が呼ばれる" "出力なし"; else
  pass "win32 で spawn が呼ばれる"
  cmd=$(jq_get "$W" cmd)
  assert_match 'System32' "$cmd" "cmd.exe を System32 配下の絶対パスで解決"
  assert_match 'cmd\.exe$' "$cmd" "解決先が cmd.exe"
  assert_no_match '^cmd\.exe$' "$cmd" "裸の 'cmd.exe' ではない（cwd からの乗っ取り防止）"

  assert_eq "/d" "$(jq_get "$W" args.0)" "args[0] が /d（AutoRun を無効化）"
  assert_eq "/s" "$(jq_get "$W" args.1)" "args[1] が /s（外側の引用符1組だけを外させる）"
  assert_eq "/c" "$(jq_get "$W" args.2)" "args[2] が /c"

  target=$(jq_get "$W" args.3)
  assert_match '^""' "$target" "対象パスが二重引用符2つで始まる"
  assert_match '""$' "$target" "対象パスが二重引用符2つで終わる"
  assert_match 'caffeinate-timer-windows\.bat' "$target" "対象が Windows 用 .bat"

  assert_eq "true" "$(jq_get "$W" opts.windowsVerbatimArguments)" "windowsVerbatimArguments が有効"
  assert_eq "inherit" "$(jq_get "$W" opts.stdio)" "stdio が inherit"
fi

section "darwin / linux"
D=$(probe darwin)
assert_eq "bash" "$(jq_get "$D" cmd)" "darwin は bash で起動"
assert_match 'caffeinate-timer\.command$' "$(jq_get "$D" args.0)" "darwin は .command を実行"
assert_eq "" "$(jq_get "$D" opts.windowsVerbatimArguments)" "darwin では windowsVerbatimArguments を付けない"

L=$(probe linux)
assert_eq "bash" "$(jq_get "$L" cmd)" "linux は bash で起動"
assert_match 'caffeinate-timer-universal\.sh$' "$(jq_get "$L" args.0)" "linux は universal.sh を実行"

section "未サポートのプラットフォーム"
out=$(PROBE_PLATFORM=sunos node "$PROBE" 2>&1); rc=$?
assert_eq "1" "$rc" "未サポート環境では終了コード1"
assert_match 'Unsupported platform' "$out" "未サポート環境ではメッセージを出す"

section "括弧やスペースを含むパスでも起動できる"
# npm がインストールする場所は選べないため、実際に厄介なパスへ複製して確認する。
tmp=$(mktemp -d); CT_TMPFILES+=("$tmp")
dest="$tmp/Program Files (x86)/caffeinate & co/v1.0"
mkdir -p "$dest/bin"
cp bin/caffeinate-timer.js "$dest/bin/"
cp caffeinate-timer-windows.bat caffeinate-timer-universal.sh caffeinate-timer.command "$dest/"
cp -r tests "$dest/tests"

W2=$(cd "$dest" && PROBE_PLATFORM=win32 node tests/fixtures/launcher-probe.js 2>/dev/null | head -1)
t2=$(jq_get "$W2" args.3)
assert_match 'Program Files \(x86\)' "$t2" "括弧つきパスがそのまま渡る"
assert_match '^""' "$t2" "括弧つきパスでも二重引用符で括られる"
assert_match '""$' "$t2" "括弧つきパスでも末尾が二重引用符2つ"

# /s があると cmd.exe は外側の1組だけを外すので、内側の引用符が残る = 正しい。
inner=$(printf '%s' "$t2" | sed 's/^"\(.*\)"$/\1/')
assert_match '^".*"$' "$inner" "外側1組を外しても引用符付きパスが残る"

L2=$(cd "$dest" && PROBE_PLATFORM=linux node tests/fixtures/launcher-probe.js 2>/dev/null | head -1)
assert_match 'Program Files \(x86\)' "$(jq_get "$L2" args.0)" "linux でも括弧つきパスを解決できる"
