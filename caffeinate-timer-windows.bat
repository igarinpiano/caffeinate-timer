@echo off
setlocal
"%SystemRoot%\System32\chcp.com" 65001 >nul
set "__CAFFEINATE_FILE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoProfile -Command "$t=[IO.File]::ReadAllText($env:__CAFFEINATE_FILE,[Text.Encoding]::UTF8);$si=$t.IndexOf('<#PS');$ei=$t.LastIndexOf('#>PS');if($si -lt 0 -or $ei -le $si){Write-Host 'スクリプトの抽出に失敗しました。';exit 1};& ([scriptblock]::Create($t.Substring($si+4,$ei-$si-4)))"
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

# ── バージョン定数 ───────────────────────────────────────
$CURRENT_VERSION = "v1.4.0"

# ── デスクトップ通知（正常終了時のみ呼び出す）────────────
# System.Windows.Forms.NotifyIcon によるバルーン通知。
# テキストはハードコードされており、ユーザー入力を含まない。
# 失敗しても処理を継続する。
function Send-CaffeinateNotification {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue
        $n = New-Object System.Windows.Forms.NotifyIcon
        try { $n.Icon = [System.Drawing.SystemIcons]::Information } catch {}
        $n.BalloonTipTitle = "Caffeinate Timer"
        $n.BalloonTipText  = "スリープ防止が終了しました。"
        $n.Visible = $true
        $n.ShowBalloonTip(5000)
        Start-Sleep -Milliseconds 200
        $n.Dispose()
    } catch {}
}

