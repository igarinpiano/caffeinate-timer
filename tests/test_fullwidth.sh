#!/usr/bin/env bash
# 全角入力。
#
# 全角で打っても半角と同じ結果になることを確認する。対象は本体入力と、
# カウントダウン中の調整入力の両方。
#
# 変換表は単位表記に現れる英字だけを対象にしているため、単位語を増やしたときに
# 表の更新を忘れると全角で打てなくなる。それを検出する検査も入れてある。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

if [ -z "$CT_TARGETS" ]; then
  skip "全角入力" "$CT_OS では実行できる対象が無い"
  exit 0
fi

# 半角 → 全角（数字・記号・英字）
to_fw() {
  printf '%s' "$1" | sed \
    -e 's/0/０/g' -e 's/1/１/g' -e 's/2/２/g' -e 's/3/３/g' -e 's/4/４/g' \
    -e 's/5/５/g' -e 's/6/６/g' -e 's/7/７/g' -e 's/8/８/g' -e 's/9/９/g' \
    -e 's/:/：/g' -e 's/\./．/g' \
    -e 's/a/ａ/g' -e 's/c/ｃ/g' -e 's/d/ｄ/g' -e 's/e/ｅ/g' -e 's/h/ｈ/g' \
    -e 's/i/ｉ/g' -e 's/m/ｍ/g' -e 's/n/ｎ/g' -e 's/o/ｏ/g' -e 's/r/ｒ/g' \
    -e 's/s/ｓ/g' -e 's/t/ｔ/g' -e 's/u/ｕ/g' -e 's/y/ｙ/g'
}

# 調整入力用: 符号も全角にする
to_fw_signed() {
  to_fw "$1" | sed -e 's/^+/＋/' -e 's/^-/－/'
}

