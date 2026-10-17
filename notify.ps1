# Claude Code のルーティンから Windows のトースト通知を出す（押すまで消えない）。Slack にも同時投稿できる
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File notify.ps1 -Title "提案" -Message "本文" -Link "claude://claude.ai/epitaxy/<sessionId>"
# -Detail に詳しい中身（理由・選択肢・押したら何をするか）を書くと3行目に出る。改行は \n
# -Link を付けると、通知本体か「開く」を押したときにそのClaudeセッションへ飛ぶ
# Slack 投稿は任意: ~/.claude/slack-notify.json に {"botToken": "xoxb-...", "channel": "C..."} を置くと有効になる
param([string]$Title = "Claudeから提案", [string]$Message = "", [string]$Detail = "", [string]$Link = "", [string]$SlackChannel = "")
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$esc = { param($s) [Security.SecurityElement]::Escape($s) }
if ($Link) {
  $l = & $esc $Link
  $head = "<toast scenario='reminder' launch='$l' activationType='protocol'>"
  $actions = "<action content='開く' arguments='$l' activationType='protocol'/><action content='閉じる' arguments='dismiss' activationType='system'/>"
} else {
  $head = "<toast scenario='reminder'>"
  $actions = "<action content='OK' arguments='dismiss' activationType='system'/>"
}
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml("$head<visual><binding template='ToastGeneric'><text>$(& $esc $Title)</text><text>$(& $esc $Message)</text>$(if ($Detail) { "<text>$(& $esc ($Detail -replace '\\n',"`n"))</text>" })</binding></visual><actions>$actions</actions></toast>")
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
# Slack にも同じ内容を投稿（設定ファイルがあるときだけ）
$cfgPath = Join-Path $env:USERPROFILE '.claude\slack-notify.json'
if (Test-Path $cfgPath) {
  try {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $SlackChannel) { $SlackChannel = $cfg.channel }
    $text = "🔔 $Title`n$Message"
    if ($Detail) { $text += "`n" + ($Detail -replace '\\n', "`n") }
    if ($Link) { $text += "`nセッション: $Link" }
    $body = [Text.Encoding]::UTF8.GetBytes((@{ channel = $SlackChannel; text = $text; unfurl_links = $false } | ConvertTo-Json -Compress))
    $r = Invoke-RestMethod -Uri 'https://slack.com/api/chat.postMessage' -Method Post -Headers @{ Authorization = "Bearer $($cfg.botToken)" } -ContentType 'application/json; charset=utf-8' -Body $body
    if (-not $r.ok) { Write-Warning "Slack投稿失敗: $($r.error)" }
  } catch { Write-Warning "Slack投稿失敗: $_" }
}
