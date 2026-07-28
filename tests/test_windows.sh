#!/usr/bin/env bash
# caffeinate-timer-windows.bat の構造と PowerShell 5.1 互換性。
#
# .bat はバッチのヘッダー部と PowerShell 本体を1ファイルに同梱した polyglot で、
# Windows 実機が無くても壊れやすい前提条件を静的に検証できる。
#   - 改行が CRLF であること（LF だと cmd.exe が正しく読めない）
#   - ヘッダー部が純 ASCII であること（chcp 後の誤デコード対策）
#   - 抽出マーカーがファイル内に1組だけ現れること
#   - PowerShell 6.2 以降専用の構文が混入していないこと（5.1 でパースエラー）
# pwsh があれば実際にパースまで行う。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"
BAT=caffeinate-timer-windows.bat
OPEN='<#PS'
CLOSE='#>PS'

section "ファイルの体裁"

if [ -f "$BAT" ]; then pass "$BAT が存在する"; else fail "$BAT が存在する"; exit 1; fi

crlf=$(python3 - "$BAT" <<'PY'
import io, sys
t = io.open(sys.argv[1], encoding='utf-8', newline='').read()
print('ok' if t.count('\n') == t.count('\r\n') and t.count('\r') == t.count('\r\n') else 'mixed')
PY
)
assert_eq "ok" "$crlf" "改行がすべて CRLF（LF や裸の CR が無い）"

hdr_ascii=$(python3 - "$BAT" <<'PY'
import io, sys
t = io.open(sys.argv[1], encoding='utf-8', newline='').read()
h = t[:t.index('<' + '#PS')]
print('ok' if all(ord(c) < 128 for c in h) else 'non-ascii')
PY
)
assert_eq "ok" "$hdr_ascii" "ヘッダー部が純 ASCII（chcp 後の誤デコードを防ぐ）"

assert_eq "1" "$(grep -a -c -F "$OPEN" "$BAT")" "開始マーカーを含む行が1行だけ"
assert_eq "1" "$(grep -a -c -F "$CLOSE" "$BAT")" "終了マーカーを含む行が1行だけ"

# ランチャー行にマーカー文字列がそのまま書かれていると IndexOf が
# ヘッダー内を指してしまう（v1.4.8 で修正した不具合）。
launcher=$(grep -a 'powershell.exe' "$BAT" | head -1)
assert_no_match '<#PS' "$launcher" "ランチャー行に開始マーカーの文字列が露出していない"
assert_no_match '#>PS' "$launcher" "ランチャー行に終了マーカーの文字列が露出していない"
assert_match 'ExecutionPolicy Bypass' "$launcher" "ランチャーが ExecutionPolicy Bypass を指定"
assert_match 'NoProfile' "$launcher" "ランチャーが -NoProfile を指定"

quotes=$(printf '%s' "$launcher" | tr -cd '"' | wc -c | tr -d ' ')
if [ $((quotes % 2)) -eq 0 ]; then pass "ランチャー行の二重引用符が偶数個 ($quotes)"
else fail "ランチャー行の二重引用符が偶数個" "$quotes 個（cmd.exe の引用が壊れる）"; fi

section "PowerShell 5.1 で使えない構文の混入"

BODY=$(tmpfile)
python3 - "$BAT" "$BODY" <<'PY'
import io, sys
t = io.open(sys.argv[1], encoding='utf-8', newline='').read()
si = t.index('<' + '#PS') + 4
ei = t.rindex('#' + '>PS')
io.open(sys.argv[2], 'w', encoding='utf-8', newline='').write(t[si:ei])
PY

if [ -s "$BODY" ]; then pass "埋め込み本体を抽出できる"; else fail "埋め込み本体を抽出できる"; fi

# 符号なし数値リテラル（0u / 4u）は PowerShell 6.2 以降の構文で、5.1 では
# スクリプト全体がパースエラーになる（v1.4.9 で修正した不具合）。
# C# ソース文字列内の 0x........u は Add-Type がコンパイルするため対象外。
u_lit=$(grep -nE '(^|[^0-9a-zA-Z_x.])[0-9]+u[ls]?([^0-9a-zA-Z_]|$)' "$BODY" | grep -v '^\s*[0-9]*:\s*#' || true)
assert_eq "" "$u_lit" "u/ul 接尾辞の数値リテラルが無い（6.2 以降専用）"

for tok in '??' '?->' '&&' '||'; do
  found=$(grep -a -F -- "$tok" "$BODY" | grep -v '^\s*#' || true)
  assert_eq "" "$found" "PowerShell 7 専用演算子 '$tok' が無い"
done

section "セキュリティ上の前提"

has() { if grep -aqF -- "$1" "$BODY"; then pass "$2"; else fail "$2" "本体に '$1' が見つからない"; fi; }
has 'EncodedCommand'        "/bg は -EncodedCommand で子プロセスへ渡す"
has 'TreatControlCAsInput'  "Ctrl+C をキー入力として扱う"
has 'SetThreadExecutionState' "スリープ防止 API を使用"
has 'Get-Process -Id'       "/wait は Get-Process へ引数として渡す"

section "バージョン表記"
assert_eq "$(head -1 versions.txt | awk '{print $1}')" \
          "$(grep -a -o '^\$CURRENT_VERSION = "v[^"]*"' "$BAT" | sed 's/.*"\(v[^"]*\)".*/\1/')" \
          "\$CURRENT_VERSION が versions.txt の先頭と一致"

section "PowerShell パーサによる検証"
PWSH=$(command -v pwsh || command -v powershell || true)
if [ -z "$PWSH" ]; then
  skip "スクリプトブロックのコンパイル" "pwsh が無い"
  skip "パースエラー件数" "pwsh が無い"
else
  out=$(CT_BODY="$BODY" "$PWSH" -NoProfile -Command '
    $body = [IO.File]::ReadAllText($env:CT_BODY)
    try { [void][scriptblock]::Create($body); "CREATE_OK" } catch { "CREATE_FAIL " + $_.Exception.Message }
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$errors)
    "ERRORS " + $errors.Count
    $bad = $tokens | Where-Object {
      $_.Kind -eq "Number" -and $_.Text -notmatch "^0[xX]" -and $_.Text -match "[a-zA-Z]" -and
      $_.Text -notmatch "(?i)(l|d|kb|mb|gb|tb|pb)$"
    }
    "BADLIT " + @($bad).Count
  ' 2>&1 </dev/null) || true
  assert_match 'CREATE_OK' "$out" "[scriptblock]::Create() が成功する"
  assert_match 'ERRORS 0' "$out" "パースエラーが0件"
  assert_match 'BADLIT 0' "$out" "5.1 で無効な数値リテラルが0件"
fi
