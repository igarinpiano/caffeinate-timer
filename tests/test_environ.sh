#!/usr/bin/env bash
# 極端な実行環境。
#
# 年/月の指定はエポック秒 →ローカル時刻の文字列 →エポック秒 の往復で計算するため、
# タイムゾーンや DST の切り替わりに影響されやすい。ここではその往復と、
# ロケール・作業ディレクトリ・PATH を変えても動くことを確認する。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

SCRIPT="$CT_SCRIPT"

section "タイムゾーンを変えても年/月が計算できる"
for tz in UTC Asia/Tokyo America/New_York America/Sao_Paulo Australia/Lord_Howe Pacific/Kiritimati Etc/GMT+12; do
  if [ ! -e "/usr/share/zoneinfo/$tz" ]; then skip "TZ=$tz" "tzdata に無い"; continue; fi
  v=$(TZ="$tz" duration_secs "$SCRIPT" '1y')
  if [ -n "$v" ]; then assert_between $((363 * DAY)) $((367 * DAY)) "$v" "TZ=$tz で '1y'"
  else fail "TZ=$tz で '1y'" "解析に失敗: $(TZ="$tz" duration "$SCRIPT" '1y')"; fi
done

section "DST 境界を跨ぐ往復計算"
# エポック秒 → ローカル時刻 → 相対加算 → エポック秒 の往復が、
# 時刻が重複・欠落する瞬間でも破綻しないことを確認する。
# （実行時刻を偽装できないため、日時計算の形だけを直接検証する）
if [ "$CT_OS" = linux ]; then
  roundtrip() { # tz epoch years months -> 秒数 or 空
    local tz="$1" e="$2" y="$3" m="$4" base rel="" out
    base=$(TZ="$tz" date -d "@$e" '+%Y-%m-%d %H:%M:%S') || return 1
    [ "$y" -gt 0 ] && rel="${rel}+${y} years "
    [ "$m" -gt 0 ] && rel="${rel}+${m} months "
    out=$(TZ="$tz" date -d "${rel}${base}" +%s 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%d' $(( out - e ))
  }
  # 米国の秋の巻き戻し / 春の進み、月末、うるう日
  for e in 1762063200 1772953200 1769904000 1835395200; do
    for tz in America/New_York Australia/Lord_Howe Asia/Tokyo; do
      [ -e "/usr/share/zoneinfo/$tz" ] || continue
      lbl="$tz @$(TZ=$tz date -d "@$e" '+%F %T')"
      d=$(roundtrip "$tz" "$e" 0 1) && assert_between $((27 * DAY)) $((32 * DAY)) "$d" "+1ヶ月: $lbl" \
        || fail "+1ヶ月: $lbl" "往復計算が失敗した"
      d=$(roundtrip "$tz" "$e" 0 2) && assert_between $((57 * DAY)) $((63 * DAY)) "$d" "+2ヶ月: $lbl" \
        || fail "+2ヶ月: $lbl" "往復計算が失敗した"
      d=$(roundtrip "$tz" "$e" 1 0) && assert_between $((364 * DAY)) $((367 * DAY)) "$d" "+1年:   $lbl" \
        || fail "+1年: $lbl" "往復計算が失敗した"
    done
  done
else
  skip "DST 境界の往復計算" "GNU date 経路のみ対象"
fi

section "ロケールを変えても動く"
for loc in C C.UTF-8 C.utf8 en_US.UTF-8 ja_JP.UTF-8 de_DE.UTF-8; do
  if ! locale -a 2>/dev/null | grep -qix "$(printf '%s' "$loc" | tr -d '-' )\|$loc"; then
    skip "LC_ALL=$loc" "未インストール"; continue
  fi
  a=$(LC_ALL="$loc" LANG="$loc" duration_secs "$SCRIPT" '1:30')
  b=$(LC_ALL="$loc" LANG="$loc" duration_secs "$SCRIPT" '1y')
  if [ "$a" = "90" ] && [ -n "$b" ]; then pass "LC_ALL=$loc で '1:30' と '1y' が解析できる"
  else fail "LC_ALL=$loc で '1:30' と '1y' が解析できる" "1:30 → '${a:-失敗}' / 1y → '${b:-失敗}'"; fi
done

section "作業ディレクトリに依存しない"
tmp=$(mktemp -d); CT_TMPFILES+=("$tmp")
odd="$tmp/dir with space & (paren)"
mkdir -p "$odd"
r=$(cd "$odd" && duration_secs "$CT_ROOT/$SCRIPT" '1:30')
assert_eq "90" "$r" "スペース・記号を含むディレクトリから起動できる"

r=$(cd / && duration_secs "$CT_ROOT/$SCRIPT" '45m')
assert_eq "2700" "$r" "ルートディレクトリから起動できる"

section "スクリプト自身のパスに記号が含まれても動く"
weird="$tmp/Program Files (x86)/caffeinate & co"
mkdir -p "$weird"
cp "$SCRIPT" "$weird/"
r=$(duration_secs "$weird/$SCRIPT" '1h')
assert_eq "3600" "$r" "括弧・アンパサンドを含むパスから起動できる"

section "最小構成の PATH"
r=$(PATH=/usr/bin:/bin duration_secs "$SCRIPT" '1:30')
assert_eq "90" "$r" "PATH=/usr/bin:/bin で動く"

# スリープ防止コマンドが無い環境でも、時間解析まで到達すること。
stub=$(mktemp -d); CT_TMPFILES+=("$stub")
for need in date bash sed awk tr printf grep cat mktemp; do
  p=$(command -v "$need" 2>/dev/null) && ln -sf "$p" "$stub/$need"
done
r=$(PATH="$stub" duration_secs "$SCRIPT" '1:30' 2>/dev/null)
if [ "$r" = "90" ]; then pass "systemd-inhibit / caffeinate が無くても解析できる"
else skip "systemd-inhibit / caffeinate が無くても解析できる" "最小 PATH では起動不可: '${r:-失敗}'"; fi

section "標準入力が端末でなくても動く"
r=$(printf '1:30\n\n' | timeout 15 bash "$SCRIPT" < <(printf '1:30\n\n') 2>&1 \
    | sed -n '/継続時間\|❌/{p;q;}' | sed 's/\x1b\[[0-9;]*m//g')
assert_match '継続時間' "$r" "パイプ経由の入力を処理できる"

section "TERM が未設定・dumb でも動く"
for t in "" dumb xterm-256color; do
  r=$(TERM="$t" duration_secs "$SCRIPT" '1:30')
  assert_eq "90" "$r" "TERM='${t:-(空)}' で動く"
done
