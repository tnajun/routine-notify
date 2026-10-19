# ルーティン一覧をタスクトレイ（時計の横）に常駐させる。ふだんは丸いアイコンだけ。
#   青＝通常 / オレンジ＋数字＝GO待ちあり / 赤＝失敗あり。左クリックで一覧、行を押すとそのセッションへ飛ぶ。
# 状態は ~/.claude/routine-status.json（hooks/routine_status.py と notify.ps1 が書く）と
# Claudeアプリの scheduled-tasks.json（予定・名前）とセッション記録（どの回がどのルーティンか）から作る。
# 起動: powershell -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File tray.ps1
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$mutex = New-Object Threading.Mutex($false, 'Local\ClaudeRoutineTray')
if (-not $mutex.WaitOne(0)) { exit }  # 二重起動しない

$SESS = "$env:APPDATA\Claude\claude-code-sessions"
$STATUS = "$env:USERPROFILE\.claude\routine-status.json"
$PIN = [char]::ConvertFromUtf32(0x1F4CC)  # 📌
$C = @{ go = [Drawing.Color]::FromArgb(245,158,11); fail = [Drawing.Color]::FromArgb(239,68,68); running = [Drawing.Color]::FromArgb(59,130,246); idle = [Drawing.Color]::FromArgb(196,201,208) }
$script:sessions = @{}   # sessionId -> @{ task; created }
$script:lastScan = [datetime]::MinValue
$script:logs = @{}       # cliSessionId -> 会話ログ(.jsonl)のパス
# ルーティンは1回の長い返答で動くのでフックが最後まで来ない。会話ログが10分以内に書かれていたら実行中とみなす
function Log-Time($cli) {
  if (-not $cli) { return $null }
  if (-not $script:logs[$cli]) {
    foreach ($d in [IO.Directory]::GetDirectories("$env:USERPROFILE\.claude\projects")) { $f = "$d\$cli.jsonl"; if ([IO.File]::Exists($f)) { $script:logs[$cli] = $f; break } }
  }
  if ($script:logs[$cli]) { [IO.File]::GetLastWriteTime($script:logs[$cli]) } else { $null }
}

function Read-Tasks {
  $f = Get-ChildItem $SESS -Recurse -Filter scheduled-tasks.json -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $f) { return @() }
  $t = [IO.File]::ReadAllText($f.FullName)
  # recordedSkips が数MBに膨らむので、その手前（scheduledTasks）だけ読む
  $i = $t.IndexOf('"recordedSkips"'); if ($i -gt 0) { $t = $t.Substring(0, $t.LastIndexOf(',', $i)) + '}' }
  @(($t | ConvertFrom-Json).scheduledTasks | Where-Object enabled)
}

function Scan-Sessions {
  $now = Get-Date
  Get-ChildItem $SESS -Recurse -Filter 'local_*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $script:lastScan } | ForEach-Object {
    $x = [IO.File]::ReadAllText($_.FullName)
    if ($x -match '"scheduledTaskId":"([^"]+)"') {
      $task = $Matches[1]
      if ($x -match '"sessionId":"(local_[^"]+)"') { $sid = $Matches[1]; $null = $x -match '"createdAt":(\d+)'; $cr = [int64]$Matches[1]; $null = $x -match '"cliSessionId":"([^"]+)"'; $script:sessions[$sid] = @{ task = $task; created = $cr; cli = $Matches[1] } }
    }
  }
  $script:lastScan = $now
}

