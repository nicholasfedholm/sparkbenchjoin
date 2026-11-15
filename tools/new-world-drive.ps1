# Creates a fresh test world via game args with the sparkbenchjoin mod (skips char select, creative),
# waits for join + settle, closes normally (WM_CLOSE to the launched PID only), writes a result json.
# Never kills foreign processes. Only kills the PID it launched, and only after WM_CLOSE + 120 s.
param(
  [Parameter(Mandatory)][string]$Reason,
  [string]$WorldPrefix = 'Test Standard',
  [string]$PlayStyle = 'preset-surviveandbuild',
  [Parameter(Mandatory)][string]$DataPath,
  [string]$GameExe = (Join-Path $env:APPDATA 'Vintagestory\Vintagestory.exe'),
  [Parameter(Mandatory)][string]$ModZip,
  [int]$MinColumns = 49,
  [int]$MaxSeconds = 600,
  [int]$SettleSeconds = 60,
  [string]$ColumnPattern = '',
  [double]$MinFreeCommitGB = 25
)
$ErrorActionPreference = 'Continue'
$realData = Join-Path $env:APPDATA 'VintagestoryData'
if ((Resolve-Path -LiteralPath $DataPath -ErrorAction SilentlyContinue).Path -eq $realData -or $DataPath.TrimEnd('\') -eq $realData) { throw 'refusing real VintagestoryData' }
New-Item -ItemType Directory -Force -Path $DataPath | Out-Null
$world = "$WorldPrefix $Reason"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultPath = Join-Path $DataPath "new-world-result-$stamp.json"
$drvLog = Join-Path $DataPath "new-world-drive-$stamp.log"
function L($m) { $s = "{0:HH:mm:ss} {1}" -f (Get-Date), $m; Add-Content -LiteralPath $drvLog -Value $s -Encoding utf8; Write-Host $s }
$res = [ordered]@{ world = $world; joined = $false; creative = $null; charDialogSeen = $null; columns = $null; settle_s = $null; vram_mib = [ordered]@{ baseline = $null; at_join = $null; peak = $null; final = $null; delta_peak = $null }; vram_note = 'GPU-wide memory.used (nvidia-smi); WDDM gives no per-process value, so delta vs pre-launch baseline';
  elapsed_s = $null; exit = $null; closed_normally = $null; killed = $false; notes = @() }
function Vram { try { [int]((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) | Select-Object -First 1) } catch { $null } }
function VPeak { $v = Vram; if ($v -ne $null -and ($res.vram_mib.peak -eq $null -or $v -gt $res.vram_mib.peak)) { $res.vram_mib.peak = $v }; $v }
function Finish($code) {
  $res.exit = $code; $res.elapsed_s = [int]((Get-Date) - $t0).TotalSeconds
  ($res | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $resultPath -Encoding utf8
  L "result: $resultPath exit=$code"; exit $code
}
$t0 = Get-Date
# preflight
$foreign = Get-Process | Where-Object { $_.ProcessName -match 'Vintagestory|Optimum' }
if ($foreign) { $foreign | ForEach-Object { L "FOREIGN $($_.Id) $($_.ProcessName)" }; $res.notes += 'foreign game process, not touched'; Finish 9 }
$os = Get-CimInstance Win32_OperatingSystem
$freeGB = $os.FreePhysicalMemory / 1MB; $commitGB = $os.FreeVirtualMemory / 1MB
$res.free_ram_gb = [math]::Round($freeGB,1); $res.free_commit_gb = [math]::Round($commitGB,1)
L ("preflight: free RAM {0:N1} GB, free commit {1:N1} GB" -f $freeGB, $commitGB)
if ($freeGB -lt 16) { L ("SKIP: free RAM {0:N1} GB < 16" -f $freeGB); $res.notes += 'low RAM'; Finish 8 }
if ($commitGB -lt $MinFreeCommitGB) { L ("SKIP: free commit {0:N1} GB < $MinFreeCommitGB (never launch into pressure)" -f $commitGB); $res.notes += 'low commit'; Finish 8 }
if (-not (Test-Path -LiteralPath $GameExe)) { L "no game exe $GameExe"; Finish 7 }
if (-not (Test-Path -LiteralPath $ModZip)) { L "no mod zip $ModZip"; Finish 7 }
$modDir = Join-Path $DataPath 'runmods'
New-Item -ItemType Directory -Force -Path $modDir | Out-Null
Copy-Item -LiteralPath $ModZip -Destination $modDir -Force
# pin modPaths to the scratch Mods + runmods only (a live clientsettings copy points at the real Mods folder)
$csPath = Join-Path $DataPath 'clientsettings.json'
if (Test-Path -LiteralPath $csPath) {
  $py = "import json,sys;p,m=sys.argv[1],sys.argv[2];d=json.load(open(p,encoding='utf-8-sig'));d.setdefault('stringListSettings',{})['modPaths']=['Mods',m];json.dump(d,open(p,'w',encoding='utf-8'),indent=2);print('modPaths',d['stringListSettings']['modPaths'])"
  L (& py -3 -c $py $csPath $modDir 2>&1 | Out-String).Trim()
}
$serverLog = Join-Path $DataPath 'Logs\server-main.log'
$clientLog = Join-Path $DataPath 'Logs\client-main.log'
$res.vram_mib.baseline = Vram; L "vram baseline $($res.vram_mib.baseline) MiB"
# launch (direct, same process context as caller; run this script from an interactive session or a one-off interactive schtask)
$argList = @('--openWorld', "`"$world`"", '--playStyle', $PlayStyle, '--dataPath', "`"$DataPath`"")
$gp = Start-Process -FilePath $GameExe -ArgumentList $argList -PassThru -WorkingDirectory (Split-Path $GameExe)
L "launched pid $($gp.Id): $($argList -join ' ')"
$tJoin = $null
function Has($file, $pat) { (Test-Path -LiteralPath $file) -and (Select-String -LiteralPath $file -Pattern $pat -Quiet) }
while (((Get-Date) - $t0).TotalSeconds -lt $MaxSeconds) {
  Start-Sleep 3; $gp.Refresh()
  if ($gp.HasExited) { L "game exited early code $($gp.ExitCode)"; $res.notes += 'game exited early'; $res.closed_normally = $false; Finish 2 }
  if (-not $tJoin -and (Has $serverLog '\[sparkbenchjoin\] join ')) {
    $tJoin = Get-Date; $res.joined = $true; $res.vram_mib.at_join = VPeak; L "join line seen, vram $($res.vram_mib.at_join) MiB"
    $cur = Select-String -LiteralPath $serverLog -Pattern '\[sparkbenchjoin\] join .*gamemode=(\w+)' | Select-Object -Last 1
    if ($cur) { L "gamemode at join=$($cur.Matches[0].Groups[1].Value)" }
  }
  if ($tJoin) {
    [void](VPeak)
    if ($ColumnPattern -and (Test-Path -LiteralPath $clientLog)) {
      $n = @(Select-String -LiteralPath $clientLog -Pattern $ColumnPattern).Count
      $res.columns = $n
      if ($n -ge $MinColumns) { L "columns signal $n >= $MinColumns"; break }
    } elseif (((Get-Date) - $tJoin).TotalSeconds -ge $SettleSeconds) {
      $res.settle_s = $SettleSeconds; $res.notes += "no column signal; fixed settle $SettleSeconds s after join (MinColumns=$MinColumns not measured)"; break
    }
  }
}
$res.creative = [bool](Has $serverLog '\[sparkbenchjoin\] gamemode=Creative set'); L "creative set: $($res.creative)"
if ($tJoin) { try {
  Add-Type -AssemblyName System.Drawing
  if (-not ('SbjWin' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class SbjWin { [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f); }' }
  $gp.Refresh(); $h = $gp.MainWindowHandle; $r = New-Object SbjWin+RECT; [void][SbjWin]::GetWindowRect($h, [ref]$r)
  $w = $r.R - $r.L; $hh = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $hh; $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
  $ok = [SbjWin]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc)
  # brightness sample so an all-black capture is flagged instead of trusted
  $sum = 0; $n = 0; for ($x = 0; $x -lt $w; $x += [math]::Max(1, [int]($w / 40))) { for ($y = 0; $y -lt $hh; $y += [math]::Max(1, [int]($hh / 40))) { $p = $bmp.GetPixel($x, $y); $sum += ($p.R + $p.G + $p.B) / 3; $n++ } }
  $shot = Join-Path $DataPath "new-world-shot-$stamp.png"; $bmp.Save($shot); $g.Dispose(); $bmp.Dispose()
  $res.screenshot = $shot; $res.screenshot_mean = [int]($sum / [math]::Max(1, $n)); $res.screenshot_method = "PrintWindow(game hwnd) ok=$ok ${w}x$hh"
  L "screenshot $shot (game window only, PrintWindow ok=$ok, mean brightness $($res.screenshot_mean))"
} catch { L "screenshot failed: $_" } }
$res.vram_mib.final = VPeak; if ($res.vram_mib.baseline -ne $null -and $res.vram_mib.peak -ne $null) { $res.vram_mib.delta_peak = $res.vram_mib.peak - $res.vram_mib.baseline }; L "vram final $($res.vram_mib.final) peak $($res.vram_mib.peak) MiB"
if (-not $tJoin) { L 'FAIL: no join line within MaxSeconds'; $res.notes += 'timeout before join' }
# dialog check: vanilla logs nothing on open, so best-effort grep plus server-side proof (moddata line)
$res.charDialogSeen = (Has $clientLog 'GuiDialogCreateCharacter|begincharacterselection|CreateCharacter')
$res.notes += 'charDialogSeen is log-grep only; vanilla may log nothing, confirm visually on first run'
if (Has $serverLog '\[sparkbenchjoin\] createCharacter=true') { $res.notes += 'createCharacter moddata set by mod (server log)' }
$clientPlaying = Has $clientLog 'Playing'
$res.notes += "client log 'Playing' hit: $clientPlaying"
# close normally, only our PID
$gp.Refresh()
if (-not $gp.HasExited) {
  L "CloseMainWindow pid $($gp.Id) window=$($gp.MainWindowHandle)"
  [void]$gp.CloseMainWindow()
  if ($gp.WaitForExit(120000)) { $res.closed_normally = $true; L "exited code $($gp.ExitCode)" }
  else { L "no exit in 120 s, killing own pid $($gp.Id)"; $res.closed_normally = $false; $res.killed = $true; try { Stop-Process -Id $gp.Id -Force } catch { L "kill failed: $_" } }
}
# verify fully exited: our PID gone and no game process left before the next launch
Start-Sleep 3
$left = Get-Process | Where-Object { $_.ProcessName -match 'Vintagestory|Optimum' }
$res.game_procs_after = @($left).Count
if ($left) { $left | ForEach-Object { L "LEFTOVER game process $($_.Id) $($_.ProcessName) (not touched)" }; $res.notes += 'game process still present after close; do not launch again until it is gone'; Finish 4 }
Finish $(if ($res.joined) { 0 } else { 3 })
