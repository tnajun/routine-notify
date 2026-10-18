---
name: routine-notify
description: ルーティン（スケジュール実行）の中で提案・GO待ち・本人の判断が必要なこと・失敗が出たときに、Windowsのトースト通知（と任意でSlack）で知らせる。通知を押すとそのセッションへ飛べる。「通知して」「Slackにも知らせて」「ピコンと出して」等でも発動。
---

# ルーティンからの通知（Windowsトースト＋任意でSlack）

会話の中に書くだけでは本人が気づかないため、本人の出番があるときは通知を出す。

## いつ出すか
- 出す：提案／GO待ち／本人の判断が必要／失敗して止まった
- 出さない：問題なく終わり本人のやることがない／普段の対話セッション
- 1回の実行につき1つまで。複数あれば1つにまとめる

## 手順
1. `mcp__ccd_session_mgmt__get_session`（session_id="self"）で `link`（`claude://claude.ai/epitaxy/...`）を取る
2. 実行する（パスはこのスキルのフォルダー）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\routine-notify\notify.ps1" -Title "【毎日13時】ブログ毎日公開" -Message "提案：下書きの在庫が残り1本です。新しい記事を3本書いてよいですか？" -Detail "理由：明日以降の公開が止まります\n案：テーマA・テーマB・テーマCの3本\n「開く」でこのセッションへ。GOと返せば書き始めます" -Link "<1のlink>"
```

- `-Title`：ルーティン名
- `-Message`：何をしてよいか／何を決めてほしいかを1行で
- `-Detail`：理由・具体案・返事したら何が起きるかを `\n` 区切りで。「確認してください」だけは不可
- `-Kind fail`：失敗して止まったときに付ける（タスクトレイの一覧で赤丸）。GO待ち・提案なら付けない（オレンジ丸）
- 出力に「Slack投稿失敗」が出たら、報告にそう書く（トーストは出ている）

## 仕組みメモ
- トーストは押すまで消えない（scenario=reminder）。集中モード中は通知センター直行
- Slack は任意。`~/.claude/slack-notify.json` に `{"botToken": "xoxb-...", "channel": "C..."}` を置くと同じ内容を投稿する（`chat:write` 権限のbot）。`claude://` リンクはPCでのみ開ける
- notify.ps1 / tray.ps1 はBOM付きUTF-8で保存すること（Windows PowerShell 5.1が日本語で構文エラーになる）
- タスクトレイの一覧（tray.ps1）：時計の横の丸アイコン。青＝通常、オレンジ＋数字＝GO待ち、赤＝失敗。押すとルーティン一覧が開き、行を押すとそのセッションへ飛ぶ
  - 状態は `~/.claude/routine-status.json`。`hooks/routine_status.py` が実行中・終了・承認待ちを、notify.ps1 がGO待ち・失敗を書く。GO待ちは本人がそのセッションで返事すると消える