# cron（分 時 日 月 曜日）の次の実行時刻。日と曜日が両方指定なら「どちらか」で一致
function Expand($f, $lo, $hi) {
  $set = @{}
  foreach ($p in $f.Split(',')) {
    $step = 1; if ($p -match '^(.*)/(\d+)$') { $p = $Matches[1]; $step = [int]$Matches[2] }
    if ($p -eq '*') { $a = $lo; $b = $hi } elseif ($p -match '^(\d+)-(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2] } else { $a = [int]$p; $b = if ($step -gt 1) { $hi } else { $a } }
    for ($v = $a; $v -le $b; $v += $step) { $set[$v % ($hi + 1 - [int]($hi -eq 7))] = 1 }  # 曜日の7は0（日曜）
  }
  $set
}
function Next-Run($cron) {
  $f = $cron.Trim() -split '\s+'; if ($f.Count -ne 5) { return $null }
  $mi = Expand $f[0] 0 59; $h = Expand $f[1] 0 23; $dom = Expand $f[2] 1 31; $mon = Expand $f[3] 1 12; $dow = Expand $f[4] 0 7
  $domAny = $f[2] -eq '*'; $dowAny = $f[4] -eq '*'
  $t = (Get-Date).Date.AddHours((Get-Date).Hour).AddMinutes((Get-Date).Minute + 1)
  $end = $t.AddDays(32)
  while ($t -lt $end) {
    $dayOk = if ($domAny -and $dowAny) { $true } elseif ($domAny) { $dow[[int]$t.DayOfWeek] } elseif ($dowAny) { $dom[$t.Day] } else { $dom[$t.Day] -or $dow[[int]$t.DayOfWeek] }
    if (-not $mon[$t.Month] -or -not $dayOk) { $t = $t.Date.AddDays(1); continue }
    if (-not $h[$t.Hour]) { $t = $t.Date.AddHours($t.Hour + 1); continue }
    if ($mi[$t.Minute]) { return $t }
    $t = $t.AddMinutes(1)
  }
  $null
}
function Fmt($d) { if (-not $d) { return '' }; if ($d.Date -eq (Get-Date).Date) { $d.ToString('H:mm') } elseif ($d.Date -eq (Get-Date).Date.AddDays(1)) { '明日 ' + $d.ToString('H:mm') } else { $d.ToString('M/d H:mm') } }

function Build-Rows {
  Scan-Sessions
  $st = @{}
  try { ([IO.File]::ReadAllText($STATUS) | ConvertFrom-Json).PSObject.Properties | Where-Object { $_.Name -like 'local_*' } | ForEach-Object { $st[$_.Name] = $_.Value } } catch {}
  $cut = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $rank = @{ go = 0; fail = 1; running = 2 }
  $rows = @(); $seen = @{}
  foreach ($t in Read-Tasks) {
    $mine = @($script:sessions.GetEnumerator() | Where-Object { $_.Value.task -eq $t.id } | Sort-Object { $_.Value.created } -Descending)
    $best = $null
    foreach ($s in $mine) {
      $e = $st[$s.Key]; if (-not $e) { continue }; $seen[$s.Key] = 1
      $state = $e.state
      if ($state -eq 'running' -and $cut - [double]$e.at -gt 3 * 3600) { $state = 'done' }  # 3時間動きがない実行中は止まったとみなす
      if ($state -in 'go','fail' -and $cut - [double]$e.at -gt 7 * 86400) { $state = 'done' }  # 1週間前のGO待ちは流す
      if ($rank.ContainsKey($state) -and (-not $best -or $rank[$state] -lt $rank[$best.state])) { $best = @{ state = $state; label = $e.label; at = $e.at; sid = $s.Key } }
    }
    if (-not $best -and $mine -and $mine[0].Value.created -gt [DateTimeOffset]::Now.AddHours(-6).ToUnixTimeMilliseconds()) {
      $lt = Log-Time $mine[0].Value.cli; $e = $st[$mine[0].Key]
      if ($lt -and $lt -gt (Get-Date).AddMinutes(-10) -and (-not $e -or $e.state -eq 'running' -or [double]$e.at -lt ([DateTimeOffset]$lt).ToUnixTimeSeconds() - 5)) {
        $best = @{ state = 'running'; label = ''; at = 0; sid = $mine[0].Key }
      }
    }
    # 名前に📌があればピン留め：一覧のいちばん上に固定し、📌は赤い印で描く（Labelはカラー絵文字を出せず☒になる）
    $pinned = $t.displayName.Contains($PIN)  # $pin だと大文字小文字を区別せず $PIN を上書きする
    $name = ($t.displayName -replace '^【[^】]*】', '').Replace($PIN, '').Trim()
    $sid = if ($best) { $best.sid } elseif ($mine) { $mine[0].Key } else { '' }
    if ($best) {
      $txt = @{ go = 'GO待ち'; fail = '失敗 ' + (Fmt ([DateTimeOffset]::FromUnixTimeSeconds([int64]$best.at).LocalDateTime)); running = '実行中' }[$best.state]
      if ($best.label -eq '承認待ち') { $txt = '承認待ち' }
      $rows += [pscustomobject]@{ state = $best.state; name = $name; text = $txt; sid = $sid; sort = 0; tip = $best.label; pin = $pinned }
    } else {
      $n = if ($t.cronExpression) { Next-Run $t.cronExpression } elseif ($t.fireAt -gt [DateTimeOffset]::Now.ToUnixTimeMilliseconds()) { [DateTimeOffset]::FromUnixTimeMilliseconds($t.fireAt).LocalDateTime }
      if (-not $n -and -not $t.cronExpression) { continue }  # 1回だけのルーティンで実行済みのものは出さない
      $rows += [pscustomobject]@{ state = 'idle'; name = $name; text = $(if ($n) { '次 ' + (Fmt $n) } else { '予定なし' }); sid = $sid; sort = $(if ($n) { $n.Ticks } else { [int64]::MaxValue }); tip = $t.displayName; pin = $pinned }
    }
  }
  # ルーティン以外のセッションから notify.ps1 で出たGO待ち・失敗も並べる
  foreach ($k in $st.Keys) {
    $e = $st[$k]
    if (-not $seen[$k] -and $e.state -in 'go','fail' -and $e.title -and $cut - [double]$e.at -lt 7 * 86400) {
      $rows += [pscustomobject]@{ state = $e.state; name = ($e.title -replace '^【[^】]*】', ''); text = @{ go = 'GO待ち'; fail = '失敗' }[$e.state]; sid = $k; sort = 0; tip = $e.label }
    }
  }
  $order = @{ go = 0; fail = 1; running = 2; idle = 3 }
  @($rows | Sort-Object { -not $_.pin }, { $order[$_.state] }, sort)
}

# アイコンは色と数字の組み合わせごとに1回だけ作って使い回す。
# 毎回作り直すと Windows の描画用の枠(GDIハンドル)が減っていき、半日ほどで落ちる（2026/10/18 17:01に実際に落ちた）
$script:icons = @{}
function Make-Icon($color, $count) {
  $key = "$($color.ToArgb())|$count"
  if ($script:icons[$key]) { return $script:icons[$key] }
  $b = New-Object Drawing.Bitmap 32, 32
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.FillEllipse((New-Object Drawing.SolidBrush $color), 1, 1, 30, 30)
  $txt = if ($count -gt 0) { [string][Math]::Min($count, 9) } else { 'C' }
  $font = New-Object Drawing.Font 'Segoe UI', 17, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($txt, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 1, 32, 32), $sf)
  $g.Dispose(); $font.Dispose(); $sf.Dispose()
  $script:icons[$key] = [Drawing.Icon]::FromHandle($b.GetHicon()); $b.Dispose()
  $script:icons[$key]
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Visible = $true
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.TopMost = $true; $form.StartPosition = 'Manual'
$form.BackColor = [Drawing.Color]::FromArgb(251,252,253)
# 文字は画面の拡大率で大きくなるので、位置と幅も同じ率で広げる
$g0 = $form.CreateGraphics(); $script:k = $g0.DpiX / 96.0; $g0.Dispose()
function Z($n) { [int]($n * $script:k) }
$form.Width = Z 420
$font = New-Object Drawing.Font 'Yu Gothic UI', 10
$bold = New-Object Drawing.Font 'Yu Gothic UI', 10, ([Drawing.FontStyle]::Bold)
$small = New-Object Drawing.Font 'Yu Gothic UI', 8.5
# 赤い画びょう（📌）を自分で描く。絵文字の字体だと線だけの白抜きになるため。1枚だけ作って使い回す
$script:pinImg = & {
  $s = Z 22; $b = New-Object Drawing.Bitmap $s, $s
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'
  $g.TranslateTransform($s / 2, $s / 2); $g.RotateTransform(40); $g.ScaleTransform($s / 22, $s / 22); $g.TranslateTransform(-10, -10)
  $red = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(220,38,38)); $dark = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(170,20,20))
  $needle = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(110,110,120)), 1.6
  $g.DrawLine($needle, 10, 14, 10, 21)
  $g.FillPolygon($red, [Drawing.PointF[]]@((New-Object Drawing.PointF 7.5, 6), (New-Object Drawing.PointF 12.5, 6), (New-Object Drawing.PointF 14, 12.5), (New-Object Drawing.PointF 6, 12.5)))
  $g.FillEllipse($dark, 4, 11.5, 12, 3.5)
  $g.FillEllipse($red, 5, 0, 10, 7.5)
  $g.FillEllipse([Drawing.Brushes]::White, 7.2, 1.6, 2.6, 2)
  $g.Dispose(); $red.Dispose(); $dark.Dispose(); $needle.Dispose()
  $b
}
$script:hiddenAt = [datetime]::MinValue
$script:tip = New-Object Windows.Forms.ToolTip
$form.Add_Deactivate({ $form.Hide(); $script:hiddenAt = Get-Date })

