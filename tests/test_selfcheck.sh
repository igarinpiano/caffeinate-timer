#!/usr/bin/env bash
# テスト自身の移植性チェック。
#
# 実際に踏んだ2つの落とし穴を再発させないための検査。
#   1. macOS に無い道具や GNU 専用の正規表現拡張を使ってしまう
#      → macOS で全件失敗したり、出力が空になって検査が空振りする
#   2. 変数の直後に全角文字を置く（"$VAR（..."）
#      → bash 3.2 が後続バイトを変数名に取り込み、set -u で異常終了する
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT/tests"

# 自分自身は対象外にする。検査したいパターンの文字列そのものを含むため。
FILES=$(ls ./*.sh | grep -v '^\./test_selfcheck\.sh$')
scan() { grep -nE -- "$1" $FILES 2>/dev/null || true; }
scan_fixed() { grep -n -F -- "$1" $FILES 2>/dev/null || true; }
scan_fixed_re() { grep -n -- "$1" $FILES 2>/dev/null || true; }

section "GNU 専用の道具・拡張を使っていない"

# timeout(1) は macOS に無い。lib.sh の説明コメントだけは対象外にする。
hit=$(scan_fixed_re '^[^#]*[^a-zA-Z_-]timeout ')
assert_eq "" "$hit" "timeout(1) を使っていない"

# BSD sed は \x1b を解釈しない（ESC は printf で組み立てる）
hit=$(scan_fixed '\x1b' | grep -v ': *#' || true)
assert_eq "" "$hit" "sed の \\x1b を使っていない"

# BSD sed は基本正規表現の \| （選択）を解釈しない
hit=$(scan_fixed_re 'sed[^|]*\\\\|' | grep -v ': *#' || true)
assert_eq "" "$hit" "sed の \\| による選択を使っていない"

# GNU 拡張のロングオプションを使っていない（BSD 版に無いものがある）
for opt in '--regexp=' '--expression=' 'grep -P'; do
  hit=$(scan_fixed "$opt")
  assert_eq "" "$hit" "'$opt' を使っていない"
done

section "変数の直後に全角文字を置いていない（bash 3.2 対策）"
# "$VAR（" のように書くと bash 3.2 が変数名にバイトを取り込む。"${VAR}（" と書く。
hit=$(python3 - <<'PY'
import io, re, glob
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
out = []
for p in sorted(glob.glob('*.sh')):
    if p == 'test_selfcheck.sh':
        continue
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        for m in pat.finditer(line):
            out.append('%s:%d: %s' % (p, i, m.group(0)))
print('\n'.join(out))
PY
)
assert_eq "" "$hit" "非 ASCII が続く変数は波括弧で囲まれている"

section "bash 3.2 に無い構文を使っていない"
for pat in '\${[A-Za-z_][A-Za-z0-9_]*,,}' '\${[A-Za-z_][A-Za-z0-9_]*\^\^}' 'declare -A' 'readarray' 'mapfile'; do
  hit=$(scan "$pat")
  assert_eq "" "$hit" "'$pat' を使っていない"
done

section "各テストファイルの体裁"
for f in $FILES; do
  case "$f" in ./lib.sh|./run.sh) continue ;; esac
  assert_match '^#!/usr/bin/env bash' "$(head -1 "$f")" "$(basename "$f"): shebang がある"
  if grep -q 'source "$(dirname "$0")/lib.sh"' "$f"; then
    pass "$(basename "$f"): lib.sh を読み込んでいる"
  else
    fail "$(basename "$f"): lib.sh を読み込んでいる"
  fi
  # trap ... EXIT を張ると lib.sh の集計が消える（tmpfile を使う）
  if grep -q "trap .* EXIT" "$f"; then
    fail "$(basename "$f"): 独自の EXIT trap を張っていない" "lib.sh の集計が上書きされる。tmpfile() を使う"
  else
    pass "$(basename "$f"): 独自の EXIT trap を張っていない"
  fi
  bash -n "$f" 2>/dev/null && pass "$(basename "$f"): 構文が正しい" \
    || fail "$(basename "$f"): 構文が正しい"
done

section "PowerShell テストの体裁"
if [ -f ./test_windows_exec.ps1 ]; then
  if have pwsh; then
    errs=$(pwsh -NoProfile -Command '
      $e=$null;$t=$null
      [void][System.Management.Automation.Language.Parser]::ParseFile("test_windows_exec.ps1",[ref]$t,[ref]$e)
      $e.Count' 2>/dev/null | tr -d '\r')
    assert_eq "0" "$errs" "test_windows_exec.ps1 のパースエラーが0件"
  else
    skip "test_windows_exec.ps1 のパース" "pwsh が無い"
  fi

  # PowerShell の変数名は大文字小文字を区別せず、スクリプト本体の代入は
  # $script: と同じスコープに入る。つまり本体で $p = ... と書くと集計用の
  # $script:P を壊す。実際に $p = Invoke-Target ... で集計が
  # PSCustomObject になり、$script:P++ が実行時エラーになった。
  # 集計用の変数と衝突する短い名前への代入を禁止する。
  hit=$(python3 - <<'PY'
import io, re

# 集計用に使っている script スコープの変数を拾う
lines = io.open('test_windows_exec.ps1', encoding='utf-8').readlines()
counters = set(m.lower() for m in re.findall(r'\$script:([A-Za-z_][A-Za-z0-9_]*)', ''.join(lines)))

# 関数の中はローカルスコープなので衝突しない。波括弧の深さを数えて、
# トップレベルの function ブロックの内側を除外する。
out, depth, in_fn = [], 0, False
for i, raw in enumerate(lines, 1):
    code = re.sub(r'#.*$', '', raw)
    stripped = code.strip()
    opens_fn = depth == 0 and re.match(r'function\s', stripped) is not None

    if not in_fn and not opens_fn and not stripped.startswith('$script:'):
        for m in re.finditer(r'\$([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)', code):
            if m.group(1).lower() in counters:
                out.append('%d: $%s への代入が $script:%s と衝突' % (i, m.group(1), m.group(1)))
        for m in re.finditer(r'foreach\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)\s+in', code):
            if m.group(1).lower() in counters:
                out.append('%d: foreach の $%s が $script:%s と衝突' % (i, m.group(1), m.group(1)))

    if opens_fn:
        in_fn = True
    depth += code.count('{') - code.count('}')
    if in_fn and depth <= 0:
        in_fn, depth = False, 0
print('\n'.join(out))
PY
)
  assert_eq "" "$hit" "集計用の \$script: 変数と衝突する代入が無い"
else
  fail "test_windows_exec.ps1 が存在する"
fi
