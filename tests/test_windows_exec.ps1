#!/usr/bin/env pwsh
# caffeinate-timer-windows.bat を実際に実行して検証する（Windows 専用）。
#
# tests/test_windows.sh が静的検査（改行・マーカー・5.1 互換性）を担当し、
# こちらは実機で本当に起動して正しい秒数を出すかを見る。
#
# タイマー本体を走らせないために、受理される入力は /bg を付けて呼ぶ。
# /bg は同じ解析経路を通ったうえでバックグラウンドへ渡して即終了するため、
# 継続時間の表示まで確認できる。拒否される入力はそのまま渡せば即終了する。
# 実際のカウントダウンは 2 秒の指定で1度だけ通す。
#
# 備考: /bg で起動した子プロセスは指定時間だけ待機したまま残る。
#       使い捨ての CI ランナー前提の割り切りで、最後にまとめて後始末する。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root     = Split-Path -Parent $TestsDir
$Bat      = Join-Path $Root 'caffeinate-timer-windows.bat'
$LauncherJs = Join-Path $Root 'bin/caffeinate-timer.js'
$CmdExe   = Join-Path $env:SystemRoot 'System32\cmd.exe'

$script:P = 0; $script:F = 0; $script:S = 0
$script:StartedPids = @()

function Section([string]$t) { Write-Host ''; Write-Host $t }
function Pass([string]$t) { $script:P++; Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Fail([string]$t, [string]$d = '') {
  $script:F++
  Write-Host "  [ NG ] $t" -ForegroundColor Red
  if ($d) { foreach ($l in ($d -split "`r?`n")) { Write-Host "         $l" -ForegroundColor DarkGray } }
}
function Skip([string]$t, [string]$r) { $script:S++; Write-Host "  [ -- ] $t ($r)" -ForegroundColor Yellow }

function AssertEq([string]$expected, [string]$actual, [string]$label) {
  if ($expected -eq $actual) { Pass $label }
  else { Fail $label "expected: $expected`nactual:   $actual" }
}
function AssertMatch([string]$pattern, [string]$actual, [string]$label) {
  if ($actual -match $pattern) { Pass $label }
  else { Fail $label "pattern: $pattern`nactual:  $actual" }
}
function AssertNotMatch([string]$pattern, [string]$actual, [string]$label) {
  if ($actual -notmatch $pattern) { Pass $label }
  else { Fail $label "must NOT match: $pattern`nactual:         $actual" }
}

# ── 対象を起動して標準出力を丸ごと取得する ──────────────────────────────
function Invoke-Target {
  param(
    [string]   $InputText,
    [string]   $FileName = $CmdExe,
    [string]   $Arguments = ('/d /s /c ""{0}""' -f $Bat),
    [int]      $TimeoutSec = 60,
    [string]   $WorkingDirectory = $Root
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $FileName
  $psi.Arguments              = $Arguments
  $psi.WorkingDirectory       = $WorkingDirectory
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

  $proc = [System.Diagnostics.Process]::Start($psi)
  $script:StartedPids += $proc.Id

  # 入力1行 + 「Enterで閉じる」用の1行
  try {
    $proc.StandardInput.WriteLine($InputText)
    $proc.StandardInput.WriteLine('')
    $proc.StandardInput.Flush()
  } catch { }

  $so = $proc.StandardOutput.ReadToEndAsync()
  $se = $proc.StandardError.ReadToEndAsync()

  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch { }
    return [pscustomobject]@{ Text = '<TIMEOUT>'; Exit = -1; TimedOut = $true }
  }
  $text = ''
  try { $text = $so.Result + $se.Result } catch { }
  # ANSI エスケープを落として改行を正規化する
  $text = [regex]::Replace($text, "$([char]27)\[[0-9;]*[A-Za-z]", '')
  return [pscustomobject]@{ Text = $text; Exit = $proc.ExitCode; TimedOut = $false }
}

# 継続時間の秒数だけを取り出す（取れなければ空文字）
function Get-Seconds([string]$text) {
  $m = [regex]::Match($text, '\((\d+)秒\)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# 受理される入力: /bg を付けて解析だけ通す
function Parse-Ok([string]$value, [int]$TimeoutSec = 60) {
  $r = Invoke-Target -InputText ('/bg ' + $value) -TimeoutSec $TimeoutSec
  return [pscustomobject]@{ Secs = (Get-Seconds $r.Text); Raw = $r.Text; TimedOut = $r.TimedOut }
}

# 拒否される入力: そのまま渡す
function Parse-Err([string]$value, [int]$TimeoutSec = 60) {
  $r = Invoke-Target -InputText $value -TimeoutSec $TimeoutSec
  $m = [regex]::Match($r.Text, '❌\s*(.+)')
  $msg = ''
  if ($m.Success) { $msg = $m.Groups[1].Value.Trim() }
  return [pscustomobject]@{ Msg = $msg; Raw = $r.Text; TimedOut = $r.TimedOut }
}

function OkCase([string]$value, [string]$expected) {
  $r = Parse-Ok $value
  if ($r.TimedOut) { Fail "入力 '$value' → $expected 秒" 'タイムアウトした'; return }
  AssertEq $expected $r.Secs "入力 '$value' → $expected 秒"
}
function ErrCase([string]$value, [string]$expected) {
  $r = Parse-Err $value
  if ($r.TimedOut) { Fail "入力 '$value' → エラー ($expected)" 'タイムアウトした'; return }
  if ($r.Msg -like "*$expected*") { Pass "入力 '$value' → エラー ($expected)" }
  else { Fail "入力 '$value' → エラー ($expected)" ("実際のメッセージ: '" + $r.Msg + "'`n出力: " + ($r.Raw -replace "`r?`n", ' / ')) }
}

Write-Host ("対象: {0}" -f $Bat)
Write-Host ("PowerShell: {0} / OS: {1}" -f $PSVersionTable.PSVersion, [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)

if (-not (Test-Path $Bat)) { Fail '.bat が存在する' $Bat; exit 1 }
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
  Skip 'Windows 実行テスト' 'Windows 以外では実行できない'
  exit 0
}

# ── まず素の起動が成立するか ────────────────────────────────────────────
Section '起動と終了'
$boot = Invoke-Target -InputText 'garbage'
if ($boot.TimedOut) {
  Fail '.bat が起動して終了する' 'タイムアウトした（起動できていない可能性）'
} elseif ($boot.Text -match 'Failed to (locate|load) the embedded script') {
  Fail '.bat が起動して終了する' ("埋め込みスクリプトの取り出しに失敗:`n" + $boot.Text)
} elseif ($boot.Text -match 'Caffeinate') {
  Pass '.bat が起動してヘッダーを表示する'
} else {
  Fail '.bat が起動してヘッダーを表示する' ("出力:`n" + $boot.Text)
}
AssertMatch '時間を入力してください' $boot.Text '入力画面が表示される'
AssertNotMatch 'ParserError|UnexpectedToken|not recognized' $boot.Text 'パースエラーや未解決コマンドが出ない'

Section '基本の形式（bash 版と同じ値になること）'
OkCase '90'         '5400'
OkCase '45m'        '2700'
OkCase '1h'         '3600'
OkCase '20s'        '20'
OkCase '1:30'       '90'
OkCase '1:30:00'    '5400'
OkCase '1h30m20s'   '5420'
OkCase '1d'         '86400'
OkCase '1d3h'       '97200'
OkCase '1:2:3:4'    '93784'
OkCase '1.5h'       '5400'
OkCase '1.5'        '90'
OkCase '45min'      '2700'
OkCase '1hour'      '3600'

Section '全角・空白・先頭ゼロの正規化'
OkCase '１：３０'   '90'
OkCase '９０'       '5400'
OkCase '００９０'   '5400'
OkCase '0090'       '5400'

Section 'カレンダー演算（年・月）'
foreach ($c in @(@('1y', 363, 367), @('2mo', 57, 63), @('1y2mo', 420, 432))) {
  $r = Parse-Ok $c[0]
  if ($r.Secs -eq '') {
    Fail ("入力 '{0}' が受理される" -f $c[0]) ("出力: " + ($r.Raw -replace "`r?`n", ' / '))
  } else {
    $days = [long]$r.Secs / 86400
    if ($days -ge $c[1] -and $days -le $c[2]) { Pass ("入力 '{0}' はおよそ {1}〜{2} 日 ({3} 秒)" -f $c[0], $c[1], $c[2], $r.Secs) }
    else { Fail ("入力 '{0}' はおよそ {1}〜{2} 日" -f $c[0], $c[1], $c[2]) ("実際: {0} 秒 = {1:N1} 日" -f $r.Secs, $days) }
  }
}

Section 'ゼロ・不正な形式の拒否'
ErrCase '0'       '0秒以下'
ErrCase '0s'      '0秒以下'
ErrCase 'garbage' '入力形式'
ErrCase '1x'      '入力形式'
ErrCase '-5'      '入力形式'
ErrCase '1:2:3:4:5:6:7' '入力形式'

Section '桁数の上限（上限ちょうどは受理、1つ超えたら拒否）'
OkCase  '111111d11h11m11s' '9600030671'
ErrCase '1111111d11h11m11s' '長すぎ'
ErrCase '999999999999999d'  '長すぎ'
ErrCase '99999y'            '長すぎ'
ErrCase '99999mo'           '長すぎ'
ErrCase '99999999999999999999' '長すぎ'
OkCase  '1s' '1'

Section '最大秒数（.bat は DateTime.MaxValue = 西暦9999年まで）'
# .command / .sh は16桁エポック（≒西暦約3億年）まで許すため、ここは .bat 固有の挙動。
# 桁数上限は通るが西暦9999年を超える指定は「最大時間」で弾かれる。
ErrCase '99999999999999d'  '最大時間'
ErrCase '9999y'            '最大時間'
ErrCase '999999999999999s' '最大時間'
# 9999ヶ月 = 約833年後なので西暦9999年には収まる（受理が正しい）
$r = Parse-Ok '9999mo'
if ($r.Secs -eq '') { Fail "'9999mo' が受理される" ("出力: " + ($r.Raw -replace "`r?`n", ' / ')) }
else { Pass ("'9999mo' が受理される ({0} 秒)" -f $r.Secs) }
# 西暦9999年に収まる範囲は受理される
$r = Parse-Ok '7000y'
if ($r.Secs -eq '') { Fail "'7000y' が受理される" ("出力: " + ($r.Raw -replace "`r?`n", ' / ')) }
else { Pass ("'7000y' が受理される ({0} 秒)" -f $r.Secs) }
OkCase '1000d' '86400000'

Section '上限内だが非常に長い書き方'
# 単位の長い表記・空白・先頭ゼロは正規化で縮むため、生の入力が長くても上限内。
# 短い等価表記と同じ秒数になることを確認する。
$ref = (Parse-Ok '1:2:3:4:5:6').Secs
if ($ref -eq '') {
  Fail "基準となる '1:2:3:4:5:6' が解析できる" '解析に失敗した'
} else {
  foreach ($v in @(
    '1years2months3days4hours5minutes6seconds',
    '1year2month3day4hour5minute6second',
    '1yr2mo3d4hr5min6sec',
    '1 y 2 mo 3 d 4 h 5 m 6 s',
    '1y 2mo 3d 4h 5m 6s'
  )) {
    $got = (Parse-Ok $v).Secs
    AssertEq $ref $got ("'{0}' ({1}文字) が '1:2:3:4:5:6' と同じ秒数" -f $v, $v.Length)
  }
}
OkCase '45minutes' '2700'
OkCase '1hours30minutes20seconds' '5420'
OkCase '1YEAR' '31536000'
OkCase '1MINUTES' '60'
foreach ($n in @(30, 100, 1000)) {
  $z = ('0' * $n) + '90'
  AssertEq '5400' (Parse-Ok $z).Secs "先頭ゼロ${n}個 + '90' が5400秒"
}

Section '全角入力'
# 全角で打っても半角と同じ結果になること（数字・記号・英字・全角スペース）。
foreach ($pair in @(
  @('90',        '９０'),
  @('1:30',      '１：３０'),
  @('45m',       '４５ｍ'),
  @('1.5h',      '１．５ｈ'),
  @('45minutes', '４５ｍｉｎｕｔｅｓ'),
  @('1year',     '１ｙｅａｒ'),
  @('1month',    '１ｍｏｎｔｈ'),
  @('20seconds', '２０ｓｅｃｏｎｄｓ'),
  @('1hour30minutes20seconds', '１ｈｏｕｒ３０ｍｉｎｕｔｅｓ２０ｓｅｃｏｎｄｓ'),
  @('1YEAR',     '１ＹＥＡＲ')
)) {
  $hw = (Parse-Ok $pair[0]).Secs
  $fw = (Parse-Ok $pair[1]).Secs
  if ($hw -eq '') { Fail ("'{0}' の半角側が解析できる" -f $pair[0]) '秒数を取得できなかった' }
  else { AssertEq $hw $fw ("'{0}' ⇔ '{1}'" -f $pair[0], $pair[1]) }
}
AssertEq (Parse-Ok '1h30m').Secs (Parse-Ok '１ｈ　３０ｍ').Secs "'1h30m' ⇔ '１ｈ　３０ｍ'（全角スペース入り）"

Section '本体入力では符号付きを弾く（半角・全角とも）'
# 符号が意味を持つのは実行中の調整入力だけ。本体入力では解釈しない。
foreach ($v in @('+90', '-5', '＋90', '－5', '−5', '+1h', '-1h', '＋１ｈ', '－１ｈ',
                 '+1:30', '－1:30', '+45m', '－45m')) {
  ErrCase $v '入力形式'
}

Section '長いが正規化されない書き方は拒否される'
# 単位語として解釈できない綴りや、同じ単位の重複はパターンに一致しない。
# 弾くのが正しい挙動。
foreach ($v in @('oneyear', '1year2year', '1years2years3years4years',
                 '1h1h1h', '1m1m1m1m1m', '1mo1mo', 'ＩＹＥＡＲ', 'ｙｅａｒ')) {
  ErrCase $v '入力形式'
}
$vlong = '1years' * 500
ErrCase $vlong '長すぎ'

Section '極端に長い入力'
foreach ($n in @(1000, 10000)) {
  $long = '9' * $n
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r = Parse-Err $long
  $sw.Stop()
  if ($r.TimedOut) { Fail "${n}桁の入力が拒否される" 'タイムアウトした'; continue }
  if ($r.Msg -like '*長すぎ*') { Pass "${n}桁の入力が拒否される ($([int]$sw.Elapsed.TotalSeconds)s)" }
  else { Fail "${n}桁の入力が拒否される" ("メッセージ: '" + $r.Msg + "'") }
}

Section '入力はコマンドとして評価されない'
$canary = Join-Path $env:TEMP ('ct-canary-' + [guid]::NewGuid().ToString('N') + '.txt')
foreach ($payload in @(
  ('90 & echo pwned > "' + $canary + '"'),
  ('90; New-Item -Path "' + $canary + '" -ItemType File'),
  ('$(New-Item -Path "' + $canary + '" -ItemType File)'),
  ('90 | Out-File "' + $canary + '"')
)) {
  [void](Invoke-Target -InputText $payload)
  if (Test-Path $canary) {
    Fail "入力がコマンドとして実行されない" ("実行された: " + $payload)
    Remove-Item $canary -Force -ErrorAction SilentlyContinue
  } else {
    Pass "入力がコマンドとして実行されない: $($payload.Substring(0, [Math]::Min(28, $payload.Length)))…"
  }
}

Section 'カウントダウンを実際に完走する'
$run = Invoke-Target -InputText '2s' -TimeoutSec 90
if ($run.TimedOut) {
  Fail '2秒のタイマーが完走する' 'タイムアウトした'
} else {
  AssertMatch '継続時間'   $run.Text '2秒のタイマーが継続時間を表示する'
  AssertMatch '終了しました' $run.Text '2秒のタイマーが終了メッセージを表示する'
  AssertEq '2' (Get-Seconds $run.Text) '2秒として解釈される'
  AssertNotMatch 'ParserError|Exception|例外' $run.Text 'カウントダウン中に例外が出ない'
}

Section 'Ctrl+C の受け取り方が設定されている'
AssertMatch '中断' $run.Text '中断方法が案内される'

Section 'コンソールのコードページを元に戻す'
# .bat は chcp 65001 に切り替えるため、終了後に元へ戻すことを確認する。
$before = (& chcp.com) -replace '[^0-9]', ''
[void](Invoke-Target -InputText 'garbage')
$after = (& chcp.com) -replace '[^0-9]', ''
AssertEq $before $after "実行後もコードページが $before のまま"

Section 'npm 経由の起動（bin/caffeinate-timer.js）'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Skip 'node 経由の起動' 'node が無い'
} else {
  $r = Invoke-Target -InputText '/bg 90' -FileName 'node' -Arguments ('"{0}"' -f $LauncherJs)
  if ($r.TimedOut) { Fail 'node 経由で .bat が起動する' 'タイムアウトした' }
  else {
    AssertEq '5400' (Get-Seconds $r.Text) 'node 経由でも 90 → 5400 秒'
    AssertNotMatch 'is not recognized|見つかりません' $r.Text 'パス解決に失敗しない'
  }
}

Section '記号を含むパスからの起動'
# npm のインストール先は選べないため、実際に厄介なパスへ複製して確認する。
$odd = Join-Path $env:TEMP ('Program Files (x86)\caffeinate & co\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $odd 'bin') -Force | Out-Null
Copy-Item $Bat -Destination $odd -Force
Copy-Item $LauncherJs -Destination (Join-Path $odd 'bin') -Force
$oddBat = Join-Path $odd 'caffeinate-timer-windows.bat'

$r = Invoke-Target -InputText '/bg 90' -Arguments ('/d /s /c ""{0}""' -f $oddBat) -WorkingDirectory $odd
if ($r.TimedOut) { Fail '括弧とアンパサンドを含むパスから起動できる' 'タイムアウトした' }
else { AssertEq '5400' (Get-Seconds $r.Text) '括弧とアンパサンドを含むパスから起動できる' }

if (Get-Command node -ErrorAction SilentlyContinue) {
  $r = Invoke-Target -InputText '/bg 90' -FileName 'node' `
        -Arguments ('"{0}"' -f (Join-Path $odd 'bin\caffeinate-timer.js')) -WorkingDirectory $odd
  if ($r.TimedOut) { Fail 'node 経由でも記号を含むパスから起動できる' 'タイムアウトした' }
  else { AssertEq '5400' (Get-Seconds $r.Text) 'node 経由でも記号を含むパスから起動できる' }
}

Section '/wait と /settings'
$r = Invoke-Target -InputText '/wait definitely-no-such-process-xyz'
AssertMatch '見つかりません' $r.Text '存在しないプロセス名を指定するとエラーになる'
$r = Invoke-Target -InputText '/wait 0'
AssertMatch '無効なPID' $r.Text 'PID 0 は拒否される'
$r = Invoke-Target -InputText '/wait not/a/name'
AssertMatch '使用できない文字' $r.Text '不正な文字を含むプロセス名は拒否される'
$r = Invoke-Target -InputText '/settings'
AssertMatch '現在のバージョン' $r.Text '/settings が設定画面を表示する'

# ── 後始末 ──────────────────────────────────────────────────────────────
Remove-Item $odd -Recurse -Force -ErrorAction SilentlyContinue
foreach ($p in $script:StartedPids) {
  try { & taskkill.exe /T /F /PID $p 2>&1 | Out-Null } catch { }
}

Write-Host ''
Write-Host '────────────────────────────────────────'
$summary = "$($script:P) passed"
if ($script:F -gt 0) { $summary += " / $($script:F) failed" }
if ($script:S -gt 0) { $summary += " / $($script:S) skipped" }
Write-Host $summary
if ($script:F -gt 0) { exit 1 }
exit 0
