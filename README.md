# routine-notify

![使用イメージ](image.png)

Claude Code（デスクトップアプリ）のルーティンが「GO待ち」「判断が必要」「失敗」になったとき、Windows の右下にトースト通知を出す Skill です。通知を押すと、そのセッションに飛べます。

- 通知は押すまで消えない（reminder）
- 「開く」ボタンでその Claude セッションへ（`claude://` リンク）
- 任意で Slack にも同じ内容を投稿

## 入れ方

```
git clone https://github.com/<you>/routine-notify "$env:USERPROFILE\.claude\skills\routine-notify"
```

Slack にも送る場合は `~/.claude/slack-notify.json` を作る：

```json
{"botToken": "xoxb-...", "channel": "C0123456789"}
```

## 単体で試す

```
powershell -NoProfile -ExecutionPolicy Bypass -File notify.ps1 -Title "テスト" -Message "通知のテストです"
```

Windows 10/11 + Windows PowerShell 5.1 で動作確認。

## License

MIT