# ── /wait モード: プロセス監視 ───────────────────────────
# 引数: プロセス名または PID
# セキュリティ:
#   PID        — 純粋な整数として検証後、Get-Process -Id の引数に渡す。
#   プロセス名 — 英数字・ドット・ハイフン・アンダースコアのみ許可（最大64文字）。
#                Get-Process -Name の引数に渡す。いずれもコマンドインジェクションなし。
function Start-WaitMode {
    param([string]$Target)
    $Target = $Target.Trim()

    if ([string]::IsNullOrEmpty($Target)) {
        Write-Host "${RED}❌ /wait の後にプロセス名またはPIDを指定してください。${RESET}"
        Write-Host "例: ${CYAN}/wait notepad${RESET}  または  ${CYAN}/wait 1234${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        return
    }

    $waitByPid = $false
    $waitPid   = 0L
    $waitName  = ""

    if ($Target -match '^\d+$') {
        # ── PID モード ──────────────────────────────────────
        # [long] にキャストして整数オーバーフローを防止。
        # Windows の最大 PID は 4194304（2^22）。
        $waitPid = [long]$Target
        if ($waitPid -le 0 -or $waitPid -gt 4194304) {
            Write-Host "${RED}❌ 無効なPIDです（1〜4194304）。${RESET}"
            Write-Host ""
            Read-Host "Enterで閉じる..."
            return
        }
        $waitByPid = $true
        $procCheck = $null
        try { $procCheck = Get-Process -Id ([int]$waitPid) -ErrorAction SilentlyContinue } catch {}
        if ($null -eq $procCheck) {
            Write-Host "${RED}❌ PID ${waitPid} のプロセスが見つかりません。${RESET}"
            Write-Host ""
            Read-Host "Enterで閉じる..."
            return
        }
    } elseif ($Target -match '^[a-zA-Z0-9._-]+$' -and $Target.Length -le 64) {
        # ── プロセス名モード ────────────────────────────────
        $waitName  = $Target
        $procCheck = $null
        try { $procCheck = Get-Process -Name $waitName -ErrorAction SilentlyContinue } catch {}
        if ($null -eq $procCheck) {
            Write-Host "${RED}❌ プロセス '${waitName}' が見つかりません。${RESET}"
            Write-Host ""
            Read-Host "Enterで閉じる..."
            return
        }
    } else {
        Write-Host "${RED}❌ プロセス名に使用できない文字が含まれています。${RESET}"
        Write-Host "  英数字・ドット（.）・ハイフン（-）・アンダースコア（_）のみ使用できます（最大64文字）。"
        Write-Host "  スペースを含む名前の場合は PID で指定してください。"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        return
    }

    $wTarget = if ($waitByPid) { "PID $waitPid" } else { "'$waitName'" }

    Write-Host "${CYAN}────────────────────────────────────────${RESET}"
    Write-Host "  ${BOLD}監視対象:${RESET} ${CYAN}${wTarget}${RESET}"
    Write-Host "${CYAN}────────────────────────────────────────${RESET}"
    Write-Host ""
    Write-Host "${YELLOW}💡 スリープを防止しています... (Ctrl+C で中断)${RESET}"
    Write-Host ""

    try { [WinPwr]::Prevent() } catch {}
    try { [Console]::TreatControlCAsInput = $true } catch {}

    $wStart      = Get-Date
    $wTick       = 0
    $interrupted = $false
    $alive       = $true

    try {
        while ($alive) {
            $elapsed = [long][Math]::Floor(((Get-Date) - $wStart).TotalSeconds)
            $eH = [int][Math]::Floor($elapsed / 3600)
            $eM = [int][Math]::Floor(($elapsed % 3600) / 60)
            $eS = [int]($elapsed % 60)
            Write-Host -NoNewline ("`r  ⏳ ${wTarget} の終了を待機中...  経過時間: {0:D2}:{1:D2}:{2:D2}   " -f $eH, $eM, $eS)

            Start-Sleep -Milliseconds 200

            # Ctrl+C 検知
            try {
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                        $interrupted = $true
                        break
                    }
                }
            } catch {}
            if ($interrupted) { break }

            # 3秒ごと（15回 × 200ms）にプロセスの生存確認
            $wTick++
            if ($wTick -ge 15) {
                $wTick     = 0
                $procCheck = $null
                try {
                    if ($waitByPid) {
                        $procCheck = Get-Process -Id ([int]$waitPid) -ErrorAction SilentlyContinue
                    } else {
                        $procCheck = Get-Process -Name $waitName -ErrorAction SilentlyContinue
                    }
                } catch {}
                if ($null -eq $procCheck) { $alive = $false }
            }
        }
    } finally {
        try { [Console]::TreatControlCAsInput = $false } catch {}
        try { [WinPwr]::Allow() } catch {}
    }

    Write-Host ""

    if ($interrupted) {
        Write-Host "${YELLOW}⚠️  中断されました。スリープ防止を解除します。${RESET}"
        Write-Host ""
    } else {
        Send-CaffeinateNotification
        Write-Host "${GREEN}✅ プロセスが終了しました。スリープ防止を解除します。 ($(Get-Date -Format 'HH:mm:ss'))${RESET}"
        Write-Host ""
    }
    Read-Host "Enterで閉じる..."
}

