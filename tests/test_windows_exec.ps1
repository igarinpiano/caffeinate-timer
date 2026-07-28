#!/usr/bin/env pwsh
# caffeinate-timer-windows.bat を実際に実行して検証する（Windows 専用）。
#
# tests/test_windows.sh が静的検査（改行・マーカー・5.1 互換性）を担当し、
# こちらは実機で本当に起動して正しい秒数を出すかを見る。
#
# タイマー本体は走らせない。出力を一時ファイルへ流し、継続時間かエラーの行が
# 出た時点でプロセスツリーを taskkill する（bash 側の duration() と同じ方式）。
#
# 以前は受理される入力ごとに /bg を使っていたが、/bg は指定時間だけ待機する
# バックグラウンドの PowerShell を起こすため、100件規模だと待機プロセスが数十個
# 残り、それぞれが Add-Type で C# をコンパイルして CPU を奪い合う。結果として
# Windows ジョブが25分の上限に達して打ち切られた。マーカー検出で即 kill する
# 方式なら子プロセスは生まれず、残留もしない。
#
# /bg 自体は専用のケースで1度だけ確認する。カウントダウンの完走も1度だけ通す。
# 1件あたりの所要時間が読みにくい環境向けに、節ごとの経過時間を出力する。
#
# ジョブが上限で打ち切られると Actions はログを1行も保存しないため、原因を
# 追えないまま25分を捨てることになる。それを避けるための作りが3つある:
#   1. 出力の取り込み部分を、プロセスを起動せず合成バイト列で先に検査する。
#   2. 続けて1件だけ起動し、マーカーを検出できるか・1件何秒かかるかを測る。
#      検出できなければ出力を16進とデコード結果ごと出して即座に終わる。
#   3. 予算（$BudgetSec）を超えたら自分から打ち切り、そこまでの結果を残す。
# 1件あたりの待ち時間も90秒から25秒へ下げてある（解析結果は数秒で出る）。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root       = Split-Path -Parent $TestsDir
$Bat        = Join-Path $Root 'caffeinate-timer-windows.bat'
$LauncherJs = Join-Path $Root 'bin/caffeinate-timer.js'
$CmdExe     = Join-Path $env:SystemRoot 'System32\cmd.exe'

$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
# PID ではなく Process をそのまま持つ。ハンドルを開いたままにしておくと
# Windows がその PID を再利用しないため、後始末の taskkill が「終了済みの
# PID を再利用した無関係のプロセス」を落とす事故を防げる。
$script:StartedProcs = @()
$script:Sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:SectionAt = 0.0

# 出力の取り込みを「どのコードページで書かれたか」に依存させない。
# .bat は chcp 65001 を試みるが、コンソールを持たない子プロセスでは chcp が
# 効かず、PowerShell の出力が ANSI/OEM で書かれることがある。それを UTF-8 と
# して読むと日本語が化けてマーカーに一致せず、全ケースがタイムアウト待ちに
# 落ちる（1件90秒 × 全件で25分の上限に達し、ジョブが打ち切られる）。
# 候補のエンコーディングを順に試し、マーカーが現れたものを採用する。
try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
$script:Encodings = @()
foreach ($cp in @(65001, 932, 1252, 437)) {
  try { $script:Encodings += [Text.Encoding]::GetEncoding($cp) } catch { }
}
# 打ち切り判定に使うマーカー。❌(U+274C) は CP932 に存在しないため、chcp が
# 効かず CP932 で書かれた場合は '?' に落ちて検出できない。エラー行は必ず
# ${RED} を伴う（.bat 内の ${RED} 18箇所すべてが ❌ の行）ので、ASCII で
# あるぶん確実に残る赤の ANSI エスケープを併用する。
$script:Marker = "継続時間|❌|$([char]27)\[0;31m"
# エンコーディングの判定に使うのは日本語の本文だけ。ASCII のエスケープは
# どの候補でも一致してしまい、正しいコードページを選べない。
$script:TextMarker = '継続時間|時間を入力'

