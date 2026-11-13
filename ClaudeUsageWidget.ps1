<#
.SYNOPSIS
    Claude usage widget that lives inside the Windows 11 taskbar, just left of the tray icons.

.DESCRIPTION
    Shows two rows - 5-hour and 7-day usage - each with a progress ring and a percentage,
    the same numbers Claude Code's /usage shows.

      - Text/ring turn orange at 80% and red at 95% (of the limit used).
      - Follows the Windows light/dark theme.
      - Hover: reset times, model-specific weekly limits, last-updated time, or the error.
      - Left-click: opens claude.ai usage page.
      - Right-click: Refresh now / Show remaining / Update interval / Start with Windows / Exit.
      - On failure the numbers become a dash and the widget dims (never shows wrong numbers).
      - HTTP 429 -> backs off (honours Retry-After, else 10, 20, 40, 60 min).

    Token: read-only from %USERPROFILE%\.claude\.credentials.json. Never written, never refreshed;
    Claude Code keeps it current and the widget re-reads it on every poll.

    Run (no console window):
      powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ClaudeUsageWidget.ps1

    Settings: HKCU\Software\ClaudeUsageWidget      Log: %LOCALAPPDATA%\ClaudeUsageWidget\widget.log
#>

# ---------------------------------------------------------------- settings
$WarnPercent      = 80
$CriticalPercent  = 95
$UsageUrl         = 'https://api.anthropic.com/api/oauth/usage'
$UsagePageUrl     = 'https://claude.ai/settings/usage'
$CredentialsPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$SettingsKey      = 'HKCU:\Software\ClaudeUsageWidget'
$RunKeyPath       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName     = 'ClaudeUsageWidget'
$LogDir           = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
$LogPath          = Join-Path $LogDir 'widget.log'