function Open-Session($sid) {
  $form.Hide()
  if ($sid) { Start-Process "claude://claude.ai/epitaxy/$sid" }
}

function Update-Icon($rows) {
  $go = @($rows | Where-Object state -eq 'go').Count; $fail = @($rows | Where-Object state -eq 'fail').Count
  $color = if ($go) { $C.go } elseif ($fail) { $C.fail } else { $C.running }
  $ic = Make-Icon $color ($go + $fail); if ($tray.Icon -ne $ic) { $tray.Icon = $ic }
  $tray.Text = if ($go -or $fail) { "ルーティン：GO待ち $go / 失敗 $fail" } else { 'ルーティン：GO待ちなし' }
}

function Show-List {
  $rows = Build-Rows; Update-Icon $rows
  # 前回スクロールした位置のまま作り直すと上に空白ができるので、先にいちばん上へ戻す
  $form.SuspendLayout(); $form.AutoScroll = $false; $form.AutoScrollPosition = New-Object Drawing.Point 0, 0
  $old = @($form.Controls); $form.Controls.Clear(); $old | ForEach-Object { $_.Dispose() }
  $y = 0; $rowH = Z 34
  $hd = New-Object Windows.Forms.Label
  $go = @($rows | Where-Object state -eq 'go').Count
  $hd.Text = "  ルーティン" + $(if ($go) { "　　GO待ち $go" } else { '' }); $hd.Font = $bold; $hd.SetBounds(0, 0, $form.Width, (Z 38)); $hd.TextAlign = 'MiddleLeft'
  if ($go) { $hd.ForeColor = [Drawing.Color]::FromArgb(194,65,12) }
  $form.Controls.Add($hd); $y = Z 38
  $tip = $script:tip; $tip.RemoveAll()
  foreach ($r in $rows) {
    $p = New-Object Windows.Forms.Panel; $p.SetBounds(0, $y, $form.Width - (Z 22), $rowH)  # 右端はスクロールバーの分あける; $p.Tag = $r.sid; $p.Cursor = 'Hand'
    $dot = New-Object Windows.Forms.Label; $dot.Text = '●'; $dot.ForeColor = $C[$r.state]; $dot.Font = $font; $dot.SetBounds((Z 12), (Z 7), (Z 20), (Z 22))
    $nm = New-Object Windows.Forms.Label; $nm.Text = $r.name; $nm.Font = $font; $nm.SetBounds((Z 34), (Z 7), (Z 236), (Z 22)); $nm.AutoEllipsis = $true
    $ctls = @($dot, $nm)
    if ($r.pin) {
      $pn = New-Object Windows.Forms.Label; $pn.Image = $script:pinImg; $pn.SetBounds((Z 32), (Z 6), (Z 24), (Z 24))
      $nm.SetBounds((Z 56), (Z 7), (Z 214), (Z 22)); $ctls += $pn
    }
    $tx = New-Object Windows.Forms.Label; $tx.Text = $r.text; $tx.Font = $font; $tx.SetBounds((Z 270), (Z 7), (Z 120), (Z 22)); $tx.TextAlign = 'MiddleRight'
    $tx.ForeColor = switch ($r.state) { 'go' { [Drawing.Color]::FromArgb(194,65,12) } 'fail' { [Drawing.Color]::FromArgb(185,28,28) } default { [Drawing.Color]::FromArgb(100,105,115) } }
    foreach ($ctl in @($p, $tx) + $ctls) {
      $ctl.Tag = $r.sid
      $ctl.Add_Click({ Open-Session $this.Tag })
      $ctl.Add_MouseEnter({ $pp = if ($this -is [Windows.Forms.Panel]) { $this } else { $this.Parent }; $pp.BackColor = [Drawing.Color]::FromArgb(238,244,255) })
      $ctl.Add_MouseLeave({ $pp = if ($this -is [Windows.Forms.Panel]) { $this } else { $this.Parent }; $pp.BackColor = [Drawing.Color]::Transparent })
      if ($r.tip) { $tip.SetToolTip($ctl, $r.tip) }
    }
    $p.Controls.AddRange(@($tx) + $ctls); $form.Controls.Add($p); $y += $rowH
  }
  $ft = New-Object Windows.Forms.Label; $ft.Text = '  行を押す → そのセッションが開く'; $ft.Font = $small
  $ft.ForeColor = [Drawing.Color]::Gray; $ft.BackColor = [Drawing.Color]::FromArgb(243,245,247); $ft.SetBounds(0, $y, $form.Width, (Z 28)); $ft.TextAlign = 'MiddleLeft'
  $form.Controls.Add($ft); $y += Z 28
  $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Height = [Math]::Min($y, $wa.Height - 20)
  $form.AutoScroll = $y -gt $wa.Height - 20
  $form.Location = New-Object Drawing.Point ($wa.Right - $form.Width - 12), ($wa.Bottom - $form.Height - 12)
  $form.ResumeLayout()
  $form.Show(); $form.Activate()
}

$tray.Add_MouseClick({
  param($s, $e)
  if ($e.Button -ne 'Left') { return }
  if ($form.Visible) { $form.Hide(); return }
  if (((Get-Date) - $script:hiddenAt).TotalMilliseconds -lt 300) { return }  # アイコンを押して閉じた直後は開き直さない
  try { Show-List } catch {}
})
$menu = New-Object Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('一覧を開く', $null, { try { Show-List } catch {} })
$null = $menu.Items.Add('終了', $null, { $tray.Visible = $false; [Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 20000
$timer.Add_Tick({ try { Update-Icon (Build-Rows) } catch {} })
$timer.Start()
Update-Icon (Build-Rows)
[Windows.Forms.Application]::Run()
$tray.Dispose()
