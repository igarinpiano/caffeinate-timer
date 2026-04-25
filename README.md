# ☕ Caffeinate Timer

Mac や Windows、Linux の自動スリープを一時的に防ぐための、シンプルで柔軟なターミナルベースのタイマーツールです。

プレゼンテーション中、大きなファイルのダウンロード中、動画の書き出し中など、「今だけはスリープしてほしくない」という場面で、指定した時間だけスリープを防止します。

macOS 標準の `caffeinate` コマンド（`-u` および `-d` フラグ）、Linux の `systemd-inhibit` コマンド、および Windows の `SetThreadExecutionState` API を、より直感的かつ簡単に使えるようにしたラッパーツールです。

---

<details>
<summary>機能 / Features</summary>

### 柔軟な時間指定

「分」だけの入力、コロン（`:`）区切り、`h` / `m` / `s` の単位表記、小数（例: `1.5h`）など、人間が直感的に思いつく様々なフォーマットに対応しています。

### 全角・表記ゆれ対応

全角数字（`９０`）や全角アルファベット（`１ｈ`）、`1 hour` のようなスペース区切りや長い単位表記も、自動で正規化して認識します。

### わかりやすい表示

スリープ防止の開始時刻・終了予定時刻・継続時間をターミナル上にカラー表示します。タイマー動作中はプログレスバーと残り時間をリアルタイムにカウントダウン表示します。

### 簡単起動

`.command` ファイル（macOS）および `.bat` ファイル（Windows）は、ターミナルを開いてコマンドを打ち込む必要はなく、ファイルをダブルクリックするだけで起動できます。

### プロセス監視モード

`/wait <プロセス名またはPID>` と入力すると、指定したプロセスが終了するまでスリープを防止します。動画エンコードやダウンロードなど、完了タイミングが不明な作業に便利です（`caffeinate-timer-windows.bat` を含む全プラットフォーム対応）。

### デスクトップ通知

タイマーの正常終了時、またはプロセス終了の検知時に、OSネイティブのデスクトップ通知を表示します（Ctrl+C による手動中断時は通知されません）。

### バックグラウンド実行モード

`/bg <時間>` と入力すると、スリープ防止をバックグラウンドで実行しターミナルウィンドウを即座に閉じられます。終了時はデスクトップ通知でお知らせします（`caffeinate-timer-windows.bat` を含む全プラットフォーム対応）。

### アップデート機能

起動時の入力画面から `/settings` と入力するだけで設定メニューを呼び出せます。最新版への自動アップデートや、過去のバージョンへのダウングレードをターミナル上で完結できます（`caffeinate-timer-windows.bat` を除く）。

</details>

---

<details>
<summary>動作環境 / Requirements</summary>

| Environment | Details |
|-------------|---------|
| macOS | 標準搭載の `caffeinate` コマンドと `bash` を使用します。追加のインストールは不要です。 |
| Windows | 標準搭載の PowerShell 5.1 以上（Windows 10 以降に同梱）を使用します。追加のインストールは不要です。 |
| Linux | `systemd-inhibit` コマンドと `bash` を使用します。systemd 環境（Ubuntu, Fedora 等）が必要です。追加のインストールは不要です。デスクトップ通知は `notify-send` が存在する場合のみ機能します。 |

</details>

---

<details>
<summary>使い方 / Usage</summary>

### macOS（`caffeinate-timer.command`）

1. Releases ページから `caffeinate-timer.command` をダウンロードします。
2. 初回のみ、ファイルに実行権限を付与する必要がある場合があります。ターミナルを開き、以下のコマンドを実行してください。

```
   chmod +x /path/to/caffeinate-timer.command
```

3. Finder から `caffeinate-timer.command` をダブルクリックして起動します。
4. ターミナルの画面が開き、時間の入力を求められるので、希望する時間を入力して Enter を押します。
5. タイマーが完了するか、`Ctrl + C` で中断するまで、Mac のスリープが防止されます。

### Windows（`caffeinate-timer-windows.bat`）

1. Releases ページから `caffeinate-timer-windows.bat` をダウンロードします。
2. `caffeinate-timer-windows.bat` をダブルクリックして起動します。
3. ターミナルの画面が開き、時間の入力を求められるので、希望する時間を入力して Enter を押します。
4. タイマーが完了するか、`Ctrl + C` で中断するまで、Windows のスリープが防止されます。

### macOS / Linux（`caffeinate-timer-universal.sh`）

1. Releases ページから `caffeinate-timer-universal.sh` をダウンロードします。
2. ファイルに実行権限を付与します。

```
   chmod +x /path/to/caffeinate-timer-universal.sh
```

3. ターミナルから以下のコマンドで起動します。

```
   /path/to/caffeinate-timer-universal.sh
```

4. 時間の入力を求められるので、希望する時間を入力して Enter を押します。
5. タイマーが完了するか、`Ctrl + C` で中断するまで、スリープが防止されます。

</details>

---

<details>
<summary>入力形式の例 / Input Format Examples</summary>

非常に多様な入力形式に対応しています。