# ---------------------------------------------------------------- Win32 bits
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace ClaudeWidget -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool   GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool   IsWindow(IntPtr h);
[DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
[DllImport("user32.dll")] public static extern bool   ShowWindow(IntPtr h, int cmd);
[DllImport("shell32.dll")] public static extern int   SHQueryUserNotificationState(out int state);
[DllImport("user32.dll")] public static extern int    GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern int    SetWindowLong(IntPtr h, int idx, int val);
[DllImport("user32.dll")] public static extern bool   SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint   GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool   SetProcessDPIAware();
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
[DllImport("user32.dll")] public static extern int    ReleaseDC(IntPtr h, IntPtr dc);
[DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleDC(IntPtr dc);
[DllImport("gdi32.dll")]  public static extern bool   DeleteDC(IntPtr dc);
[DllImport("gdi32.dll")]  public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
[DllImport("gdi32.dll")]  public static extern bool   DeleteObject(IntPtr obj);
[DllImport("user32.dll")] public static extern bool   UpdateLayeredWindow(IntPtr h, IntPtr dstDc, IntPtr dstPt, ref SIZE size,
                                                         IntPtr srcDc, ref POINT srcPt, int key, ref BLEND blend, int flags);
public struct RECT  { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
public struct SIZE  { public int W, H; }
[StructLayout(LayoutKind.Sequential, Pack=1)]
public struct BLEND { public byte Op, Flags, Alpha, Format; }
'@
[ClaudeWidget.Native]::SetProcessDPIAware() | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageWidget', [ref]$createdNew)
if (-not $createdNew) { exit }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------------------------------------------------------------- state
$script:LastGood     = $null
$script:LastGoodTime = $null
$script:StaleReason  = 'loading...'
$script:BackoffSec   = 0
$script:NextAllowed  = [DateTime]::MinValue
$script:Layout       = $null   # last computed position/size, to detect taskbar changes
$script:LightTheme   = $null

# ---------------------------------------------------------------- small helpers
function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 200KB) { Remove-Item $LogPath -Force }
        Add-Content -Path $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch { }
}

function Get-Setting([string]$Name, $Default) {
    try { $v = (Get-ItemProperty -Path $SettingsKey -Name $Name -ErrorAction Stop).$Name; if ($null -ne $v) { return $v } } catch { }
    $Default
}
function Set-Setting([string]$Name, $Value) {
    if (-not (Test-Path $SettingsKey)) { New-Item -Path $SettingsKey -Force | Out-Null }
    Set-ItemProperty -Path $SettingsKey -Name $Name -Value $Value
}

function Test-LightTheme {
    try { [int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).SystemUsesLightTheme -eq 1 }
    catch { $false }
}

function Read-Credentials {
    # Read-only, and share the file so Claude Code can rewrite it while we read.
    $fs = [IO.File]::Open($CredentialsPath, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
    try   { $json = (New-Object IO.StreamReader($fs)).ReadToEnd() }
    finally { $fs.Dispose() }
    ($json | ConvertFrom-Json).claudeAiOauth
}

function Format-Reset($Value) {
    if (-not $Value) { return 'no active window' }
    $t = if ($Value -is [DateTime]) { $Value.ToLocalTime() } else { [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime }
    $span = $t - (Get-Date)
    $when = if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('ddd HH:mm') }
    $in = if ($span.TotalMinutes -le 0)    { 'now' }
          elseif ($span.TotalHours -lt 24) { '{0}h{1:00}m' -f [Math]::Floor($span.TotalHours), $span.Minutes }
          else                             { '{0}d{1}h' -f $span.Days, $span.Hours }
    "resets $when, in $in"
}

function Get-Percent($Window) {
    if ($Window -and $null -ne $Window.utilization) { return [int][Math]::Round([double]$Window.utilization) }
    0
}

# ---------------------------------------------------------------- data
function Update-Usage {
    # Returns the delay until the next poll.
    $normal = [TimeSpan]::FromMinutes([int](Get-Setting 'IntervalMinutes' 5))
    $now = Get-Date
    if ($now -lt $script:NextAllowed) { return $script:NextAllowed - $now }

    try { $cred = Read-Credentials }
    catch { $script:StaleReason = 'cannot read Claude Code credentials'; Write-Log "Credentials: $($_.Exception.Message)"; return $normal }
    if (-not $cred -or -not $cred.accessToken) { $script:StaleReason = 'not signed in to Claude Code'; return $normal }
    if ($cred.expiresAt -and [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cred.expiresAt).UtcDateTime -le [DateTime]::UtcNow) {
        $script:StaleReason = 'token expired - open Claude Code to renew'
        Write-Log 'Token expired; waiting for Claude Code to refresh it'
        return $normal
    }

    try {
        $resp = Invoke-WebRequest -Uri $UsageUrl -UseBasicParsing -TimeoutSec 20 -UserAgent 'claude-usage-widget-ps/1.0' -Headers @{
            Authorization    = "Bearer $($cred.accessToken)"
            'anthropic-beta' = 'oauth-2025-04-20'
        }
        $script:LastGood     = $resp.Content | ConvertFrom-Json
        $script:LastGoodTime = Get-Date
        $script:StaleReason  = $null
        $script:BackoffSec   = 0
        Write-Log ('OK: 5h={0}% 7d={1}%' -f (Get-Percent $script:LastGood.five_hour), (Get-Percent $script:LastGood.seven_day))
        return $normal
    }
    catch {
        $status = $null; $retryAfter = $null
        $r = $_.Exception.Response
        if ($r) { $status = [int]$r.StatusCode; $retryAfter = $r.Headers['Retry-After'] }
        if ($status -eq 429) {
            $sec = 0
            if (-not [int]::TryParse([string]$retryAfter, [ref]$sec)) { $sec = [Math]::Min([Math]::Max($script:BackoffSec * 2, 600), 3600) }
            $script:BackoffSec  = [Math]::Max($sec, 60)
            $script:NextAllowed = (Get-Date).AddSeconds($script:BackoffSec)
            $script:StaleReason = 'rate-limited, retrying at {0:HH:mm}' -f $script:NextAllowed
            Write-Log "429; backing off $($script:BackoffSec)s"
            return [TimeSpan]::FromSeconds($script:BackoffSec)
        }
        $script:StaleReason = switch ($status) {
            401     { 'token rejected - open Claude Code to renew' }
            403     { 'access denied (403)' }
            $null   { 'network error' }
            default { "server error (HTTP $status)" }
        }
        Write-Log "Request failed ($status): $($_.Exception.Message)"
        return $normal
    }
}

# ---------------------------------------------------------------- drawing
function Get-Colors {
    $light = Test-LightTheme
    $script:LightTheme = $light
    if ($light) { @{ Fg = [Drawing.Color]::FromArgb(230, 0, 0, 0);       Warn = [Drawing.Color]::FromArgb(217, 115, 13); Crit = [Drawing.Color]::FromArgb(196, 43, 28) } }
    else        { @{ Fg = [Drawing.Color]::FromArgb(240, 255, 255, 255); Warn = [Drawing.Color]::FromArgb(255, 170, 60); Crit = [Drawing.Color]::FromArgb(255, 95, 90) } }
}

function Set-Alpha([Drawing.Color]$c, [double]$f) { [Drawing.Color]::FromArgb([int]($c.A * $f), $c.R, $c.G, $c.B) }

function Draw-Widget {
    $L = $script:Layout
    if (-not $L) { return }
    $w = $L.W; $h = $L.H; $s = $L.Scale
    $col = Get-Colors
    $stale = [bool]$script:StaleReason
    $showRemaining = [int](Get-Setting 'ShowRemaining' 0) -eq 1

    $rows = @(
        @{ Label = '5h'; Used = $(if ($script:LastGood) { Get-Percent $script:LastGood.five_hour } else { $null }) },
        @{ Label = '7d'; Used = $(if ($script:LastGood) { Get-Percent $script:LastGood.seven_day } else { $null }) }
    )

    $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::FromArgb(1, 0, 0, 0))   # alpha 1: invisible, but still catches the mouse

    $pad      = [int](4 * $s)
    $rowH     = $h * 0.40
    $ringD    = [int](11 * $s)
    $ringW    = [Math]::Max(1.5, 2 * $s)
    $fontPx   = [Math]::Round(12 * $s)
    $fontVal  = New-Object Drawing.Font 'Segoe UI Semibold', $fontPx, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
    $fontLbl  = New-Object Drawing.Font 'Segoe UI', $fontPx, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
    $right    = New-Object Drawing.StringFormat; $right.Alignment = 'Far'; $right.LineAlignment = 'Center'
    $left     = New-Object Drawing.StringFormat; $left.LineAlignment = 'Center'

    for ($i = 0; $i -lt 2; $i++) {
        $row = $rows[$i]
        $cy  = $h * (0.30 + 0.40 * $i)
        $used = $row.Used
        $main = if ($stale -or $null -eq $used) { Set-Alpha $col.Fg 0.45 }
                elseif ($used -ge $CriticalPercent) { $col.Crit }
                elseif ($used -ge $WarnPercent)     { $col.Warn }
                else                                { $col.Fg }

        # ring: faint full circle + arc for the shown percentage
        $rect  = New-Object Drawing.RectangleF ($pad + $ringW / 2), ($cy - $ringD / 2), ($ringD - $ringW), ($ringD - $ringW)
        $track = New-Object Drawing.Pen (Set-Alpha $col.Fg 0.25), $ringW
        $g.DrawEllipse($track, $rect); $track.Dispose()
        if (-not $stale -and $null -ne $used) {
            $shown = if ($showRemaining) { 100 - $used } else { $used }
            $sweep = 360.0 * [Math]::Min(100, [Math]::Max(0, $shown)) / 100
            if ($sweep -gt 0) {
                $arc = New-Object Drawing.Pen $main, $ringW
                $arc.StartCap = 'Round'; $arc.EndCap = 'Round'
                $g.DrawArc($arc, $rect, -90, $sweep); $arc.Dispose()
            }
        }

        # label + value
        $textTop = $cy - $rowH / 2
        $lblBrush = New-Object Drawing.SolidBrush (Set-Alpha $col.Fg 0.65)
        $g.DrawString($row.Label, $fontLbl, $lblBrush, (New-Object Drawing.RectangleF ($pad + $ringD + 4 * $s), $textTop, ($w), $rowH), $left)
        $lblBrush.Dispose()
        $value = if ($stale -or $null -eq $used) { [string][char]0x2013 }
                 elseif ($showRemaining)         { "$(100 - $used)%" }
                 else                            { "$used%" }
        $valBrush = New-Object Drawing.SolidBrush $main
        $g.DrawString($value, $fontVal, $valBrush, (New-Object Drawing.RectangleF 0, $textTop, ($w - $pad), $rowH), $right)
        $valBrush.Dispose()
    }
    $fontVal.Dispose(); $fontLbl.Dispose(); $right.Dispose(); $left.Dispose(); $g.Dispose()

    # Push the bitmap (with per-pixel alpha) to the layered window.
    $screenDc = [ClaudeWidget.Native]::GetDC([IntPtr]::Zero)
    $memDc    = [ClaudeWidget.Native]::CreateCompatibleDC($screenDc)
    $hBmp     = $bmp.GetHbitmap([Drawing.Color]::FromArgb(0))
    $oldObj   = [ClaudeWidget.Native]::SelectObject($memDc, $hBmp)
    $size  = New-Object ClaudeWidget.Native+SIZE;  $size.W = $w; $size.H = $h
    $src   = New-Object ClaudeWidget.Native+POINT
    $blend = New-Object ClaudeWidget.Native+BLEND; $blend.Alpha = 255; $blend.Format = 1   # AC_SRC_ALPHA
    if (-not [ClaudeWidget.Native]::UpdateLayeredWindow($script:Form.Handle, $screenDc, [IntPtr]::Zero, [ref]$size, $memDc, [ref]$src, 0, [ref]$blend, 2)) {
        Write-Log "UpdateLayeredWindow failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    [ClaudeWidget.Native]::SelectObject($memDc, $oldObj) | Out-Null
    [ClaudeWidget.Native]::DeleteObject($hBmp) | Out-Null
    [ClaudeWidget.Native]::DeleteDC($memDc) | Out-Null
    [ClaudeWidget.Native]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null
    $bmp.Dispose()

    Update-Tooltip
}

function Update-Tooltip {
    $lines = @()
    if ($script:StaleReason) { $lines += "Not current: $($script:StaleReason)" }
    if ($script:LastGood) {
        $d = $script:LastGood
        $lines += "5-hour: $(Get-Percent $d.five_hour)% used ($(Format-Reset $d.five_hour.resets_at))"
        $lines += "Weekly: $(Get-Percent $d.seven_day)% used ($(Format-Reset $d.seven_day.resets_at))"
        foreach ($l in @($d.limits | Where-Object { $_.kind -eq 'weekly_scoped' -and $_.scope.model.display_name })) {
            $lines += "Weekly $($l.scope.model.display_name): $($l.percent)% used"
        }
        $lines += '{0} {1:HH:mm}' -f $(if ($script:StaleReason) { 'Last good data:' } else { 'Updated' }), $script:LastGoodTime
    }
    $script:Tip.SetToolTip($script:Form, ($lines -join "`n"))
}

# ---------------------------------------------------------------- placement inside the taskbar
function Find-Taskbar { [ClaudeWidget.Native]::FindWindow('Shell_TrayWnd', $null) }

function Update-Layout {
    $tb = Find-Taskbar
    if ($tb -ne $script:Taskbar -or -not [ClaudeWidget.Native]::IsWindow($script:Taskbar)) { Restart-Widget; return }

    $tbRect = New-Object ClaudeWidget.Native+RECT
    [void][ClaudeWidget.Native]::GetWindowRect($tb, [ref]$tbRect)
    $trayLeft = $tbRect.Right
    $tray = [ClaudeWidget.Native]::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    if ($tray -ne [IntPtr]::Zero) {
        $trayRect = New-Object ClaudeWidget.Native+RECT
        [void][ClaudeWidget.Native]::GetWindowRect($tray, [ref]$trayRect)
        $trayLeft = $trayRect.Left
    }
    $scale = [ClaudeWidget.Native]::GetDpiForWindow($tb) / 96.0
    if ($scale -le 0) { $scale = 1 }
    $h = $tbRect.Bottom - $tbRect.Top
    $w = [int](78 * $scale)
    $x = $trayLeft - $w - [int](4 * $scale)
    $y = $tbRect.Top
    $new = @{ X = $x; Y = $y; W = $w; H = $h; Scale = $scale }

    $old = $script:Layout
    $script:Layout = $new
    if (-not $old -or $old.W -ne $w -or $old.H -ne $h -or $old.Scale -ne $scale -or $script:LightTheme -ne (Test-LightTheme)) { Draw-Widget }

    # Step aside for full-screen games/videos and presentations (QUNS_BUSY / D3D full screen / presentation mode).
    $state = 0
    [void][ClaudeWidget.Native]::SHQueryUserNotificationState([ref]$state)
    if ($state -in 2, 3, 4) { [void][ClaudeWidget.Native]::ShowWindow($script:Form.Handle, 0); return }

    # HWND_TOPMOST; flags 0x0001 NOSIZE | 0x0010 NOACTIVATE | 0x0040 SHOWWINDOW
    [void][ClaudeWidget.Native]::SetWindowPos($script:Form.Handle, [IntPtr]-1, $x, $y, 0, 0, 0x0051)
}

function Restart-Widget {
    # Explorer restarted: our window died with the old taskbar. Start a fresh copy once the new one is up.
    if ((Find-Taskbar) -eq [IntPtr]::Zero) { return }   # not back yet; try again next tick
    Write-Log 'Taskbar recreated; restarting'
    $script:LayoutTimer.Stop(); $script:PollTimer.Stop()
    $mutex.ReleaseMutex()
    Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    [System.Windows.Forms.Application]::Exit()
}

# ---------------------------------------------------------------- refresh loop
function Invoke-Refresh {
    $script:PollTimer.Stop()
    try   { $delay = Update-Usage }
    catch { $delay = [TimeSpan]::FromMinutes(5); $script:StaleReason = 'internal error'; Write-Log "Error: $_" }
    try   { Draw-Widget } catch { Write-Log "Draw error: $_" }
    $script:PollTimer.Interval = [int][Math]::Max(1000, $delay.TotalMilliseconds)
    $script:PollTimer.Start()
}

# ---------------------------------------------------------------- startup toggle
function Get-StartupCommand { "`"$(Join-Path $PSHOME 'powershell.exe')`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"" }
function Test-Startup { [bool](Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- window
$script:Taskbar = Find-Taskbar
if ($script:Taskbar -eq [IntPtr]::Zero) { Write-Log 'No taskbar found'; exit }

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.FormBorderStyle = 'None'
$script:Form.ShowInTaskbar   = $false
$script:Form.StartPosition   = 'Manual'
$script:Form.Location        = New-Object Drawing.Point -32000, -32000
$script:Form.Size            = New-Object Drawing.Size 1, 1
$script:Form.Show()

# Make it a per-pixel-transparent window that never takes focus, and let the taskbar own it:
# Windows always keeps an owned window above its owner, so the taskbar can't cover it.
$hwnd = $script:Form.Handle
$exStyle = [ClaudeWidget.Native]::GetWindowLong($hwnd, -20) -bor 0x80000 -bor 0x80 -bor 0x08000000   # WS_EX_LAYERED | TOOLWINDOW | NOACTIVATE
[void][ClaudeWidget.Native]::SetWindowLong($hwnd, -20, $exStyle)
[void][ClaudeWidget.Native]::SetWindowLongPtr($hwnd, -8, $script:Taskbar)                                # GWLP_HWNDPARENT = owner

$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.ShowAlways   = $true
$script:Tip.InitialDelay = 300
$script:Tip.AutoPopDelay = 15000

# ---------------------------------------------------------------- menu
$menu          = New-Object System.Windows.Forms.ContextMenuStrip
$refreshItem   = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh now'
$remainingItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Show remaining instead of used'
$intervalItem  = New-Object System.Windows.Forms.ToolStripMenuItem 'Update interval'
$startupItem   = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$openItem      = New-Object System.Windows.Forms.ToolStripMenuItem 'Open usage page'
$exitItem      = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'

$remainingItem.CheckOnClick = $true
$remainingItem.Checked = [int](Get-Setting 'ShowRemaining' 0) -eq 1
$startupItem.CheckOnClick = $true
$startupItem.Checked = Test-Startup

foreach ($m in 2, 5, 10, 15) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem "$m minutes"
    $item.Tag = $m
    $item.Checked = ([int](Get-Setting 'IntervalMinutes' 5) -eq $m)
    $item.add_Click({
        param($sender)
        Set-Setting 'IntervalMinutes' ([int]$sender.Tag)
        foreach ($other in $intervalItem.DropDownItems) { $other.Checked = ($other -eq $sender) }
        Invoke-Refresh
    })
    [void]$intervalItem.DropDownItems.Add($item)
}

[void]$menu.Items.AddRange(@(
    $refreshItem, $openItem, (New-Object System.Windows.Forms.ToolStripSeparator),
    $remainingItem, $intervalItem, $startupItem, (New-Object System.Windows.Forms.ToolStripSeparator),
    $exitItem))

$refreshItem.add_Click({ Invoke-Refresh })
$openItem.add_Click({ Start-Process $UsagePageUrl })
$remainingItem.add_Click({ Set-Setting 'ShowRemaining' ([int]$remainingItem.Checked); Draw-Widget })
$startupItem.add_Click({
    try {
        if ($startupItem.Checked) { Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value (Get-StartupCommand) }
        else                      { Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue }
    } catch { Write-Log "Startup toggle failed: $_" }
    $startupItem.Checked = Test-Startup
})
$exitItem.add_Click({
    $script:LayoutTimer.Stop(); $script:PollTimer.Stop()
    $script:Form.Close()
    [System.Windows.Forms.Application]::Exit()
})

$script:Form.add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq 'Left')  { Start-Process $UsagePageUrl }
    if ($e.Button -eq 'Right') { $menu.Show([System.Windows.Forms.Cursor]::Position) }
})

# ---------------------------------------------------------------- go
$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.add_Tick({ Invoke-Refresh })

$script:LayoutTimer = New-Object System.Windows.Forms.Timer
$script:LayoutTimer.Interval = 1000
$script:LayoutTimer.add_Tick({ try { Update-Layout } catch { Write-Log "Layout error: $_" } })

Write-Log 'Started'
Update-Layout
Invoke-Refresh
$script:LayoutTimer.Start()
[System.Windows.Forms.Application]::Run()

Write-Log 'Exited'
try { $mutex.ReleaseMutex() } catch { }
