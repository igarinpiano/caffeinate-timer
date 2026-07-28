#!/usr/bin/env bash
# カウントダウン中の時間調整パーサ (_ct_parse_adj_secs)。
# 関数定義だけを切り出して直接呼ぶ（行番号には依存しない）。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

if [ -z "$CT_TARGETS" ]; then
  skip "調整パーサ" "$CT_OS では実行できる対象が無い"
  exit 0
fi

# macOS では .command と universal.sh の両方を回す
for SCRIPT in $CT_TARGETS; do
  FN=$(extract_adj_fn "$SCRIPT")
  if [ -z "$FN" ]; then
    skip "$SCRIPT: _ct_parse_adj_secs" "関数が見つからない"
    continue
  fi
  printf '\n%s══ %s %s\n' "$_B" "$SCRIPT" "$_N"

  # 呼び出し側は標準出力の空文字で失敗を判定する（終了コードは見ていない）ため、
  # ここでも同じ見方をする。
  adj() {
    ( OS="$(uname -s)"; eval "$FN"; _ct_parse_adj_secs "$1" 2>/dev/null )
  }

  ok()  { assert_eq "$2" "$(adj "$1")" "'$1' → $2 秒"; }
  rej() { assert_eq "" "$(adj "$1")" "'$1' が拒否される"; }

  section "基本の加算・減算"
  ok '+30m'      1800
  ok '-1h'       -3600
  ok '+90'       5400
  ok '+1d3h30m'  99000
  ok '+45s'      45
  ok '-20s'      -20
  ok '30m'       1800      # 符号なしは加算扱い
  ok '+1d'       86400

  section "単位の別表記・空白・全角"
  ok '+45min'    2700
  ok '+1hour'    3600
  ok '-2hrs'     -7200
  ok '+ 30 m'    1800
  ok '+000030m'  1800

  section "カレンダー演算（年・月）"
  # ここが壊れると実行中の +1y が無言で無視される（v1.4.10 で修正した不具合）。
  for spec in "+1y:363:367" "+2mo:57:63" "+1y2mo:420:432"; do
    in=${spec%%:*}; rest=${spec#*:}; lo=${rest%%:*}; hi=${rest##*:}
    v=$(adj "$in")
    if [ -n "$v" ]; then assert_between $((lo * DAY)) $((hi * DAY)) "$v" "'$in'"
    else fail "'$in'" "拒否された（解析に失敗している）"; fi
  done

  n=$(adj '-1y')
  if [ -n "$n" ]; then
    assert_between $((-367 * DAY)) $((-363 * DAY)) "$n" "'-1y' が負のおよそ1年"
  else fail "'-1y' が負のおよそ1年" "拒否された"; fi

  section "本体入力との一致"
  # 同じ指定なら本体パーサと調整パーサで同じ秒数になること（時計のずれ分だけ許容）。
  for u in 1y 2mo 1y2mo; do
    a=$(adj "+$u"); b=$(duration_secs "$SCRIPT" "$u")
    if [ -n "$a" ] && [ -n "$b" ]; then
      d=$(( a > b ? a - b : b - a ))
      if [ "$d" -le 2 ]; then pass "'$u' が本体パーサと一致 ($a)"
      else fail "'$u' が本体パーサと一致" "調整: $a / 本体: $b (差 ${d}秒)"; fi
    else
      fail "'$u' が本体パーサと一致" "調整: '${a:-拒否}' / 本体: '${b:-拒否}'"
    fi
  done

  section "拒否されるべき入力"
  rej '+0s'
  rej '+0'
  rej 'garbage'
  rej ''
  rej '+1x'
  rej '+1.5h'      # 小数は調整では未対応（本体入力のみ対応）
  rej '+abc'

  section "桁あふれ（int64 オーバーフロー）の封じ込め"
  INT64_MAX=9223372036854775807
  ok  '+99999999999999d' 8639999999999913600    # 14桁は受理され int64 に収まる
  rej '+999999999999999d'                        # 15桁は日数上限で拒否
  rej '+9999999999999999d'
  rej '+99999999999999999999d'
  rej '+1d99999999999999h'
  rej '+9999999999999999999999m'

  for v in '+99999999999999d' '+9999999999999999' '+99999999999999h'; do
    r=$(adj "$v")
    if [ -z "$r" ]; then
      pass "'$v' が拒否される（オーバーフロー回避）"
    elif [ "$r" -gt 0 ] 2>/dev/null && [ "$r" -le "$INT64_MAX" ] 2>/dev/null; then
      pass "'$v' が int64 の範囲内 ($r)"
    else
      fail "'$v' が int64 の範囲内" "桁あふれした値: $r"
    fi
  done

  section "調整入力はシェルとして評価されない"
  canary="$(mktemp -u)"
  for payload in '+30m; touch '"$canary" '$(touch '"$canary"')' '`touch '"$canary"'`'; do
    adj "$payload" >/dev/null 2>&1
    if [ -e "$canary" ]; then
      fail "'$payload' がコマンドとして実行されない" "$canary が作成された"; rm -f "$canary"
    else
      pass "'$payload' がコマンドとして実行されない"
    fi
  done
done