for SCRIPT in $CT_TARGETS; do
  printf '\n%s══ %s %s\n' "$_B" "$SCRIPT" "$_N"

  section "本体入力: 全角と半角で同じ結果になる"
  # 単位の1文字表記・長い表記・略記・コロン区切り・小数を網羅する
  for hw in 90 45m 1h 20s 1d 1:30 1:30:00 1h30m20s 1d3h 1:2:3:4 1.5h 1.5 \
            45min 45minutes 1hour 1hours 20sec 20seconds 1day 1days \
            1year 1years 1yr 1month 1months 2mo 1minute 1minutes 1second \
            1hour30minutes20seconds 1y2mo3d4h5m6s; do
    fw=$(to_fw "$hw")
    hw_r=$(duration "$SCRIPT" "$hw")
    fw_r=$(duration "$SCRIPT" "$fw")
    if [ "$hw_r" = "NONE" ]; then
      fail "'$hw' の半角側が解析できる" "結果を取得できなかった"
    else
      assert_eq "$hw_r" "$fw_r" "'$hw' ⇔ '$fw'"
    fi
  done

  section "本体入力: 全角の大文字も受理される"
  # 変換表は全角大文字を半角大文字へ落とし、後段の小文字化に任せる
  for pair in '1YEAR:１ＹＥＡＲ' '45MIN:４５ＭＩＮ' '1HOUR:１ＨＯＵＲ' '20SEC:２０ＳＥＣ'; do
    hw=${pair%%:*}; fw=${pair#*:}
    assert_eq "$(duration "$SCRIPT" "$hw")" "$(duration "$SCRIPT" "$fw")" "'$hw' ⇔ '$fw'"
  done

  section "本体入力: 全角スペースは無視される"
  assert_eq "$(duration "$SCRIPT" '1h30m')" "$(duration "$SCRIPT" '１ｈ　３０ｍ')" \
    "'1h30m' ⇔ '１ｈ　３０ｍ'（全角スペース入り）"

  section "本体入力: 全角でも不正な入力は拒否される"
  for fw in 'ＩＹＥＡＲ' 'ｙｅａｒ' '１ｙｅａｒ２ｙｅａｒ' '１ｈ１ｈ１ｈ' '０ｓ' 'ａｂｃ'; do
    assert_match '^ERR' "$(duration "$SCRIPT" "$fw")" "'$fw' は拒否される"
  done

  section "本体入力: 符号付きは半角でも全角でも弾かれる"
  # 符号が意味を持つのは調整入力だけ。本体入力では符号を解釈しない。
  # （変換表からも符号を外してあるため、全角の符号は半角化もされない）
  for v in '+90' '-5' '＋90' '－5' '−5' '+1h' '-1h' '＋１ｈ' '－１ｈ' \
           '+1:30' '－1:30' '+45m' '－45m' '+1y' '－1y'; do
    assert_match 'ERR.*入力形式' "$(duration "$SCRIPT" "$v")" "'$v' は本体入力では拒否される"
  done

  section "調整入力: 全角と半角で同じ結果になる"
  FN=$(extract_adj_fn "$SCRIPT")
  if ! printf '%s' "$FN" | grep -q '_ct_parse_adj_secs'; then
    skip "$SCRIPT: 調整入力の全角" "_ct_parse_adj_secs が無い"
  else
    adj() { ( OS="$(uname -s)"; eval "$FN"; _ct_parse_adj_secs "$1" 2>/dev/null ); }
    for hw in '+30m' '-1h' '+90' '+1d3h30m' '+45s' '+45min' '+1hour' '+1d' \
              '+1minute' '+20seconds' '+1yr'; do
      fw=$(to_fw_signed "$hw")
      hw_r=$(adj "$hw")
      if [ -z "$hw_r" ]; then
        fail "'$hw' の半角側が解析できる" "拒否された"
      else
        assert_eq "$hw_r" "$(adj "$fw")" "'$hw' ⇔ '$fw'"
      fi
    done

    # 全角の符号も解釈される（＋ U+FF0B / － U+FF0D / − U+2212）
    assert_eq "$(adj '+30m')" "$(adj '＋30m')"   "'+30m' ⇔ '＋30m'（全角プラス）"
    assert_eq "$(adj '-1h')"  "$(adj '－1h')"    "'-1h' ⇔ '－1h'（全角マイナス）"
    assert_eq "$(adj '-1h')"  "$(adj '−1h')"    "'-1h' ⇔ '−1h'（U+2212 マイナス）"
    assert_eq "$(adj '+30m')" "$(adj '＋３０ｍ')" "'+30m' ⇔ '＋３０ｍ'（全て全角）"
    assert_eq "$(adj '-1h')"  "$(adj '－１ｈ')"  "'-1h' ⇔ '－１ｈ'（全て全角）"

    # 符号は先頭だけを対象にする（末尾や単独は拒否）
    assert_eq "" "$(adj '30m＋')" "'30m＋'（末尾の全角プラス）は拒否される"
    assert_eq "" "$(adj '30m+')"  "'30m+'（末尾の半角プラス）は拒否される"
    assert_eq "" "$(adj '＋')"    "'＋' だけは拒否される"
    assert_eq "" "$(adj '－')"    "'－' だけは拒否される"

    # 年・月はカレンダー演算が要るため、実行環境で使える場合のみ比較する
    if [ -n "$(adj '+1y')" ]; then
      assert_eq "$(adj '+1y')"    "$(adj '＋１ｙ')"        "'+1y' ⇔ '＋１ｙ'"
      assert_eq "$(adj '+1year')" "$(adj '＋１ｙｅａｒ')" "'+1year' ⇔ '＋１ｙｅａｒ'"
    else
      skip "$SCRIPT: 調整入力の年指定" "この環境では年のカレンダー演算が使えない"
    fi

    assert_eq "" "$(adj '＋ＩＹＥＡＲ')" "'＋ＩＹＥＡＲ' は拒否される"
    assert_eq "" "$(adj '＋０ｓ')"       "'＋０ｓ' は拒否される"
  fi

  section "変換表が単位表記の全英字を網羅している"
  # 単位の正規化に使われている語から英字を集め、全角変換表に対応する
  # 全角文字が入っているかを確かめる。単位語を増やして表を更新し忘れると
  # 全角で打てなくなるため、それをここで検出する。
  missing=$(python3 - "$SCRIPT" <<'PY'
import io, re, sys

src = io.open(sys.argv[1], encoding='utf-8').read()

# 変換表（_ct_fw_to_ascii の s コマンド）から「全角→半角」の対応を集める
fn = re.search(r'_ct_fw_to_ascii\(\) \{.*?\n\}', src, re.S)
table = dict(re.findall(r"s/(.)/(.)/g", fn.group(0))) if fn else {}
mapped = set(table.values())

# 単位の正規化パターンから英字を集める（正規表現の記号は落とす）
units = re.findall(r"-e 's/([a-z?]+)/[a-z]+/g'", src)
letters = set()
for u in units:
    letters |= set(c for c in u if c.isalpha())

missing = sorted(c for c in letters if c not in mapped)
print(''.join(missing))
PY
)
  assert_eq "" "$missing" "単位表記に使う英字すべてに全角の対応がある"
done
