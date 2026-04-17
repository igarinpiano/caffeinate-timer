@echo off
chcp 65001 >nul
set "__CAFFEINATE_FILE=%~f0"
powershell -ExecutionPolicy Bypass -NoProfile -Command "$t=[IO.File]::ReadAllText($env:__CAFFEINATE_FILE,[Text.Encoding]::UTF8);$si=$t.IndexOf('<#PS');$ei=$t.LastIndexOf('#>PS');if($si -lt 0 -or $ei -le $si){Write-Host 'スクリプトの抽出に失敗しました。';exit 1};& ([scriptblock]::Create($t.Substring($si+4,$ei-$si-4)))"
exit /b
<#PS
# Copyright © 2026 Igarin. All rights reserved.
# ── Windows 用 Caffeinate タイマー ──────────────────────
# 動作要件: Windows 10 以上 / PowerShell 5.1 以上（標準搭載）
# 追加インストール不要。

# ── ANSI カラー有効化（Windows 10+ / conhost 用）────────
try {
    if (-not ([System.Management.Automation.PSTypeName]'WinCon').Type) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WinCon {
    [DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
}
'@ -ErrorAction SilentlyContinue
    }
    $hOut = [WinCon]::GetStdHandle(-11); $cmode = 0u
    [WinCon]::GetConsoleMode($hOut, [ref]$cmode) | Out-Null
    [WinCon]::SetConsoleMode($hOut, $cmode -bor 4u) | Out-Null
} catch {}

# ── スリープ防止 API（kernel32.dll / 標準搭載）────────
# ES_CONTINUOUS(0x80000000) | ES_SYSTEM_REQUIRED(0x01) | ES_DISPLAY_REQUIRED(0x02)
try {
    if (-not ([System.Management.Automation.PSTypeName]'WinPwr').Type) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WinPwr {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
    public static void Prevent() { SetThreadExecutionState(0x80000003u); }
    public static void Allow()   { SetThreadExecutionState(0x80000000u); }
}
'@ -ErrorAction SilentlyContinue
    }
} catch {}

# ── 色定義 ──────────────────────────────────────────────
$E      = [char]27
$BOLD   = "$E[1m"
$CYAN   = "$E[0;36m"
$GREEN  = "$E[0;32m"
$YELLOW = "$E[1;33m"
$RED    = "$E[0;31m"
$RESET  = "$E[0m"

# ── ヘッダー ────────────────────────────────────────────
Clear-Host
Write-Host "${BOLD}${CYAN}☕  Caffeinate タイマー${RESET}"
Write-Host "${CYAN}────────────────────────────────────────${RESET}"
Write-Host ""
Write-Host "${BOLD}時間を入力してください。${RESET}"
Write-Host "例:"
Write-Host "  ${CYAN}90${RESET}           → 90分"
Write-Host "  ${CYAN}1:30:00${RESET}      → 1時間30分0秒"
Write-Host "  ${CYAN}1:30${RESET}         → 1分30秒"
Write-Host "  ${CYAN}1h / 1hour${RESET}   → 1時間"
Write-Host "  ${CYAN}45m / 45min${RESET}  → 45分"
Write-Host "  ${CYAN}20s / 20sec${RESET}  → 20秒"
Write-Host "  ${CYAN}1h30m20s${RESET}     → 1時間30分20秒"
Write-Host "  ${CYAN}1h20s${RESET}        → 1時間20秒"
Write-Host "  ${CYAN}1.5h${RESET}         → 1時間30分"
Write-Host ""
$raw = Read-Host "入力"
Write-Host ""

# ── 前処理①：全角→半角変換 ─────────────────────────────
# （sed の y コマンド相当をPowerShell の Replace で実現）
# 対象：全角数字／コロン／小数点／単位 h m s／全角スペース
$fwTable = @(
    @('０','0'),@('１','1'),@('２','2'),@('３','3'),@('４','4'),
    @('５','5'),@('６','6'),@('７','7'),@('８','8'),@('９','9'),
    @('：',':'),@('．','.'),@('ｈ','h'),@('ｍ','m'),@('ｓ','s'),@('　',' ')
)
foreach ($pair in $fwTable) { $raw = $raw.Replace($pair[0], $pair[1]) }

# ── 前処理②：半角スペース除去・小文字化 ────────────────
$inp = $raw.Replace(' ', '').ToLower()