# ── 設定メニュー関数 ─────────────────────────────────────
# Windows 版ではアップデートの自動実行は行わず、
# GitHubへの手動ダウンロードを案内する。
# （理由: 実行中 .bat の自己置換はリレースクリプトが必要で
#   環境依存の問題（ExecutionPolicy / Defender 等）が多く
#   堅牢な実装が困難なため）
function Show-SettingsMenu {
    Clear-Host
    Write-Host "${BOLD}${CYAN}⚙️  設定${RESET}"
    Write-Host "${CYAN}────────────────────────────────────────${RESET}"
    Write-Host ""
    Write-Host "  現在のバージョン: ${GREEN}${CURRENT_VERSION}${RESET}"
    Write-Host ""
    Write-Host "${CYAN}────────────────────────────────────────${RESET}"
    Write-Host ""
    Write-Host "  Windows 版ではアップデートを手動で行ってください。"
    Write-Host ""
    Write-Host "  ${BOLD}最新版のダウンロード:${RESET}"
    Write-Host "  ${CYAN}https://github.com/igarinpiano/caffeinate-timer/releases/latest${RESET}"
    Write-Host ""
    Write-Host "  ${BOLD}全バージョン一覧:${RESET}"
    Write-Host "  ${CYAN}https://github.com/igarinpiano/caffeinate-timer/releases${RESET}"
    Write-Host ""
    Write-Host "  ダウンロード後、このファイルと置き換えてください。"
    Write-Host ""
    Read-Host "Enterで閉じる..."
}

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
Write-Host "  ${CYAN}1:2:3:4${RESET}      → 1日2時間3分4秒"
Write-Host "  ${CYAN}1:2:3:4:5${RESET}    → 1ヶ月2日3時間4分5秒"
Write-Host "  ${CYAN}1:2:3:4:5:6${RESET}  → 1年2ヶ月3日4時間5分6秒"
Write-Host "  ${CYAN}1y / 1year${RESET}   → 1年"
Write-Host "  ${CYAN}2mo / 2month${RESET} → 2ヶ月"
Write-Host "  ${CYAN}1d / 1day${RESET}    → 1日"
Write-Host "  ${CYAN}1h / 1hour${RESET}   → 1時間"
Write-Host "  ${CYAN}45m / 45min${RESET}  → 45分"
Write-Host "  ${CYAN}20s / 20sec${RESET}  → 20秒"
Write-Host "  ${CYAN}1h30m20s${RESET}     → 1時間30分20秒"
Write-Host "  ${CYAN}1h20s${RESET}        → 1時間20秒"
Write-Host "  ${CYAN}1.5h${RESET}         → 1時間30分"
Write-Host "  ${CYAN}1y2mo${RESET}        → 1年2ヶ月"
Write-Host "  ${CYAN}1y2mo3h30m${RESET}   → 1年2ヶ月3時間30分"
Write-Host "  ${CYAN}1d3h30m${RESET}      → 1日3時間30分"
Write-Host "  ${CYAN}/wait <名前>${RESET}  → プロセス終了まで待機"
Write-Host "  ${CYAN}/bg <時間>${RESET}    → バックグラウンドで実行"
Write-Host "  ${CYAN}/settings${RESET}    → 設定"
Write-Host ""
$raw = Read-Host "入力"
Write-Host ""

# ── /settings コマンド ────────────────────────────────────
# 前処理を通す前に検出する（スペース除去・小文字化の影響を受けないよう先に処理）
if ($raw.Trim() -eq '/settings') {
    Show-SettingsMenu
    exit 0
}

# ── /wait コマンド ─────────────────────────────────────────
# 前処理を通す前に検出する。ターゲットはプロセス名/PIDなので
# 時間文字列の正規化パイプラインを通さない。
$trimmedRaw = $raw.Trim()
if ($trimmedRaw -match '^/wait( .+)?$') {
    $waitArg = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
    Start-WaitMode -Target $waitArg
    exit 0
}

