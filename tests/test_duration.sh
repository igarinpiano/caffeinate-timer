#!/usr/bin/env bash
# 起動画面の時間入力の解析。実スクリプトへ実際に入力を与え、
# 表示された継続時間の秒数を検証する（タイマー本体は走らせない）。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

if [ -z "$CT_TARGETS" ]; then
  skip "時間入力の解析" "$CT_OS では実行できる対象が無い"
  exit 0
fi

# macOS では .command と universal.sh の両方を回す
for SCRIPT in $CT_TARGETS; do
  printf '\n%s══ %s %s\n' "$_B" "$SCRIPT" "$_N"

  ok() { assert_eq "OK $2" "$(duration "$SCRIPT" "$1")" "入力 '$1' → $2 秒"; }
  err() { assert_match "^ERR.*$2" "$(duration "$SCRIPT" "$1")" "入力 '$1' → エラー ($2)"; }

  section "基本の形式"
  ok '90'         5400
  ok '45m'        2700
  ok '1h'         3600
  ok '20s'        20
  ok '1:30'       90
  ok '1:30:00'    5400
  ok '1h30m20s'   5420
  ok '1d'         86400
  ok '1d3h'       97200
  ok '1:2:3:4'    93784      # 1日2時間3分4秒

  section "小数・単位の別表記・大文字"
  ok '1.5h'       5400
  ok '1.5'        90
  ok '0.5h'       1800
  ok '45min'      2700
  ok '45minutes'  2700
  ok '1hour'      3600
  ok '20sec'      20
  ok '1day'       86400
  ok '45MIN'      2700
  ok '1H'         3600

  section "空白・全角・先頭ゼロの正規化"
  ok ' 90 '       5400
  ok '1h 30m'     5400
  ok '１：３０'    90
  ok '９０'       5400
  ok '００９０'   5400
  ok '0090'       5400
  ok '1：30'      90       # 全角・半角混在

  section "カレンダー演算（年・月）"
  # 実行日によって秒数が変わるため範囲で検証する。
  # ここが壊れると Linux で年/月指定が使えない（v1.4.10 で修正した不具合）。
  y=$(duration_secs "$SCRIPT" '1y')
  if [ -n "$y" ]; then assert_between $((363 * DAY)) $((367 * DAY)) "$y" "入力 '1y' はおよそ1年"
  else fail "入力 '1y' はおよそ1年" "解析に失敗した: $(duration "$SCRIPT" '1y')"; fi

  m=$(duration_secs "$SCRIPT" '2mo')
  if [ -n "$m" ]; then assert_between $((57 * DAY)) $((63 * DAY)) "$m" "入力 '2mo' はおよそ2ヶ月"
  else fail "入力 '2mo' はおよそ2ヶ月" "解析に失敗した: $(duration "$SCRIPT" '2mo')"; fi

  ym=$(duration_secs "$SCRIPT" '1y2mo')
  if [ -n "$ym" ]; then assert_between $((420 * DAY)) $((432 * DAY)) "$ym" "入力 '1y2mo' はおよそ1年2ヶ月"
  else fail "入力 '1y2mo' はおよそ1年2ヶ月" "解析に失敗した: $(duration "$SCRIPT" '1y2mo')"; fi

  full=$(duration_secs "$SCRIPT" '1:2:3:4:5:6')
  if [ -n "$full" ]; then assert_between $((423 * DAY)) $((435 * DAY)) "$full" "入力 '1:2:3:4:5:6' は年:月:日:時:分:秒"
  else fail "入力 '1:2:3:4:5:6' は年:月:日:時:分:秒" "解析に失敗した: $(duration "$SCRIPT" '1:2:3:4:5:6')"; fi

  assert_match '^OK' "$(duration "$SCRIPT" '1year')"  "入力 '1year' が受理される"
  assert_match '^OK' "$(duration "$SCRIPT" '2months')" "入力 '2months' が受理される"

  section "ゼロ・不正な形式の拒否"
  err '0'      '0秒以下'
  err '0s'     '0秒以下'
  err '0m'     '0秒以下'
  err '00:00'  '0秒以下'
  err 'garbage' '入力形式'
  err 'abc'     '入力形式'
  err '1x'      '入力形式'
  err '-5'      '入力形式'
  err 'h'       '入力形式'
  err '1:2:3:4:5:6:7' '入力形式'
  err ':::'     '入力形式'
  err '1..5h'   '入力形式'
  assert_match '^ERR' "$(duration "$SCRIPT" '')" "空入力が拒否される"

  section "入力はシェルとして評価されない"
  # コマンド実行を試みる入力を与え、副作用が起きないことを確認する。
  canary="$(mktemp -u)"
  for payload in "90; touch $canary" "\$(touch $canary)" "\`touch $canary\`" "90 && touch $canary" "90 | touch $canary"; do
    duration "$SCRIPT" "$payload" >/dev/null 2>&1
    if [ -e "$canary" ]; then
      fail "入力 '$payload' がコマンドとして実行されない" "$canary が作成された"
      rm -f "$canary"
    else
      pass "入力 '$payload' がコマンドとして実行されない"
    fi
  done

  section "端末エスケープシーケンスの注入"
  # 生の ANSI シーケンスをそのままエコーバックしないこと。
  esc=$(printf '\033[31mBOOM\033[0m')
  # 生の出力を先頭から取り、入力の中身がそのまま画面へ出ていないことを確認する。
  # （出力が空だと無条件に通ってしまうため、何か出ていることも確かめる）
  raw_out=$(tmpfile)
  printf '%s\n\n' "$esc" | bash "$SCRIPT" > "$raw_out" 2>&1 &
  raw_pid=$!
  raw_i=0
  while [ "$raw_i" -lt 200 ]; do
    if LC_ALL=C grep -Eq '継続時間|❌' "$raw_out" 2>/dev/null; then break; fi
    kill -0 "$raw_pid" 2>/dev/null || break
    sleep 0.1
    raw_i=$((raw_i + 1))
  done
  if kill -0 "$raw_pid" 2>/dev/null; then
    have pkill && pkill -P "$raw_pid" 2>/dev/null
    kill "$raw_pid" 2>/dev/null; sleep 0.1; kill -9 "$raw_pid" 2>/dev/null
  fi
  wait "$raw_pid" 2>/dev/null
  raw=$(LC_ALL=C awk '/継続時間|❌/{print; exit} {print}' "$raw_out" | tr -d '\r')
  assert_match 'Caffeinate|入力|❌' "$raw" "出力が空ではない（次の検査が空振りしないこと）"
  assert_no_match 'BOOM' "$raw" "エスケープ付き入力の内容をエコーバックしない"
done
