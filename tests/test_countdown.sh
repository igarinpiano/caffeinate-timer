#!/usr/bin/env bash
# カウントダウン中のキー入力処理。疑似端末（python3 の pty）で実スクリプトを動かし、
# 実際にキーを送って残り時間と調整入力欄を読み取る。
#
# 検出する退行:
#   - 全角の調整入力（＋１ｍ）が read -n 1 のバイト分割で捨てられ、効かない
#   - 矢印キーのエスケープシーケンス（ESC [ A）の末尾 'A' が入力欄に混入する
#   - 標準入力が EOF のとき read が即座に戻り、ループが CPU を使い切る
#   - SIGTERM / SIGKILL で本体が終わると、スリープ防止プロセスが孤児として残り
#     スリープを無期限に止め続ける
set -uo pipefail
source "$(dirname "$0")/lib.sh"

cd "$CT_ROOT"

if [ -z "$CT_TARGETS" ]; then
  skip "カウントダウンのキー入力" "$CT_OS では実行できる対象が無い"
  exit 0
fi
if ! have python3; then
  skip "カウントダウンのキー入力" "python3 が無い"
  exit 0
fi

DRIVER=$(tmpfile)
cat > "$DRIVER" <<'PY'
import os, pty, re, select, signal, sys, time

script = sys.argv[1]
keys = sys.argv[2].encode('utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8')

pid, fd = pty.fork()
if pid == 0:
    os.environ['LANG'] = 'en_US.UTF-8' if sys.platform == 'darwin' else 'C.UTF-8'
    os.environ.pop('LC_ALL', None)
    os.execvp('bash', ['bash', script])

buf = b''
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                return

pump(1.0)
os.write(fd, b'30s\r')
pump(1.5)
for ch in keys:
    os.write(fd, ch.encode('utf-8'))
    pump(0.15)
pump(1.5)
plain = re.sub(rb'\033\[[0-9;]*[A-Za-z]', b'', buf).decode('utf-8', 'replace')
rem = re.findall(r'残り: (\d\d):(\d\d):(\d\d)', plain)
field = re.findall(r'調整入力: ?([^\r\n]*)', plain)

# Ctrl+C で後始末（スリープ防止プロセスの停止）まで走らせてから閉じる
os.write(fd, b'\x03')
pump(1.0)
os.write(fd, b'\r')
pump(0.5)
for _ in range(20):
    if os.waitpid(pid, os.WNOHANG)[0] != 0:
        break
    time.sleep(0.1)
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)

secs = int(rem[-1][0]) * 3600 + int(rem[-1][1]) * 60 + int(rem[-1][2]) if rem else -1
print('%d\t%s' % (secs, field[-1].strip() if field else '<none>'))
PY

for SCRIPT in $CT_TARGETS; do
  printf '\n%s══ %s %s\n' "$_B" "$SCRIPT" "$_N"

  section "調整入力"
  r=$(python3 "$DRIVER" "$SCRIPT" '＋１ｍ\r')
  assert_between 61 90 "${r%%	*}" "全角の '＋１ｍ' で残り時間が1分延びる"

  r=$(python3 "$DRIVER" "$SCRIPT" '\033[A\033[D+1m')
  assert_eq "+1m" "${r#*	}" "矢印キーの文字が調整入力欄に混入しない"

  r=$(python3 "$DRIVER" "$SCRIPT" '\033[A+1m\r')
  assert_between 61 90 "${r%%	*}" "矢印キーの後の '+1m' が効く"

  section "標準入力が EOF のとき"
  # 3秒のタイマーを EOF の標準入力で走らせ、CPU 時間が実時間に比べて十分小さいこと。
  cpu=$(python3 - "$SCRIPT" <<'PY'
import os, resource, subprocess, sys
p = subprocess.Popen(['bash', sys.argv[1]], stdin=subprocess.PIPE,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
p.communicate(b'3s\n', timeout=30)
u = resource.getrusage(resource.RUSAGE_CHILDREN)
print(int((u.ru_utime + u.ru_stime) * 1000))
PY
)
  assert_between 0 1500 "$cpu" "EOF でもカウントダウンが CPU を使い切らない（CPU ミリ秒）"

  section "本体が kill されたときの後始末"
  for sig in TERM KILL; do
    fifo=$(tmpfile); rm -f "$fifo"; mkfifo "$fifo"
    ( printf '1h\n'; sleep 6 ) > "$fifo" &
    feeder=$!
    bash "$SCRIPT" < "$fifo" > /dev/null 2>&1 &
    target=$!
    sleep 2
    kids=$(ps -A -o pid= -o ppid= | awk -v p="$target" '$2 == p { printf "%s ", $1 }')
    kill -"$sig" "$target" 2>/dev/null
    wait "$target" 2>/dev/null
    left=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      left=""
      for k in $kids; do kill -0 "$k" 2>/dev/null && left="$left $k"; done
      [ -z "$left" ] && break
      sleep 0.2
    done
    if [ -z "$kids" ]; then
      fail "SIG$sig 後にスリープ防止プロセスが残らない" "子プロセスを特定できなかった"
    else
      assert_eq "" "$left" "SIG$sig 後にスリープ防止プロセスが残らない"
    fi
    for k in $left; do kill "$k" 2>/dev/null; done
    kill "$feeder" 2>/dev/null; wait "$feeder" 2>/dev/null
  done
done