# ── 単位を正規化（長い表記 → 短い表記）─────────────────
$inp = $inp -replace 'hours?',   'h' `
            -replace 'hrs?',     'h' `
            -replace 'minutes?', 'm' `
            -replace 'mins?',    'm' `
            -replace 'seconds?', 's' `
            -replace 'secs?',    's'

# ── 入力文字数チェック ───────────────────────────────────
# 正規化後16文字を超えると時間単位×乗数の乗算がInt64を超える
# （例: 16桁×3600は桁あふれし、0秒チェックでも補足できない正のゴミ値を生じる）
if ($inp.Length -gt 16) {
    Write-Host "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
    Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── パターンマッチング ───────────────────────────────────
$seconds = 0L
$parsed  = $true

# 1) 整数のみ → 分
if      ($inp -match '^(\d+)$') {
    $seconds = [long]$Matches[1] * 60L

# 2) 小数のみ → 分（例: 1.5 → 90秒）
} elseif ($inp -match '^(\d+)\.(\d+)$') {
    $ip = [long]$Matches[1]; $dp = $Matches[2]; if ($dp.Length -gt 9) { $dp = $dp.Substring(0, 9) }; $dl = $dp.Length
    $pow = [long][Math]::Pow(10, $dl)
    $seconds = [long][Math]::Truncate(($ip * $pow + [long]$dp) * 60L / $pow)

# 3) X:Y → 分:秒
} elseif ($inp -match '^(\d+):(\d+)$') {
    $seconds = [long]$Matches[1] * 60L + [long]$Matches[2]

# 4) X:Y:Z → 時:分:秒
} elseif ($inp -match '^(\d+):(\d+):(\d+)$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2] * 60L + [long]$Matches[3]

# 5) 小数h → 時間（例: 1.5h）
} elseif ($inp -match '^(\d+)\.(\d+)h$') {
    $ip = [long]$Matches[1]; $dp = $Matches[2]; if ($dp.Length -gt 9) { $dp = $dp.Substring(0, 9) }; $dl = $dp.Length
    $pow = [long][Math]::Pow(10, $dl)
    $seconds = [long][Math]::Truncate(($ip * $pow + [long]$dp) * 3600L / $pow)

# 6) XhYmZs（最も長いものを先に）
} elseif ($inp -match '^(\d+)h(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2] * 60L + [long]$Matches[3]

# 7) XhYm
} elseif ($inp -match '^(\d+)h(\d+)m$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2] * 60L

# 8) XhYs（分なし）
} elseif ($inp -match '^(\d+)h(\d+)s$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2]

# 9) XmYs
} elseif ($inp -match '^(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 60L + [long]$Matches[2]

# 10) Xh のみ
} elseif ($inp -match '^(\d+)h$') { $seconds = [long]$Matches[1] * 3600L

# 11) Xm のみ
} elseif ($inp -match '^(\d+)m$') { $seconds = [long]$Matches[1] * 60L

# 12) Xs のみ
} elseif ($inp -match '^(\d+)s$') { $seconds = [long]$Matches[1]

# 13) パース失敗
} else { $parsed = $false }

if (-not $parsed) {
    Write-Host "${RED}❌ 入力形式がわかりませんでした。${RESET}"
    Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 0秒チェック ─────────────────────────────────────────
if ($seconds -le 0) {
    Write-Host "${RED}❌ 0秒以下の値は設定できません。${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 最大秒数チェック ─────────────────────────────────────
# (Get-Date).AddSeconds() が DateTime.MaxValue(西暦9999年)を超えると例外をスローする
$maxSeconds = [long](([DateTime]::MaxValue - (Get-Date)).TotalSeconds) - 1L
if ($seconds -gt $maxSeconds) {
    Write-Host "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 時刻・継続時間の表示 ─────────────────────────────────
$nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$endStr = (Get-Date).AddSeconds($seconds).ToString('yyyy-MM-dd HH:mm:ss')
$hh     = [Math]::Floor($seconds / 3600L)
$mm     = [Math]::Floor(($seconds % 3600L) / 60L)
$ss     = $seconds % 60L
$dur    = '{0:D2}:{1:D2}:{2:D2}' -f [int]$hh, [int]$mm, [int]$ss

Write-Host "${CYAN}────────────────────────────────────────${RESET}"
Write-Host "  ${BOLD}現在時刻:${RESET} ${GREEN}${nowStr}${RESET}"
Write-Host "  ${BOLD}終了時刻:${RESET} ${GREEN}${endStr}${RESET}"
Write-Host "  ${BOLD}継続時間:${RESET} ${CYAN}${dur}${RESET}  (${seconds}秒)"
Write-Host "${CYAN}────────────────────────────────────────${RESET}"
Write-Host ""
Write-Host "${YELLOW}💡 スリープを防止しています... (Ctrl+C で中断)${RESET}"
Write-Host ""

# ── スリープ防止 開始 ────────────────────────────────────
try { [WinPwr]::Prevent() } catch {}

# ── Ctrl+C をキー入力として受け取り、ループで待機 ────────
# [Console]::TreatControlCAsInput = $true にすることで
# Ctrl+C をシグナルではなくキー入力として扱い、
# 200ms ポーリングで検出 → 確実にスリープ防止を解除できる
try { [Console]::TreatControlCAsInput = $true } catch {}

$targetTime  = (Get-Date).AddSeconds($seconds)
$interrupted = $false

# ── try/finally でクリーンアップを保証 ──────────────────
# 異常終了・Terminating Error 発生時でも TreatControlCAsInput の
# リセットとスリープ防止の解除が必ず実行されるようにする。
try {
    while ((Get-Date) -lt $targetTime) {
        Start-Sleep -Milliseconds 200
        try {
            # バッファに溜まったキー入力をすべて消化（ドレイン）する。
            # if のままでは 1 イテレーションにつき 1 キーしか読まず、
            # 複数キーが積まれていると Ctrl+C 検知まで最大
            # (先行キー数 × 200ms) の遅延が生じるため while に変更。
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'C' -and
                    ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                    $interrupted = $true
                    break  # 内側の while (KeyAvailable) を抜ける
                }
            }
        } catch {}
        if ($interrupted) { break }  # 外側の while (targetTime) を抜ける
    }
} finally {
    # ── TreatControlCAsInput リセット ───────────────────
    try { [Console]::TreatControlCAsInput = $false } catch {}
    # ── スリープ防止 解除 ────────────────────────────────
    try { [WinPwr]::Allow() } catch {}
}

# ── 正常終了 / 中断 ──────────────────────────────────────
if ($interrupted) {
    Write-Host ""
    Write-Host "${YELLOW}⚠️  中断されました。スリープ防止を解除します。${RESET}"
    Write-Host ""
} else {
    Write-Host "${GREEN}✅ 終了しました。 ($(Get-Date -Format 'HH:mm:ss'))${RESET}"
    Write-Host ""
}
Read-Host "Enterで閉じる..."
#>PS