| 入力例 | 解釈される時間 | 備考 |
|--------|--------------|------|
| `90` | 90分 | 整数のみの場合は「分」として扱われます |
| `1.5` | 1分30秒 | 小数での「分」指定 |
| `01:30` | 1分30秒 | 分:秒 |
| `1:30:00` | 1時間30分0秒 | 時:分:秒 |
| `1:2:3:4` | 1日2時間3分4秒 | 日:時:分:秒 |
| `1:2:3:4:5` | 1ヶ月2日3時間4分5秒 | 月:日:時:分:秒 |
| `1:2:3:4:5:6` | 1年2ヶ月3日4時間5分6秒 | 年:月:日:時:分:秒 |
| `1h` / `1hour` | 1時間 | 単位付き（時間） |
| `45m` / `45min` | 45分 | 単位付き（分） |
| `20s` / `20sec` | 20秒 | 単位付き（秒） |
| `1d` / `1day` | 1日 | 単位付き（日） |
| `2mo` / `2month` | 2ヶ月 | 単位付き（月） |
| `1y` / `1year` | 1年 | 単位付き（年） |
| `1h30m20s` | 1時間30分20秒 | 時・分・秒の複合指定 |
| `1h30m` | 1時間30分 | 時・分の複合指定 |
| `1h20s` | 1時間20秒 | 時・秒の複合指定 |
| `1m20s` | 1分20秒 | 分・秒の複合指定 |
| `1d3h30m` | 1日3時間30分 | 日・時・分の複合指定 |
| `1y2mo` | 1年2ヶ月 | 年・月の複合指定 |
| `1y2mo3d` | 1年2ヶ月3日 | 年・月・日の複合指定 |
| `1y2mo3d4h` | 1年2ヶ月3日4時間 | 年・月・日・時の複合指定 |
| `1.5h` | 1時間30分 | 小数での「時間」指定 |

> **Note:** 全角数字（例: `９０`）や全角アルファベット（例: `１ｈ`）で入力しても正常に動作します。
> 数字の前に0をつけても正常に動作します。（例: `01h`）

</details>

---

<details>
<summary>停止・解除について / Stop & Cancel</summary>

- 指定した時間が経過すると、自動的にスリープ防止が解除され、ターミナルに完了メッセージが表示されます。
- 途中でスリープ防止を解除したい場合は、ターミナルウィンドウ上で `Ctrl + C` を押してください。安全に中断処理が行われます。

</details>

---

<details>
<summary>プロセス監視モード / Process Wait Mode</summary>

入力画面で `/wait <プロセス名またはPID>` と入力すると、指定したプロセスが終了するまでスリープを防止します。

```
/wait Finder
/wait ffmpeg
/wait 1234
```

- プロセス名は英数字・ドット（`.`）・ハイフン（`-`）・アンダースコア（`_`）のみ使用できます（最大64文字）。スペースを含む名前の場合は PID で指定してください。
- プロセスが終了すると自動的にスリープ防止を解除し、デスクトップ通知を表示します。
- 監視中の経過時間はターミナルにリアルタイムで表示されます。

> **Note:** 全プラットフォーム（macOS / Linux / Windows）対応。

</details>

---

<details>
<summary>時刻指定モード / Until Mode</summary>

入力画面で `/until HH:MM` と入力すると、今日のその時刻まで（翌日以前の時刻は翌日として扱われます）スリープを防止します。

```
/until 18:30
/until 9:00
```

- 時刻は 0〜23 時、0〜59 分の範囲で指定してください。
- `/bg` と組み合わせた `/bg /until 18:30` の形式も使用できます。

> **Note:** 全プラットフォーム（macOS / Linux / Windows）対応。

</details>

---

<details>
<summary>タイマー途中変更 / Adjust Timer</summary>

カウントダウン実行中に `+30m` や `-1h` などを入力して Enter を押すと、残り時間をその場で変更できます。

```
+30m       → 30分延長
-1h        → 1時間短縮
+1h30m     → 1時間30分延長
+90        → 90分延長（単位なしは分として扱われます）
```

- 残り時間が0秒以下になる短縮を指定した場合は、最低1秒が確保されます。
- `/bg` モードでは表示がないため途中変更は使用できません。

</details>

---

<details>
<summary>バックグラウンド実行 / Background Mode</summary>

時間指定の前に `/bg` を付けると、スリープ防止をバックグラウンドで実行します。

```
/bg 90
/bg 1h30m
/bg 2:00:00
```

- ターミナルウィンドウを即座に閉じても、バックグラウンドでスリープ防止が継続されます。
- 指定時間が経過すると、デスクトップ通知で完了をお知らせします。
- バックグラウンド実行中はカウントダウン表示は行われません。

> **Note:** 全プラットフォーム（macOS / Linux / Windows）対応。

</details>

---

<details>
<summary>アップデート / Update</summary>

起動時の入力画面で `/settings` と入力すると設定メニューが開き、アップデート操作を行えます（`caffeinate-timer-windows.bat` を除く）。

### 自動アップデート

設定メニューで `/update` と入力すると、GitHub から最新バージョンの情報を取得します。現在のバージョンより新しいリリースがある場合は確認を求めた上でダウンロード・自己置換を行い、完了後にスクリプトが自動的に再起動します。

### バージョン選択（ダウングレード対応）

`/update --manual` と入力すると、リリース済みのバージョン一覧が番号付きで表示されます。番号を選択すると指定バージョンに切り替えられるため、ダウングレードにも対応しています。

> **Note:** アップデート機能は `caffeinate-timer.command` および `caffeinate-timer-universal.sh` のみ対応しています。`caffeinate-timer-windows.bat` には現在この機能は含まれていません。

</details>

---

<details>
<summary>プロジェクト構成 / Project Structure</summary>

```
caffeinate-timer/
├── caffeinate-timer.command       # macOS 専用
├── caffeinate-timer-windows.bat   # Windows 専用
├── caffeinate-timer-universal.sh  # macOS / Linux 対応
└── README.md
```

</details>

---

## ライセンス及び著作権について / License & Copyright

Copyright © 2026 Igarin. All rights reserved.

---

## 謝辞 / Acknowledgements

This project uses Apple's built-in `caffeinate` command, the `systemd-inhibit` command available on Linux systems, and the Windows `SetThreadExecutionState` API.
