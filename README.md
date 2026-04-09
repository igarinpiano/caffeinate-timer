# ☕ Caffeinate Timer

Mac や Linux の自動スリープを一時的に防ぐための、シンプルで柔軟なターミナルベースのタイマーツールです。

プレゼンテーション中、大きなファイルのダウンロード中、動画の書き出し中など、「今だけはスリープしてほしくない」という場面で、指定した時間だけスリープを防止します。

macOS 標準の `caffeinate` コマンド（`-u` および `-d` フラグ）、および Linux の `systemd-inhibit` コマンドを、より直感的かつ簡単に使えるようにしたラッパーツールです。

---

<details>
<summary>機能 / Features</summary>

### 柔軟な時間指定

「分」だけの入力、コロン（`:`）区切り、`h` / `m` / `s` の単位表記、小数（例: `1.5h`）など、人間が直感的に思いつく様々なフォーマットに対応しています。

### 全角・表記ゆれ対応

全角数字（`９０`）や全角アルファベット（`１ｈ`）、`1 hour` のようなスペース区切りや長い単位表記も、自動で正規化して認識します。

### わかりやすい表示

スリープ防止の開始時刻・終了予定時刻・継続時間をターミナル上にカラー表示します。

### 簡単起動

`.command` ファイルのため、ターミナルを開いてコマンドを打ち込む必要はなく、Finder からダブルクリックするだけで起動できます。( macOS のみ )

</details>

---

<details>
<summary>動作環境 / Requirements</summary>

| Environment | Details |
|-------------|---------|
| macOS | 標準搭載の `caffeinate` コマンドと `bash` を使用します。追加のインストールは不要です。 |
| Linux | `systemd-inhibit` コマンドと `bash` を使用します。systemd 環境（Ubuntu, Fedora 等）が必要です。追加のインストールは不要です。 |

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

### macOS / Linux（`caffeinate-timer-universal.sh`）

1. Releases ページから `caffeinate-timer-universal.sh` をダウンロードします。
2. ファイルに実行権限を付与します。

```
   chmod +x /path/to/caffeinate-timer-universal.sh
```

3. ターミナルから以下のコマンドで起動します。

```
   chmod +x /path/to/caffeinate-timer-universal.sh
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
| `1h` / `1hour` | 1時間 | 単位付き（時間） |
| `45m` / `45min` | 45分 | 単位付き（分） |
| `20s` / `20sec` | 20秒 | 単位付き（秒） |
| `1h30m20s` | 1時間30分20秒 | 時・分・秒の複合指定 |
| `1h30m` | 1時間30分 | 時・分の複合指定 |
| `1h20s` | 1時間20秒 | 時・秒の複合指定 |
| `1m20s` | 1分20秒 | 分・秒の複合指定 |
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
<summary>プロジェクト構成 / Project Structure</summary>

```
caffeinate-timer/
├── caffeinate-timer.command       # macOS 専用
├── caffeinate-timer-universal.sh  # macOS / Linux 対応
└── README.md
```

</details>

---

## ライセンス及び著作権について / License & Copyright

Copyright © 2026 Igarin. All rights reserved.

---

## 謝辞 / Acknowledgements

This project uses Apple's built-in `caffeinate` command.