# ── /bg プレフィックス ─────────────────────────────────────
# /bg <時間> の形式を検出し、フラグを立てて時間部分のみ以降の処理に渡す。
# /bg 単体（時間なし）はエラー。
$bgMode = $false
if ($trimmedRaw -like '/bg *') {
    $bgMode = $true
    $raw    = $trimmedRaw.Substring(4)   # '/bg ' = 4 文字
} elseif ($trimmedRaw -eq '/bg') {
    Write-Host "${RED}❌ /bg の後に時間を指定してください。${RESET}"
    Write-Host "例: ${CYAN}/bg 90${RESET}  または  ${CYAN}/bg 1h30m${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 前処理①：全角→半角変換 ─────────────────────────────
# （sed の y コマンド相当をPowerShell の Replace で実現）
# 対象：全角数字／コロン／小数点／単位 h m s d／全角スペース
$fwTable = @(
    @('０','0'),@('１','1'),@('２','2'),@('３','3'),@('４','4'),
    @('５','5'),@('６','6'),@('７','7'),@('８','8'),@('９','9'),
    @('：',':'),@('．','.'),@('ｈ','h'),@('ｍ','m'),@('ｓ','s'),@('ｄ','d'),@('ｙ','y'),@('ｏ','o'),@('　',' ')
)
foreach ($pair in $fwTable) { $raw = $raw.Replace($pair[0], $pair[1]) }

# ── 前処理②：半角スペース除去・小文字化 ────────────────
$inp = $raw.Replace(' ', '').ToLower()

# ── 単位を正規化（長い表記 → 短い表記）─────────────────
# ※ months / years を先に正規化して minutes / seconds / days と競合しないようにする
$inp = $inp -replace 'months?',  'mo' `
            -replace 'years?',   'y'  `
            -replace 'yrs?',     'y'  `
            -replace 'hours?',   'h'  `
            -replace 'hrs?',     'h'  `
            -replace 'minutes?', 'm'  `
            -replace 'mins?',    'm'  `
            -replace 'seconds?', 's'  `
            -replace 'secs?',    's'  `
            -replace 'days?',    'd'

# ── 前処理③：各数値グループの先頭ゼロを除去 ─────────────────────────
# 文字列長チェックが先頭ゼロで誤判定しないよう正規化する（例: 000001h → 1h）。
# .NET regex の後読み (?<![0-9]) で「数字以外の直後」の先頭ゼロを除去する。
$inp = $inp -replace '(?<![0-9])0+(?=[0-9])', ''

# ── 年・月コンポーネントの抽出 ──────────────────────────────────────
# カレンダー演算が必要なため、パターンマッチの前に y / mo を分離する。
# 桁数を4桁以内に制限し AddYears()/AddMonths() への過大入力を防ぐ。
$yearVal  = 0L
$monthVal = 0L

if ($inp -match '^(\d+)y(.*)$') {
    if ($Matches[1].Length -gt 4) {
        Write-Host "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
        Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
    $yearVal = [long]$Matches[1]
    $inp = $Matches[2]
}

if ($inp -match '^(\d+)mo(.*)$') {
    if ($Matches[1].Length -gt 4) {
        Write-Host "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
        Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
    $monthVal = [long]$Matches[1]
    $inp = $Matches[2]
}

# ── 入力文字数チェック ───────────────────────────────────
# 正規化後16文字を超えると時間単位×乗数の乗算がInt64を超える
# （例: 16桁×3600は桁あふれし、0秒チェックでも補足できない正のゴミ値を生じる）
# ※ d 単位（×86400）の単体入力は別途14桁以内チェックを追加（後述）
if ($inp.Length -gt 16) {
    Write-Host "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
    Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── パターンマッチング ───────────────────────────────────
$seconds = 0L
$parsed  = $true

# 0) 年・月のみ（d/h/m/s なし）
if      ($inp -eq '' -and ($yearVal -gt 0 -or $monthVal -gt 0)) {
    # d/h/m/s 分は 0 秒として扱う（年・月のみ指定）

# 1) 整数のみ → 分
} elseif ($inp -match '^(\d+)$') {
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

# 4.1) W:X:Y:Z → 日:時:分:秒
} elseif ($inp -match '^(\d+):(\d+):(\d+):(\d+)$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 3600L + [long]$Matches[3] * 60L + [long]$Matches[4]

# 4.2) V:W:X:Y:Z → ヶ月:日:時:分:秒
} elseif ($inp -match '^(\d+):(\d+):(\d+):(\d+):(\d+)$') {
    if ($Matches[1].Length -gt 4) {
        Write-Host "${RED}❌ 入力が長すぎます（月の値は4桁以内）。${RESET}"
        Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 1:2:3:4 / 1:2:3:4:5 / 45m / 1h / 1d${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
    $monthVal = [long]$Matches[1]
    $seconds  = [long]$Matches[2] * 86400L + [long]$Matches[3] * 3600L + [long]$Matches[4] * 60L + [long]$Matches[5]

# 4.3) U:V:W:X:Y:Z → 年:ヶ月:日:時:分:秒
} elseif ($inp -match '^(\d+):(\d+):(\d+):(\d+):(\d+):(\d+)$') {
    if ($Matches[1].Length -gt 4 -or $Matches[2].Length -gt 4) {
        Write-Host "${RED}❌ 入力が長すぎます（年・月の値は4桁以内）。${RESET}"
        Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 1:2:3:4 / 1:2:3:4:5:6 / 45m / 1h / 1d${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
    $yearVal  = [long]$Matches[1]
    $monthVal = [long]$Matches[2]
    $seconds  = [long]$Matches[3] * 86400L + [long]$Matches[4] * 3600L + [long]$Matches[5] * 60L + [long]$Matches[6]

# 5) 小数h → 時間（例: 1.5h）
} elseif ($inp -match '^(\d+)\.(\d+)h$') {
    $ip = [long]$Matches[1]; $dp = $Matches[2]; if ($dp.Length -gt 9) { $dp = $dp.Substring(0, 9) }; $dl = $dp.Length
    $pow = [long][Math]::Pow(10, $dl)
    $seconds = [long][Math]::Truncate(($ip * $pow + [long]$dp) * 3600L / $pow)

# 6) XdYhZmWs（最も長いものを先に）
} elseif ($inp -match '^(\d+)d(\d+)h(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 3600L + [long]$Matches[3] * 60L + [long]$Matches[4]

# 7) XdYhZm
} elseif ($inp -match '^(\d+)d(\d+)h(\d+)m$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 3600L + [long]$Matches[3] * 60L

# 8) XdYhZs（分なし）
} elseif ($inp -match '^(\d+)d(\d+)h(\d+)s$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 3600L + [long]$Matches[3]

# 9) XdYmZs（時なし）
} elseif ($inp -match '^(\d+)d(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 60L + [long]$Matches[3]

# 10) XdYh
} elseif ($inp -match '^(\d+)d(\d+)h$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 3600L

# 11) XdYm
} elseif ($inp -match '^(\d+)d(\d+)m$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2] * 60L

# 12) XdYs（時分なし）
} elseif ($inp -match '^(\d+)d(\d+)s$') {
    $seconds = [long]$Matches[1] * 86400L + [long]$Matches[2]

# 13) Xd のみ
# ※ 16文字制限内でも15桁×86400はInt64を超えるため14桁以内に制限する
} elseif ($inp -match '^(\d+)d$') {
    $dStr = $Matches[1]
    if ($dStr.Length -gt 14) {
        Write-Host "${RED}❌ 入力が長すぎます（正規化後16文字以内）。${RESET}"
        Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
    $seconds = [long]$dStr * 86400L

# 14) XhYmZs
} elseif ($inp -match '^(\d+)h(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2] * 60L + [long]$Matches[3]

# 15) XhYm
} elseif ($inp -match '^(\d+)h(\d+)m$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2] * 60L

# 16) XhYs（分なし）
} elseif ($inp -match '^(\d+)h(\d+)s$') {
    $seconds = [long]$Matches[1] * 3600L + [long]$Matches[2]

# 17) XmYs
} elseif ($inp -match '^(\d+)m(\d+)s$') {
    $seconds = [long]$Matches[1] * 60L + [long]$Matches[2]

# 18) Xh のみ
} elseif ($inp -match '^(\d+)h$') { $seconds = [long]$Matches[1] * 3600L

# 19) Xm のみ
} elseif ($inp -match '^(\d+)m$') { $seconds = [long]$Matches[1] * 60L

# 20) Xs のみ
} elseif ($inp -match '^(\d+)s$') { $seconds = [long]$Matches[1]

# 21) パース失敗
} else { $parsed = $false }

if (-not $parsed) {
    Write-Host "${RED}❌ 入力形式がわかりませんでした。${RESET}"
    Write-Host "例: ${CYAN}90 / 1:30 / 1:30:00 / 45m / 1h / 1.5h / 1h30m20s / 1d / 1d3h${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 年・月のカレンダー演算（秒への変換）──────────────────────────────
# AddYears()/AddMonths() はカレンダーを考慮した正確な月・年の加算を行う。
# sub_seconds は d/h/m/s 分のみの秒数（表示用に保持）。
# $_now を先頭で一度だけ取得し、以降の全時刻計算の基点として使い回す。
# これにより、カレンダー演算・表示・最大秒数チェックの各ステップ間で
# システム時計が1秒進むことによるドリフトを防ぐ。
$subSeconds = $seconds
$_now = Get-Date
if ($yearVal -gt 0 -or $monthVal -gt 0) {
    try {
        $_endCal = $_now.AddYears([int]$yearVal).AddMonths([int]$monthVal)
        $seconds = [long]($_endCal - $_now).TotalSeconds + $subSeconds
    } catch {
        Write-Host "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
        Write-Host ""
        Read-Host "Enterで閉じる..."
        exit 1
    }
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
$maxSeconds = [long](([DateTime]::MaxValue - $_now).TotalSeconds) - 1L
if ($seconds -gt $maxSeconds) {
    Write-Host "${RED}❌ 設定可能な最大時間を超えています。${RESET}"
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 1
}

# ── 時刻・継続時間の表示 ─────────────────────────────────
$nowStr = $_now.ToString('yyyy-MM-dd HH:mm:ss')
$endStr = $_now.AddSeconds($seconds).ToString('yyyy-MM-dd HH:mm:ss')
$_dS = $subSeconds % 60L
$_dM = [Math]::Floor(($subSeconds % 3600L) / 60L)
$_dH = [Math]::Floor(($subSeconds % 86400L) / 3600L)
$_dD = [Math]::Floor($subSeconds / 86400L)
if ($yearVal -gt 0) {
    $dur = '{0:D2}:{1:D2}:{2:D2}:{3:D2}:{4:D2}:{5:D2}' -f [int]$yearVal, [int]$monthVal, [int]$_dD, [int]$_dH, [int]$_dM, [int]$_dS
} elseif ($monthVal -gt 0) {
    $dur = '{0:D2}:{1:D2}:{2:D2}:{3:D2}:{4:D2}' -f [int]$monthVal, [int]$_dD, [int]$_dH, [int]$_dM, [int]$_dS
} elseif ($subSeconds -ge 86400L) {
    $dur = '{0:D2}:{1:D2}:{2:D2}:{3:D2}' -f [int]$_dD, [int]$_dH, [int]$_dM, [int]$_dS
} else {
    $dur = '{0:D2}:{1:D2}:{2:D2}' -f [int]$_dH, [int]$_dM, [int]$_dS
}

Write-Host "${CYAN}────────────────────────────────────────${RESET}"
Write-Host "  ${BOLD}現在時刻:${RESET} ${GREEN}${nowStr}${RESET}"
Write-Host "  ${BOLD}終了時刻:${RESET} ${GREEN}${endStr}${RESET}"
Write-Host "  ${BOLD}継続時間:${RESET} ${CYAN}${dur}${RESET}  (${seconds}秒)"
Write-Host "${CYAN}────────────────────────────────────────${RESET}"
Write-Host ""

# ── /bg モード: バックグラウンドで実行 ──────────────────
# $seconds は検証済み [long] 整数のみをスクリプト文字列に埋め込む。
# base64 エンコードで -EncodedCommand に渡すため、インジェクション不可。
# 子プロセス内で使用する WinPwr クラスを WinPwrBg と命名し、
# 親プロセス内の WinPwr と名前衝突しないようにする（別プロセスのため
# 実際は衝突しないが、コードの意図を明確にするため）。
if ($bgMode) {
    Write-Host "${YELLOW}🔄 バックグラウンドで実行します。終了時に通知が届きます。${RESET}"
    Write-Host ""
    $bgScript = `
        "Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class WinPwrBg { [DllImport(""kernel32.dll"")] public static extern uint SetThreadExecutionState(uint f); public static void Prevent(){ SetThreadExecutionState(0x80000003u); } public static void Allow(){ SetThreadExecutionState(0x80000000u); } }' -Language CSharp -ErrorAction SilentlyContinue`n" + `
        "[WinPwrBg]::Prevent()`n" + `
        "Start-Sleep -Seconds $seconds`n" + `
        "[WinPwrBg]::Allow()`n" + `
        "Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue`n" + `
        "Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue`n" + `
        "`$n = New-Object System.Windows.Forms.NotifyIcon`n" + `
        "try { `$n.Icon = [System.Drawing.SystemIcons]::Information } catch {}`n" + `
        "`$n.BalloonTipTitle = 'Caffeinate Timer'`n" + `
        "`$n.BalloonTipText  = 'スリープ防止が終了しました。'`n" + `
        "`$n.Visible = `$true`n" + `
        "`$n.ShowBalloonTip(5000)`n" + `
        "Start-Sleep -Milliseconds 6000`n" + `
        "`$n.Dispose()"
    $bgBytes   = [System.Text.Encoding]::Unicode.GetBytes($bgScript)
    $bgEncoded = [Convert]::ToBase64String($bgBytes)
    try {
        Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -EncodedCommand $bgEncoded" `
            -WindowStyle Hidden `
            -ErrorAction Stop
        Write-Host "${GREEN}✅ バックグラウンドで起動しました。このウィンドウは閉じても構いません。${RESET}"
    } catch {
        Write-Host "${RED}❌ バックグラウンド起動に失敗しました。${RESET}"
    }
    Write-Host ""
    Read-Host "Enterで閉じる..."
    exit 0
}

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
$lastSec     = -1

# ── try/finally でクリーンアップを保証 ──────────────────
# 異常終了・Terminating Error 発生時でも TreatControlCAsInput の
# リセットとスリープ防止の解除が必ず実行されるようにする。
try {
    while ((Get-Date) -lt $targetTime) {
        # ── カウントダウン表示（1秒ごとに更新）──────────────
        $remain = [long][Math]::Ceiling(($targetTime - (Get-Date)).TotalSeconds)
        if ($remain -lt 0) { $remain = 0 }
        $curSec = [int]$remain
        if ($curSec -ne $lastSec) {
            $lastSec = $curSec
            $rH      = [int][Math]::Floor($remain / 3600)
            $rM      = [int][Math]::Floor(($remain % 3600) / 60)
            $rS      = [int]($remain % 60)
            $elapsed = $seconds - $remain
            if ($elapsed -lt 0) { $elapsed = 0 }
            $filled  = if ($seconds -gt 0) { [int][Math]::Floor($elapsed * 20 / $seconds) } else { 20 }
            if ($filled -gt 20) { $filled = 20 }
            $pct = if ($seconds -gt 0) { [int][Math]::Floor($elapsed * 100 / $seconds) } else { 100 }
            if ($pct -gt 100) { $pct = 100 }
            $bar = ('█' * $filled) + ('░' * (20 - $filled))
            Write-Host -NoNewline ("`r  ${GREEN}▶${RESET} [$bar] $pct%  残り: {0:D2}:{1:D2}:{2:D2}   " -f $rH, $rM, $rS)
        }

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
Write-Host ""
if ($interrupted) {
    Write-Host "${YELLOW}⚠️  中断されました。スリープ防止を解除します。${RESET}"
    Write-Host ""
} else {
    Send-CaffeinateNotification
    Write-Host "${GREEN}✅ 終了しました。 ($(Get-Date -Format 'HH:mm:ss'))${RESET}"
    Write-Host ""
}
Read-Host "Enterで閉じる..."
#>PS