# ジョブが上限で打ち切られると Actions にログが1行も残らず原因が追えない。
# 上限より手前で自分から打ち切り、そこまでの結果を必ず出力する。
$script:BudgetSec = 900

# 子プロセスにコンソールを割り当てるか。割り当てると .bat の chcp 65001 が
# 効く一方、PowerShell の Read-Host が新しいコンソールの入力を見てしまい、
# リダイレクトした標準入力が届かなくなることがある（届かないと空入力として
# 扱われ、入力画面を描き直す無限ループになる）。どちらが正しいかは環境依存
# なので、事前確認で実際に両方試して決める。
$script:AllocConsole = $false

function Section([string]$t) {
  $now = $script:Sw.Elapsed.TotalSeconds
  if ($script:SectionAt -gt 0) {
    Write-Host ('    ({0:N1}s)' -f ($now - $script:SectionAt)) -ForegroundColor DarkGray
  }
  $script:SectionAt = $now
  Write-Host ''
  Write-Host $t
  Assert-Budget
}
function Pass([string]$t) { $script:Passed++; Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Fail([string]$t, [string]$d = '') {
  $script:Failed++
  Write-Host "  [ NG ] $t" -ForegroundColor Red
  if ($d) { foreach ($l in ($d -split "`r?`n")) { Write-Host "         $l" -ForegroundColor DarkGray } }
}
function Skip([string]$t, [string]$r) { $script:Skipped++; Write-Host "  [ -- ] $t ($r)" -ForegroundColor Yellow }

function Write-Summary {
  Write-Host ''
  Write-Host '────────────────────────────────────────'
  $summary = "$($script:Passed) passed"
  if ($script:Failed -gt 0) { $summary += " / $($script:Failed) failed" }
  if ($script:Skipped -gt 0) { $summary += " / $($script:Skipped) skipped" }
  Write-Host ('{0}   (合計 {1:N1}s)' -f $summary, $script:Sw.Elapsed.TotalSeconds)
}

# ジョブの上限に達すると Actions はログを一切保存しないため、原因調査ができない。
# 手前で自分から打ち切り、そこまでの結果と経過時間を必ず残す。
function Assert-Budget {
  if ($script:Sw.Elapsed.TotalSeconds -lt $script:BudgetSec) { return }
  Write-Host ''
  Write-Host ('!! 時間予算 {0}s を超えたため打ち切ります。' -f $script:BudgetSec) -ForegroundColor Red
  Write-Host '   1件あたりの起動が想定より遅いか、マーカーを検出できていません。' -ForegroundColor Red
  Write-Summary
  exit 1
}

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

# ── 出力の取り込み ──────────────────────────────────────────────────────
# 書き込み中のファイルを読む。
# [IO.File]::ReadAllBytes は FileShare.Read で開くため、cmd がリダイレクト先を
# 書き込み用に握っている間は共有違反になる。待機中のポーリングがこれで毎回空を
# 返していたので、カウントダウンが続くケース（長い時間を指定した場合）は
# 継続時間の行を見つけられず、値は正しいのにタイムアウト扱いになっていた。
# 短い時間ならプロセスが終了してファイルが閉じるため、最後の読み出しだけは
# 成功する。それで '1s' や '20s' は通り、'90' や '1000d' は落ちていた。
function Get-CaptureBytes([string]$path, [int]$Retries = 1) {
  for ($i = 0; $i -lt $Retries; $i++) {
    try {
      $fs = New-Object IO.FileStream(
        $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      try {
        $ms = New-Object IO.MemoryStream
        try { $fs.CopyTo($ms); return ,$ms.ToArray() } finally { $ms.Dispose() }
      } finally { $fs.Dispose() }
    } catch { }
    if ($i -lt ($Retries - 1)) { Start-Sleep -Milliseconds 120 }
  }
  return ,([byte[]]@())
}

# マーカーが現れるデコード結果を優先し、無ければ最初の候補を返す
function ConvertFrom-CaptureBytes([byte[]]$bytes) {
  if (-not $bytes -or $bytes.Length -eq 0) { return '' }
  $first = ''
  foreach ($enc in $script:Encodings) {
    $t = ''
    try { $t = $enc.GetString($bytes) } catch { continue }
    $t = $t.TrimStart([char]0xFEFF)
    if ($t -match $script:TextMarker) { return $t }
    if ($first -eq '') { $first = $t }
  }
  return $first
}

# マーカーを検出できなかったときに原因を切り分けるための生データ
function Format-CaptureDiagnostics([byte[]]$bytes) {
  if (-not $bytes -or $bytes.Length -eq 0) { return '(出力が空)' }
  $n     = [Math]::Min(120, $bytes.Length)
  $hex   = (($bytes[0..($n - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' ')
  $lines = @(("バイト数: {0}" -f $bytes.Length), ("先頭 {0}B: {1}" -f $n, $hex))

  # 各候補のデコード結果を短く並べ、どのコードページで書かれたかを見分ける
  foreach ($enc in $script:Encodings) {
    $t = ''
    try { $t = $enc.GetString($bytes) } catch { continue }
    $t = ($t -replace "`r?`n", ' / ')
    if ($t.Length -gt 120) { $t = $t.Substring(0, 120) + '…' }
    $lines += ("{0}: {1}" -f $enc.WebName, $t)
  }

  # 採用したデコード結果は長めに出す。入力画面が何度も描き直されていれば
  # 標準入力が届いていない（空入力として扱われている）ことが分かる。
  $body = ConvertFrom-CaptureBytes $bytes
  $lines += ("入力画面の出現回数: {0}" -f ([regex]::Matches($body, '時間を入力してください')).Count)
  $lines += ("エラー行の出現回数: {0}" -f ([regex]::Matches($body, "❌|$([char]27)\[0;31m")).Count)
  $flat = ($body -replace "`r?`n", ' / ')
  if ($flat.Length -gt 1800) { $flat = $flat.Substring(0, 1800) + '…' }
  $lines += ('本文: ' + $flat)
  return ($lines -join "`n")
}

# ── 対象を起動し、必要な行が出た時点で止めて出力を返す ────────────────
# 常に cmd 経由で起動し、出力はファイルへリダイレクトしてそれを監視する。
# node 経由の起動も同じ枠組みで扱えるよう、$Command は cmd へ渡すコマンド行。
function Invoke-Target {
  param(
    [string] $InputText,
    [string] $Command = '',
    [int]    $TimeoutSec = 25,
    [string] $WorkingDirectory = $Root,
    [string] $UntilPattern = '',    # この正規表現が出た時点で打ち切る
    [object] $AllocConsole = $null, # 既定は $script:AllocConsole（事前確認で決める）
    [switch] $WaitForExit           # プロセスの終了そのものを見たいときだけ使う
  )
  if (-not $Command)      { $Command = '"{0}"' -f $Bat }
  if (-not $UntilPattern) { $UntilPattern = $script:Marker }
  if ($null -eq $AllocConsole) { $AllocConsole = $script:AllocConsole }
  $out = Join-Path ([IO.Path]::GetTempPath()) ('ct-' + [guid]::NewGuid().ToString('N') + '.log')
  # /s は remainder の最初と最後の引用符だけを外すので、内側の引用は残る
  $arguments = '/d /s /c "{0} > "{1}" 2>&1"' -f $Command, $out

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName              = $CmdExe
  $psi.Arguments             = $arguments
  $psi.WorkingDirectory      = $WorkingDirectory
  $psi.UseShellExecute       = $false
  $psi.CreateNoWindow        = -not [bool]$AllocConsole
  $psi.RedirectStandardInput = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  if ($WaitForExit) { $script:StartedProcs += $proc }
  try {
    $proc.StandardInput.WriteLine($InputText)
    $proc.StandardInput.WriteLine('')
    $proc.StandardInput.Flush()
  } catch { }

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $found    = $false
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if (-not $WaitForExit) {
      if ((ConvertFrom-CaptureBytes (Get-CaptureBytes $out)) -match $UntilPattern) {
        $found = $true; break
      }
    }
    Start-Sleep -Milliseconds 150
  }
  $timedOut = (-not $found) -and (-not $proc.HasExited)
  if (-not $proc.HasExited) {
    try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch { }
    try { [void]$proc.WaitForExit(5000) } catch { }
  }

  $bytes = Get-CaptureBytes $out 12
  $text  = ConvertFrom-CaptureBytes $bytes
  Remove-Item $out -Force -ErrorAction SilentlyContinue
  $text = [regex]::Replace($text, "$([char]27)\[[0-9;]*[A-Za-z]", '')
  return [pscustomobject]@{ Text = $text; TimedOut = $timedOut; Bytes = $bytes }
}

function Get-Seconds([string]$text) {
  $m = [regex]::Match($text, '\((\d+)秒\)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Parse-Ok([string]$value) {
  $r = Invoke-Target -InputText $value
  return [pscustomobject]@{ Secs = (Get-Seconds $r.Text); Raw = $r.Text; TimedOut = $r.TimedOut }
}
function Parse-Err([string]$value) {
  $r = Invoke-Target -InputText $value
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
# 半角と全角で同じ秒数になること
function SameCase([string]$hw, [string]$fw) {
  $a = (Parse-Ok $hw).Secs
  $b = (Parse-Ok $fw).Secs
  if ($a -eq '') { Fail "'$hw' の半角側が解析できる" '秒数を取得できなかった'; return }
  AssertEq $a $b "'$hw' ⇔ '$fw'"
}

Write-Host ("対象: {0}" -f $Bat)
Write-Host ("PowerShell: {0} / OS: {1}" -f $PSVersionTable.PSVersion, [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)

if (-not (Test-Path $Bat)) { Fail '.bat が存在する' $Bat; exit 1 }

# ── テスト自身の検査 ────────────────────────────────────────────────────
# 出力の取り込みが壊れると、全ケースが「マーカーが出ないまま待ち続ける」
# 状態になり、ジョブが上限で打ち切られてログも残らない。取り込み部分だけを
# 合成バイト列で先に検証しておく（プロセスは起動しないので一瞬で終わる）。
Section '出力の取り込み（テスト自身の検査）'
$okLine  = "⏱️  継続時間: 1時間30分 (90秒)`r`n"
$sjis    = $null
try { $sjis = [Text.Encoding]::GetEncoding(932) } catch { }

AssertEq '4' ([string]$script:Encodings.Count) '候補のエンコーディングが4種そろっている'

$u8 = ConvertFrom-CaptureBytes ([Text.Encoding]::UTF8.GetBytes($okLine))
AssertMatch $script:Marker $u8 'UTF-8 の出力からマーカーを検出できる'
AssertEq '90' (Get-Seconds $u8) 'UTF-8 の出力から秒数を取り出せる'

# 書き込み中のファイルを読めること。Windows では、他のプロセスが書き込み用に
# 握っているファイルを FileShare.Read で開くと共有違反になる。ポーリングが
# これで空を返すと、カウントダウンが続くケースが軒並みタイムアウト扱いになる。
$busy   = Join-Path ([IO.Path]::GetTempPath()) ('ct-busy-' + [guid]::NewGuid().ToString('N') + '.log')
$writer = New-Object IO.StreamWriter($busy, $false, [Text.Encoding]::UTF8)
try {
  $writer.Write($okLine)
  $writer.Flush()
  AssertEq '90' (Get-Seconds (ConvertFrom-CaptureBytes (Get-CaptureBytes $busy))) `
    '書き込み中のファイルからでも秒数を取り出せる'
} finally {
  $writer.Dispose()
  Remove-Item $busy -Force -ErrorAction SilentlyContinue
}

$bom = ConvertFrom-CaptureBytes ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($okLine))
AssertEq '90' (Get-Seconds $bom) 'BOM 付き UTF-8 でも秒数を取り出せる'
if ($bom.StartsWith([char]0xFEFF)) { Fail 'BOM が本文に残らない' 'BOM が先頭に残っている' }
else { Pass 'BOM が本文に残らない' }

if (-not $sjis) {
  Skip 'CP932 で書かれた出力の取り込み' 'CP932 が使えない'
} else {
  # chcp 65001 が効かず CP932 で書かれた場合。UTF-8 として読むと化けるため、
  # 候補を順に試して正しいコードページを選べることを確認する。
  $raw = $sjis.GetBytes("継続時間: 1時間30分 (90秒)`r`n")
  AssertNotMatch $script:TextMarker ([Text.Encoding]::UTF8.GetString($raw)) `
    'CP932 を UTF-8 として読むと日本語が化ける（前提の確認）'
  AssertEq '90' (Get-Seconds (ConvertFrom-CaptureBytes $raw)) 'CP932 の出力からも秒数を取り出せる'

  # ❌(U+274C) は CP932 に無いので '?' に落ちる。赤の ANSI エスケープが
  # 残るぶん、エラー行はそれで検出できる。
  $err = $sjis.GetBytes("$([char]27)[0;31m❌ 入力形式が正しくありません。$([char]27)[0m`r`n")
  AssertMatch $script:Marker (ConvertFrom-CaptureBytes $err) 'CP932 のエラー行も検出できる'
}

# 日本語が '?' に落ちた場合はどう読んでも復元できない。マーカーに一致させず、
# 診断情報で原因が分かるようにしておく。
$dead = [Text.Encoding]::ASCII.GetBytes("?????: 1?????30? (90?)`r`n")
AssertNotMatch $script:TextMarker (ConvertFrom-CaptureBytes $dead) '"?" に落ちた出力はマーカーに一致しない'
$diag = Format-CaptureDiagnostics $dead
AssertMatch 'バイト数: \d+' $diag '診断にバイト数が出る'
AssertMatch '3f 3f 3f'      $diag '診断に16進が出る'
AssertMatch 'utf-8'         $diag '診断に各デコード結果が出る'

AssertEq '' (ConvertFrom-CaptureBytes ([byte[]]@())) '空の出力は空文字になる'
AssertEq '(出力が空)' (Format-CaptureDiagnostics ([byte[]]@())) '空の出力の診断は説明を返す'
# 空の結果は PowerShell が unroll して $null になる。呼び出し側は
# -not / 型付きパラメータで受けているので、その前提どおりかを確認する。
$missing = Get-CaptureBytes (Join-Path ([IO.Path]::GetTempPath()) 'ct-no-such.log')
if ($missing) { Fail '存在しないファイルを読むと空になる' '中身が返ってきた' }
else { Pass '存在しないファイルを読んでも例外にならず空になる' }
AssertEq '' (ConvertFrom-CaptureBytes $missing) '空の結果をそのまま渡しても例外にならない'

# ── 起動が成立するか ────────────────────────────────────────────────────
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

# ── 事前確認 ────────────────────────────────────────────────────────────
# マーカーを検出できないと、以降の全ケースが「出力を待ち続けて
# タイムアウト」になり、ジョブ全体が上限で打ち切られてログも残らない。
# 1件だけ試して、検出できるか・1件あたり何秒かかるかをここで確定させる。
Section '事前確認（起動方法の校正・マーカー検出・1件あたりの所要時間）'
# コンソールを割り当てるかどうかで標準入力の届き方と出力のコードページが
# 変わる。正解は環境依存なので、'1:30' を実際に渡して 90 秒と解釈された
# 方を採用する。どちらも駄目ならここで打ち切る（以降は待つだけなので）。
$per     = 0.0
$chosen  = $null
$attempts = @()
foreach ($alloc in @($false, $true)) {
  $label = if ($alloc) { 'コンソールあり' } else { 'コンソールなし' }
  $caseSw = [System.Diagnostics.Stopwatch]::StartNew()
  $probe  = Invoke-Target -InputText '1:30' -AllocConsole $alloc
  $caseSw.Stop()
  if ((Get-Seconds $probe.Text) -eq '90') {
    $chosen = $alloc
    $per    = $caseSw.Elapsed.TotalSeconds
    Pass ('{0}: 1件 {1:N1}s で継続時間を検出できる' -f $label, $per)
    break
  }
  Write-Host ('    {0}: 検出できず ({1:N1}s)' -f $label, $caseSw.Elapsed.TotalSeconds) -ForegroundColor Yellow
  $attempts += ("── {0} ──`n{1}" -f $label, (Format-CaptureDiagnostics $probe.Bytes))
}
if ($null -eq $chosen) {
  Fail '継続時間の行を検出できる' ((@(
    "'1:30' を渡しても継続時間の行を検出できなかった。どちらの起動方法でも駄目。",
    '以降のケースも待つだけなので、ここで打ち切る。'
  ) + $attempts) -join "`n")
  Write-Summary
  exit 1
}
$script:AllocConsole = $chosen
if ($per -gt 8) {
  Write-Host ('    警告: 1件 {0:N1}s は遅い。全ケースで約 {1:N0} 分かかる。' -f $per, ($per * 90 / 60)) `
    -ForegroundColor Yellow
}

Section '基本の形式（bash 版と同じ値になること）'
OkCase '90'         '5400'
OkCase '20s'        '20'
OkCase '1:30'       '90'
OkCase '1h30m20s'   '5420'
OkCase '1d3h'       '97200'
OkCase '1:2:3:4'    '93784'
OkCase '1.5h'       '5400'
OkCase '45minutes'  '2700'

Section '全角・先頭ゼロの正規化'
OkCase '１：３０'   '90'
OkCase '００９０'   '5400'

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
ErrCase 'garbage' '入力形式'
ErrCase '1:2:3:4:5:6:7' '入力形式'

Section '桁数の上限（上限ちょうどは受理、1つ超えたら拒否）'
OkCase  '111111d11h11m11s'  '9600030671'
ErrCase '1111111d11h11m11s' '長すぎ'
ErrCase '999999999999999d'  '長すぎ'
ErrCase '99999y'            '長すぎ'
ErrCase '99999mo'           '長すぎ'
OkCase  '1s' '1'

Section '最大秒数（.bat は DateTime.MaxValue = 西暦9999年まで）'
# .command / .sh は16桁エポック（≒西暦約3億年）まで許すため、ここは .bat 固有の挙動。
ErrCase '99999999999999d'  '最大時間'
ErrCase '9999y'            '最大時間'
ErrCase '999999999999999s' '最大時間'
# 9999ヶ月 = 約833年後なので西暦9999年には収まる（受理が正しい）
$r = Parse-Ok '9999mo'
if ($r.Secs -eq '') { Fail "'9999mo' が受理される" ("出力: " + ($r.Raw -replace "`r?`n", ' / ')) }
else { Pass ("'9999mo' が受理される ({0} 秒)" -f $r.Secs) }
OkCase '1000d' '86400000'

Section '上限内だが非常に長い書き方'
# 単位の長い表記・空白・先頭ゼロは正規化で縮むため、生の入力が長くても上限内。
$ref = (Parse-Ok '1:2:3:4:5:6').Secs
if ($ref -eq '') {
  Fail "基準となる '1:2:3:4:5:6' が解析できる" '解析に失敗した'
} else {
  foreach ($v in @('1years2months3days4hours5minutes6seconds',
                   '1yr2mo3d4hr5min6sec',
                   '1 y 2 mo 3 d 4 h 5 m 6 s')) {
    AssertEq $ref (Parse-Ok $v).Secs ("'{0}' ({1}文字) が '1:2:3:4:5:6' と同じ秒数" -f $v, $v.Length)
  }
}
AssertEq '5400' (Parse-Ok (('0' * 1000) + '90')).Secs "先頭ゼロ1000個 + '90' が5400秒"

Section '全角入力'
SameCase '45minutes' '４５ｍｉｎｕｔｅｓ'
SameCase '1year'     '１ｙｅａｒ'
SameCase '1YEAR'     '１ＹＥＡＲ'
SameCase '1h30m'     '１ｈ　３０ｍ'

Section '長いが正規化されない書き方は拒否される'
foreach ($v in @('oneyear', '1h1h1h', 'ＩＹＥＡＲ', 'ｙｅａｒ')) { ErrCase $v '入力形式' }
ErrCase ('1years' * 500) '長すぎ'

Section '本体入力では符号付きを弾く（半角・全角とも）'
# 符号が意味を持つのは実行中の調整入力だけ。本体入力では解釈しない。
foreach ($v in @('+90', '-5', '＋90', '－5', '−5', 'ー5', '+1h', '＋１ｈ', 'ー1h', '+1:30')) {
  ErrCase $v '入力形式'
}

Section '極端に長い入力'
$long = '9' * 10000
$caseSw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Parse-Err $long
$caseSw.Stop()
if ($r.TimedOut) { Fail '10000桁の入力が拒否される' 'タイムアウトした' }
elseif ($r.Msg -like '*長すぎ*') { Pass ('10000桁の入力が拒否される ({0:N1}s)' -f $caseSw.Elapsed.TotalSeconds) }
else { Fail '10000桁の入力が拒否される' ("メッセージ: '" + $r.Msg + "'") }

Section '入力はコマンドとして評価されない'
$canary = Join-Path $env:TEMP ('ct-canary-' + [guid]::NewGuid().ToString('N') + '.txt')
foreach ($payload in @(
  ('90 & echo pwned > "' + $canary + '"'),
  ('$(New-Item -Path "' + $canary + '" -ItemType File)'),
  ('90 | Out-File "' + $canary + '"')
)) {
  [void](Invoke-Target -InputText $payload)
  if (Test-Path $canary) {
    Fail '入力がコマンドとして実行されない' ("実行された: " + $payload)
    Remove-Item $canary -Force -ErrorAction SilentlyContinue
  } else {
    Pass ('入力がコマンドとして実行されない: {0}…' -f $payload.Substring(0, [Math]::Min(28, $payload.Length)))
  }
}

Section 'カウントダウンを実際に完走する'
$run = Invoke-Target -InputText '2s' -TimeoutSec 120 -WaitForExit
if ($run.TimedOut -or -not ($run.Text -match '終了しました')) {
  Fail '2秒のタイマーが完走する' ("出力:`n" + $run.Text)
} else {
  Pass '2秒のタイマーが完走して終了メッセージを表示する'
  AssertEq '2' (Get-Seconds $run.Text) '2秒として解釈される'
  AssertNotMatch 'ParserError|Exception' $run.Text 'カウントダウン中に例外が出ない'
  AssertMatch '中断' $run.Text '中断方法が案内される'
}

Section '/bg（バックグラウンド実行）'
# ここだけ /bg を使う。/bg は Start-Process で切り離した powershell.exe を起こす。
# それは SetThreadExecutionState でスリープと画面消灯を止めたまま指定秒数
# （'/bg 90' なので5400秒 = 90分）眠る。cmd はすぐ終了するので、起動した
# プロセスの PID を taskkill しても切り離された側には届かない。CI では
# ランナーごと消えるが、実機で走らせると90分スリープできなくなる。
# 起動前後の powershell.exe を比べ、増えた分をここで落とす。
$psBefore = @(Get-Process powershell -ErrorAction SilentlyContinue | ForEach-Object Id)
$bg = Invoke-Target -InputText '/bg 90' -TimeoutSec 120 -WaitForExit
if ($bg.TimedOut) { Fail '/bg が起動して終了する' 'タイムアウトした' }
else {
  AssertEq '5400' (Get-Seconds $bg.Text) '/bg でも 90 → 5400 秒'
  AssertMatch 'バックグラウンド' $bg.Text '/bg の案内が表示される'
}
$bgStrays = @(Get-Process powershell -ErrorAction SilentlyContinue |
              Where-Object { $psBefore -notcontains $_.Id } | ForEach-Object Id)
foreach ($bgPid in $bgStrays) {
  try { & taskkill.exe /T /F /PID $bgPid 2>&1 | Out-Null } catch { }
}
if ($bgStrays.Count -gt 0) {
  Pass ('/bg が切り離した待機プロセスを片付けた ({0}件)' -f $bgStrays.Count)
} else {
  Skip '/bg が切り離した待機プロセスの後始末' '増えた powershell.exe が無い'
}

Section 'コンソールのコードページを元に戻す'
$before = (& chcp.com) -replace '[^0-9]', ''
[void](Invoke-Target -InputText 'garbage')
$after = (& chcp.com) -replace '[^0-9]', ''
AssertEq $before $after "実行後もコードページが $before のまま"

Section 'npm 経由の起動（bin/caffeinate-timer.js）'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Skip 'node 経由の起動' 'node が無い'
} else {
  $r = Invoke-Target -InputText '90' -Command ('node "{0}"' -f $LauncherJs)
  if ($r.TimedOut) { Fail 'node 経由で .bat が起動する' ("出力:`n" + $r.Text) }
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

$r = Invoke-Target -InputText '90' -Command ('"{0}"' -f $oddBat) -WorkingDirectory $odd
if ($r.TimedOut) { Fail '括弧とアンパサンドを含むパスから起動できる' ("出力:`n" + $r.Text) }
else { AssertEq '5400' (Get-Seconds $r.Text) '括弧とアンパサンドを含むパスから起動できる' }

if (Get-Command node -ErrorAction SilentlyContinue) {
  $r = Invoke-Target -InputText '90' `
        -Command ('node "{0}"' -f (Join-Path $odd 'bin\caffeinate-timer.js')) -WorkingDirectory $odd
  if ($r.TimedOut) { Fail 'node 経由でも記号を含むパスから起動できる' ("出力:`n" + $r.Text) }
  else { AssertEq '5400' (Get-Seconds $r.Text) 'node 経由でも記号を含むパスから起動できる' }
}

Section '/wait と /settings'
# いずれもエラー表示後は入力画面へ戻るためプロセスは終了しない。
# 終了を待つと1件ごとに上限まで待つことになるので、目的の行が出た時点で打ち切る。
$r = Invoke-Target -InputText '/wait definitely-no-such-process-xyz'
AssertMatch '見つかりません' $r.Text '存在しないプロセス名を指定するとエラーになる'
$r = Invoke-Target -InputText '/wait 0'
AssertMatch '無効なPID' $r.Text 'PID 0 は拒否される'
$r = Invoke-Target -InputText '/wait not/a/name'
AssertMatch '使用できない文字' $r.Text '不正な文字を含むプロセス名は拒否される'
$r = Invoke-Target -InputText '/settings' -UntilPattern '現在のバージョン'
AssertMatch '現在のバージョン' $r.Text '/settings が設定画面を表示する'

# ── 後始末 ──────────────────────────────────────────────────────────────
Section '後始末'
Remove-Item $odd -Recurse -Force -ErrorAction SilentlyContinue
foreach ($startedProc in $script:StartedProcs) {
  # 既に終了しているものは触らない。Process のハンドルを持っている間は
  # PID が再利用されないので、この判定は安全に効く。
  try { if ($startedProc.HasExited) { continue } } catch { continue }
  try { & taskkill.exe /T /F /PID $startedProc.Id 2>&1 | Out-Null } catch { }
}
Pass '一時ファイルと残留プロセスを片付けた'

Write-Summary
if ($script:Failed -gt 0) { exit 1 }
exit 0
