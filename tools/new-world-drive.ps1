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
  [string]$ColumnPattern = ''
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
$freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($freeGB -lt 16) { L ("SKIP: free RAM {0:N1} GB < 16" -f $freeGB); $res.notes += 'low RAM'; Finish 8 }
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
if ($tJoin) { try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing; $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $shot = Join-Path $DataPath "new-world-shot-$stamp.png"; $bmp.Save($shot); $g.Dispose(); $bmp.Dispose(); $res.screenshot = $shot; L "screenshot $shot" } catch { L "screenshot failed: $_" } }
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
Finish $(if ($res.joined) { 0 } else { 3 })
