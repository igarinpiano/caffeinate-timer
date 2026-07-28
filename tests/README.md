# テスト

追加のインストールは不要です（bash / node / python3 のみ）。

```bash
tests/run.sh              # 全件実行
tests/run.sh duration     # 名前に duration を含むものだけ実行
```

全件で 5 秒程度です。失敗があれば終了コードが 1 になります。

## 構成

| ファイル | 対象 |
|---|---|
| `test_version.sh` | `versions.txt` / `CURRENT_VERSION` / `package.json` のバージョン整合、配布ファイル指定 |
| `test_duration.sh` | 起動画面の時間入力の解析（通常の形式・全角・境界値・桁あふれ・注入耐性） |
| `test_adjust.sh` | カウントダウン中の時間調整パーサ（`+30m` / `-1h` / `+1y` など） |
| `test_windows.sh` | `.bat` の構造と PowerShell 5.1 互換性 |
| `test_launcher.sh` | `bin/caffeinate-timer.js` のプラットフォーム分岐 |
| `test_environ.sh` | 極端な実行環境（タイムゾーン・DST 境界・ロケール・パス・PATH・TERM） |

`lib.sh` が共通のアサーションを提供します。`pwsh` が無い環境では PowerShell
パーサによる検証だけがスキップされ、残りは通常どおり実行されます。

## 設計上の注意

**タイマー本体は走らせません。** 継続時間の行を読んだ時点で `sed` が終了し、
SIGPIPE で対象スクリプトも止まります（1 件あたり 0.1 秒程度）。

**シェルスクリプトは実物を実行して検証します。** 解析ロジックをテスト側に
複製すると本体と乖離するため、`lib.sh` の `duration()` が実スクリプトへ
入力を与えて表示を読み取ります。関数単体を対象にする場合は `extract_fn()` で
関数定義だけを切り出します（行番号には依存しません）。

**一時ファイルは `tmpfile()` で確保してください。** テストファイル側で
`trap ... EXIT` を張ると `lib.sh` の集計処理が上書きされ、結果が
0 件として報告されます。

**Windows / macOS 固有の経路も Linux 上で検証できます。** `.bat` は
埋め込まれた PowerShell 本体を取り出して静的に検査し、`pwsh` があれば
実際にパースします。`bin/caffeinate-timer.js` は `process.platform` と
`spawn` を差し替えて引数だけを取り出します（`tests/fixtures/launcher-probe.js`）。

## このテストが検出する既知の退行

いずれも実際に発生した不具合です。

| 退行 | 検出するテスト |
|---|---|
| `versions.txt` への行追加を忘れて `CURRENT_VERSION` だけ上げる（`/update` がダウングレードを提示する） | `test_version.sh` |
| GNU date へ `@EPOCH` と相対指定を同時に渡す（Linux で年/月指定が失敗する） | `test_duration.sh` / `test_adjust.sh` |
| 時刻の直後に `+2 months` を置く（`+2` がタイムゾーンと誤読され 1 ヶ月になる） | `test_duration.sh` / `test_environ.sh` |
| `.bat` に PowerShell 6.2 以降専用の数値リテラル（`0u`）が入る（5.1 で全体がパースエラー） | `test_windows.sh` |
| `.bat` のヘッダー行に抽出マーカーの文字列が露出する（開始位置を誤検出する） | `test_windows.sh` |
| `.bat` が LF で保存される / ヘッダーに非 ASCII が混入する | `test_windows.sh` |
| 上限内の冗長な表記（`1years2months3days…` など40文字）を誤って弾く | `test_limits.sh` / `test_windows_exec.ps1` |
| macOS 上の `universal.sh`（BSD `date -v` 経路）だけが壊れる | `test_limits.sh` / `test_duration.sh`（macOS ジョブ） |
| `timeout` や GNU sed 拡張に依存してテスト自体が macOS で動かない | CI の macOS ジョブ |
| `cmd.exe` を裸の名前で spawn する（カレントディレクトリから乗っ取られる） | `test_launcher.sh` |
| `cmd /c` の引用が外れる（`C:\Program Files (x86)\...` で起動できない） | `test_launcher.sh` |
| 時間調整の桁数上限が無く int64 が桁あふれする | `test_duration.sh` / `test_adjust.sh` |
