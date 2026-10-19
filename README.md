# routine-notify

[English](README.en.md)

![使用イメージ](image.png)

Claude Code（デスクトップアプリ）のルーティンが「GO待ち」「判断が必要」「失敗」になったとき、Windows の右下にトースト通知を出す Skill です。通知を押すと、そのセッションに飛べます。

- 通知は押すまで消えない（reminder）
- 「開く」ボタンでその Claude セッションへ（`claude://` リンク）
- 任意で Slack にも同じ内容を投稿
- タスクトレイ（時計の横）にルーティン一覧を常駐（任意）

## 入れ方

```
git clone https://github.com/tnajun/routine-notify "$env:USERPROFILE\.claude\skills\routine-notify"
```

Slack にも送る場合は `~/.claude/slack-notify.json` を作る：

```json
{"botToken": "xoxb-...", "channel": "C0123456789"}
```

## 単体で試す

```
powershell -NoProfile -ExecutionPolicy Bypass -File notify.ps1 -Title "テスト" -Message "通知のテストです"
```

## タスクトレイのルーティン一覧（任意）

ふだんは時計の横に丸いアイコンがあるだけです。

- 青：通常
- オレンジ＋数字：GO待ちあり
- 赤：失敗あり

アイコンを押すとルーティン一覧が開きます（GO待ち・失敗・実行中・次の予定時刻）。行を押すと、そのセッションに飛びます。一覧の外を押すと閉じます。

### ピン留め

よく見るルーティンは、一覧のいちばん上に固定できます。

1. Claudeアプリでルーティンの詳細画面を開き、右上の鉛筆マークで名前を編集する
2. 名前のどこかに 📌 を入れて保存する（例：`【毎日9:40】📌メール返信の下書き作成`）

これだけで、そのルーティンは状態や時間に関係なく一覧のいちばん上に並び、名前の左に赤いピンが付きます。外すときは 📌 を消します。一覧は20秒ごとに自動で並び替わるので、再起動はいりません。

### 1. 状態を記録するフックを入れる

`hooks/routine_status.py` を `~/.claude/hooks/` に置き、`~/.claude/settings.json` の `hooks` に足します（Python 3 が必要）：

```json
{
  "hooks": {
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "python \"%USERPROFILE%/.claude/hooks/routine_status.py\"", "timeout": 10}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "python \"%USERPROFILE%/.claude/hooks/routine_status.py\"", "timeout": 10}]}],
    "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "python \"%USERPROFILE%/.claude/hooks/routine_status.py\"", "timeout": 10}]}]
  }
}
```

すでに同じイベントのフックがある場合は、その `hooks` 配列に1行足してください。`%USERPROFILE%` が展開されない環境では、フルパスに書き換えてください。

### 2. 一覧を起動する

```
powershell -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\routine-notify\tray.ps1"
```

サインイン時に自動で起動したい場合は、上のコマンドのショートカットをスタートアップフォルダー（`shell:startup`）に置きます。

アイコンが `^`（隠れているインジケーター）の中に入ったら、時計の横までドラッグすると常に見えるようになります。

### 仕組み

- ルーティンの名前と予定：Claude デスクトップアプリの `scheduled-tasks.json`
- 実行中：ルーティンの会話ログが10分以内に書かれていたら実行中
- GO待ち・失敗：notify.ps1 が `~/.claude/routine-status.json` に書く（`-Kind fail` で失敗）
- 終了・承認待ち：フック（routine_status.py）が書く

Windows 10/11 + Windows PowerShell 5.1 で動作確認。

## License

MIT
