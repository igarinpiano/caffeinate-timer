#!/usr/bin/env bash
# 入力長・桁数・最大秒数の上限。
#
# 「上限ちょうどは受理し、1つ超えたら拒否する」ことを対で確認する。
#
# 桁数の上限（調整20文字 / 本体16文字 / 日数14桁 / 年・月4桁）は3ファイル共通。
# 一方で最大秒数の方針はファイルごとに違うため、ct_max_policy で切り替える。
#   .command / .sh : 16桁エポック(9999999999999999)まで ≒ 西暦約3億年
#   .bat           : .NET の DateTime.MaxValue まで（西暦9999年）
# .bat 側の確認は tests/test_windows_exec.ps1 が担当する。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

if [ -z "$CT_TARGETS" ]; then
  skip "上限テスト" "$CT_OS では実行できる対象が無い"
  exit 0
fi

for SCRIPT in $CT_TARGETS; do
  POLICY=$(ct_max_policy "$SCRIPT")
  printf '\n%s══ %s (最大秒数: %s) %s\n' "$_B" "$SCRIPT" "$POLICY" "$_N"

  # 「長すぎ」で弾かれたかどうかだけを見る（他のエラーや受理は区別しない）
  too_long() { case "$(duration "$SCRIPT" "$1")" in *長すぎ*) printf 'yes' ;; *) printf 'no' ;; esac; }

  # 上限ちょうど → 桁数エラーにはならない / 1つ超え → 桁数エラー
  boundary() { # <ok入力> <ng入力> <ラベル>
    assert_eq "no"  "$(too_long "$1")" "$3: '$1' は桁数上限内"
    assert_eq "yes" "$(too_long "$2")" "$3: '$2' は桁数上限超え"
  }

  section "正規化後の全体長（上限16文字）"
  assert_eq "OK 9600030671" "$(duration "$SCRIPT" '111111d11h11m11s')" \
    "16文字ちょうど '111111d11h11m11s' が受理され正しい秒数になる"
  boundary '111111d11h11m11s' '1111111d11h11m11s' "全体長"
  boundary '1234567890123456' '12345678901234567' "全体長（数値のみ）"

  section "日数単体の桁数（上限14桁）"
  boundary '99999999999999d' '999999999999999d' "日数"

  section "年・月の桁数（上限4桁）"
  boundary '9999y'  '99999y'  "年"
  boundary '9999mo' '99999mo' "月"
  boundary '9999:1:2:3:4:5' '99999:1:2:3:4:5' "年（U:V:W:X:Y:Z 形式）"
  boundary '1:9999:2:3:4:5' '1:99999:2:3:4:5' "月（U:V:W:X:Y:Z 形式）"

  # 変数の直後に全角文字を置くと bash 3.2 が後続バイトを変数名に取り込むため、
  # 非 ASCII が続く箇所では必ず波括弧で囲む。
  section "最大秒数（このファイルの方針: ${POLICY}）"
  case "$POLICY" in
    epoch16)
      # 16桁エポックまで許すため、西暦9999年を超える指定も通る
      assert_match '^OK'          "$(duration "$SCRIPT" '7000y')" "'7000y' が受理される"
      assert_match '^OK'          "$(duration "$SCRIPT" '9999y')" "'9999y' が受理される（西暦9999年超も可）"
      assert_eq "OK 999999999999999" "$(duration "$SCRIPT" '999999999999999s')" \
        "'999999999999999s'（15桁の秒）が受理される"
      # 16桁の分 = 6e17 秒は 16桁エポックを超えるので弾かれる
      assert_match 'ERR.*最大時間' "$(duration "$SCRIPT" '9999999999999999')" \
        "'9999999999999999'（16桁=分）は最大秒数超えで拒否される"
      assert_match 'ERR.*最大時間' "$(duration "$SCRIPT" '99999999999999d')" \
        "'99999999999999d'（14桁の日）は最大秒数超えで拒否される"
      ;;
    year9999)
      skip "最大秒数（year9999）" "tests/test_windows_exec.ps1 が担当"
      ;;
  esac

  section "最小の受理値"
  assert_eq "OK 1" "$(duration "$SCRIPT" '1s')" "1秒は受理される"
  for v in '0s' '0' '0:00' '0d0h0m0s' '0.0h'; do
    assert_match 'ERR.*0秒以下' "$(duration "$SCRIPT" "$v")" "'$v' は0秒以下として拒否される"
  done

  section "上限内だが非常に長い書き方"
  # 単位の長い表記・空白・先頭ゼロは正規化で縮むため、生の入力が長くても
  # 上限には引っかからない。短い等価表記と同じ秒数になることを確認する。
  ref=$(duration_secs "$SCRIPT" '1:2:3:4:5:6')
  if [ -z "$ref" ]; then
    fail "基準となる '1:2:3:4:5:6' が解析できる" "解析に失敗した"
  else
    for v in '1years2months3days4hours5minutes6seconds' \
             '1year2month3day4hour5minute6second' \
             '1yr2mo3d4hr5min6sec' \
             '1 y 2 mo 3 d 4 h 5 m 6 s' \
             '1y 2mo 3d 4h 5m 6s'; do
      assert_eq "$ref" "$(duration_secs "$SCRIPT" "$v")" \
        "'$v' (${#v}文字) が '1:2:3:4:5:6' と同じ秒数"
    done
  fi

  assert_eq "OK 2700" "$(duration "$SCRIPT" '45minutes')" "'45minutes' が2700秒"
  assert_eq "OK 5420" "$(duration "$SCRIPT" '1hours30minutes20seconds')" \
    "'1hours30minutes20seconds' (24文字) が5420秒"

  # 先頭ゼロは正規化で消えるので、桁数上限の対象にならない
  for n in 30 100 1000; do
    z=$(awk -v n="$n" 'BEGIN{ s=""; for(i=0;i<n;i++) s = s "0"; print s "90" }')
    assert_eq "OK 5400" "$(duration "$SCRIPT" "$z")" "先頭ゼロ${n}個 + '90' が5400秒"
    assert_eq "no" "$(too_long "$z")" "先頭ゼロ${n}個では桁数上限を超えない"
  done

  section "長いが正規化されない書き方は拒否される"
  # 全角の英字は変換表に無い（数字・記号と単位1文字だけが対象）ため、
  # 正規化されずそのまま解析に失敗する。弾くのが正しい挙動。
  for v in '１ｙｅａｒ' '１ｍｉｎｕｔｅ' 'oneyear' '1year2year' \
           '1years2years3years4years' '1h1h1h' '1m1m1m1m1m' '1mo1mo'; do
    assert_match '^ERR' "$(duration "$SCRIPT" "$v")" "'$v' は拒否される"
  done
  # 半角の大文字は小文字化されるので、長い表記でも受理される（上と対になる確認）
  assert_eq "OK 31536000" "$(duration "$SCRIPT" '1YEAR')"        "'1YEAR' は受理される"
  assert_eq "OK 60"       "$(duration "$SCRIPT" '1MINUTES')"     "'1MINUTES' は受理される"
  assert_eq "OK 36892800" "$(duration "$SCRIPT" '1YEARS2MONTHS')" "'1YEARS2MONTHS' は受理される"

  section "上限を大きく超える入力"
  for v in 99999999999999999999 999999999999999999999999999999 \
           99999999999999999999d 99999999999999999999h 99999999999999999999m \
           99999999999999999999s 99999999999999999999y 99999999999999999999mo; do
    assert_eq "yes" "$(too_long "$v")" "'$v' が桁数上限で拒否される"
  done

  section "桁あふれした値が漏れない"
  # 拒否されるか、正の値かつ int64 の範囲内であること。
  INT64_MAX=9223372036854775807
  for v in 99999999999999d 9999999999999999 99999999999999h 999999999999999m \
           1234567890123456s 111111d11h11m11s 9999y 9999mo 999999999999999s; do
    r=$(duration "$SCRIPT" "$v")
    case "$r" in
      ERR*) pass "'$v' は拒否される（桁あふれ回避）" ;;
      OK\ *)
        n=${r#OK }
        if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && [ "$n" -le "$INT64_MAX" ] 2>/dev/null; then
          pass "'$v' は正の値で int64 の範囲内 ($n)"
        else
          fail "'$v' は正の値で int64 の範囲内" "桁あふれの疑いがある値: '$n'"
        fi ;;
      *) fail "'$v' の結果を取得できた" "取得結果: $r" ;;
    esac
  done

  section "極端に長い入力でハングしない"
  for n in 1000 10000 100000; do
    long=$(awk -v n="$n" 'BEGIN{ s=""; for(i=0;i<n;i++) s = s "9"; print s }')
    start=$(date +%s)
    r=$(duration "$SCRIPT" "$long")
    took=$(( $(date +%s) - start ))
    assert_match '^ERR' "$r" "${n}桁の入力が拒否される"
    if [ "$took" -le 20 ]; then pass "${n}桁の入力が20秒以内に処理される (${took}s)"
    else fail "${n}桁の入力が20秒以内に処理される" "${took}s かかった"; fi
  done
  # 長い単位表記を大量に並べた場合（正規化しても縮まない）
  vlong=$(awk 'BEGIN{ s=""; for(i=0;i<500;i++) s = s "1years"; print s }')
  assert_match '^ERR' "$(duration "$SCRIPT" "$vlong")" "'1years' を500回並べた入力が拒否される"

  section "コロン区切りの成分数"
  for n in 2 3 4 5 6; do
    v=$(awk -v n="$n" 'BEGIN{ s="1"; for(i=1;i<n;i++) s = s ":1"; print s }')
    assert_match '^OK' "$(duration "$SCRIPT" "$v")" "${n}成分 '$v' は受理される"
  done
  assert_match 'ERR.*入力形式' "$(duration "$SCRIPT" '1:1:1:1:1:1:1')" "7成分は拒否される"

  section "調整パーサの上限"
  FN=$(extract_fn "$SCRIPT" _ct_parse_adj_secs)
  if [ -z "$FN" ]; then
    skip "調整パーサの上限" "$SCRIPT に _ct_parse_adj_secs が無い"
  else
    adj() { ( OS="$(uname -s)"; eval "$FN"; _ct_parse_adj_secs "$1" 2>/dev/null ); }

    # 正規化後20文字の上限。y/mo を抽出したあとの残りには16文字の上限が別に
    # かかるため、20文字の上限に到達するには y/mo が文字を消費する形が必要。
    if [ -n "$(adj '+9999y9999mo11d11h11s')" ]; then pass "20文字ちょうどが受理される"
    else fail "20文字ちょうどが受理される" "拒否された: '+9999y9999mo11d11h11s'"; fi
    assert_eq "" "$(adj '+9999y9999mo111d11h11s')" "21文字は拒否される"
    # y/mo が無い場合は16文字の上限が先に効く
    assert_eq "" "$(adj '+99999999999999999s')" "y/mo が無い18文字は16文字上限で拒否される"

    # y/mo 抽出後16文字の上限
    assert_eq "9600030671" "$(adj '+111111d11h11m11s')" "16文字ちょうどが受理される"
    assert_eq ""           "$(adj '+1111111d11h11m11s')" "17文字は拒否される"

    # 日数14桁の上限
    assert_eq "8639999999999913600" "$(adj '+99999999999999d')" "14桁の日数が受理される"
    assert_eq ""                    "$(adj '+999999999999999d')" "15桁の日数は拒否される"

    # 年・月の4桁上限
    assert_eq "" "$(adj '+99999y')"  "5桁の年は拒否される"
    assert_eq "" "$(adj '+99999mo')" "5桁の月は拒否される"
    if [ -n "$(adj '+9999y')" ]; then pass "4桁の年が受理される"
    else fail "4桁の年が受理される" "拒否された"; fi

    # 最小値と0
    assert_eq "1"  "$(adj '+1s')" "+1s が受理される"
    assert_eq "-1" "$(adj '-1s')" "-1s が受理される"
    assert_eq ""   "$(adj '+0s')" "+0s は拒否される"
    assert_eq ""   "$(adj '-0s')" "-0s は拒否される"

    # 上限内だが長い書き方（正規化後20文字以内なら受理される）
    aref=$(adj '+1y2mo3d4h5m6s')
    if [ -z "$aref" ]; then
      fail "基準となる '+1y2mo3d4h5m6s' が解析できる" "拒否された"
    else
      for v in '+1years2months3days4hours5minutes6seconds' '+1yr2mo3d4hr5min6sec' '+1 y 2 mo 3 d 4 h 5 m 6 s'; do
        assert_eq "$aref" "$(adj "$v")" "'$v' (${#v}文字) が '+1y2mo3d4h5m6s' と同じ秒数"
      done
    fi
    assert_eq "" "$(adj '+１ｍｉｎｕｔｅ')" "全角英字の調整入力は拒否される"

    # 桁あふれが漏れないこと
    for v in '+99999999999999d' '+99999999999999h' '+999999999999999m' '+1234567890123456s'; do
      r=$(adj "$v")
      if [ -z "$r" ]; then pass "'$v' は拒否される（桁あふれ回避）"
      elif [ "$r" -gt 0 ] 2>/dev/null && [ "$r" -le 9223372036854775807 ] 2>/dev/null; then
        pass "'$v' は正の値で int64 の範囲内 ($r)"
      else
        fail "'$v' は正の値で int64 の範囲内" "桁あふれの疑いがある値: '$r'"
      fi
    done
  fi
done
