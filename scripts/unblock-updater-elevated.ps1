# unblock-updater-elevated.ps1 -- 撤销 block-updater-elevated.ps1（需要管理员，会弹 UAC）
# 删掉两条 IFEO、把 WPS 的计划任务恢复成启用、wpscloudsvr 回 Manual。

$ErrorActionPreference = 'SilentlyContinue'
$LogDir = Join-Path $env:LOCALAPPDATA 'file-assoc-guard'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
function Write-Log([string]$Path, $m) { ($m | Out-String).TrimEnd() | Out-File -Append -Encoding utf8 $Path }

# WPS 会把用户名后缀拼到任务名上，所以按前缀探测而不是写死全名
function Get-WpsTasks {
  Get-ScheduledTask | Where-Object { $_.TaskName -match '^Wps(Update|Wake|Push)' }
}

# 安装目录：先看跑着的进程，再看任务动作里的 exe，最后看常见路径
function Get-WpsDir {
  $c = @()
  $p = Get-Process ksolaunch, wps -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -and $p.Path) { $c += Split-Path $p.Path }
  foreach ($t in Get-WpsTasks) {
    foreach ($a in $t.Actions) { if ($a.Execute -and $a.Execute -notmatch 'powershell|cmd\.exe') { $c += Split-Path $a.Execute } }
  }
  $c += 'C:\Program Files\WPS Office', 'C:\Program Files (x86)\WPS Office', 'D:\WPS Office'
  foreach ($x in $c) { if ($x -and (Test-Path (Join-Path $x 'wpsupdate.exe'))) { return $x } }
  return ($c | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Assert-Elevated([string]$ScriptPath) {
  $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
  $ok = ([Security.Principal.WindowsPrincipal]$ident).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $ok) {
    Write-Host 'Need administrator rights, asking for UAC...'
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    exit
  }
  return $ident
}

$log = Join-Path $LogDir 'block.log'
Write-Log $log ("=== unblock updater (elevated) " + (Get-Date).ToString('s') + " ===")
$ident = Assert-Elevated $PSCommandPath
Write-Log $log ("user = " + $ident.Name)

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in 'wpsupdate.exe', 'updateself.exe') {
  $key = Join-Path $ifeo $exe
  try {
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction Stop; Write-Log $log ('OK    removed IFEO ' + $exe) }
    else { Write-Log $log ('SKIP  no IFEO key for ' + $exe) }
  } catch { Write-Log $log ('FAIL  ' + $exe + ' : ' + $_.Exception.Message) }
}

foreach ($t in Get-WpsTasks) {
  try { Enable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log $log ('OK    enabled ' + $t.TaskName) }
  catch { Write-Log $log ('FAIL  ' + $t.TaskName + ' : ' + $_.Exception.Message) }
}
try { Set-Service wpscloudsvr -StartupType Manual -ErrorAction Stop; Write-Log $log 'OK    wpscloudsvr -> Manual' }
catch { Write-Log $log ('FAIL  set service: ' + $_.Exception.Message) }

Write-Log $log ''
Write-Log $log '--- verify ---'
foreach ($exe in 'wpsupdate.exe', 'updateself.exe') {
  $v = (Get-ItemProperty (Join-Path $ifeo $exe) -Name Debugger).Debugger
  Write-Log $log ('  ' + $exe.PadRight(16) + $(if ($v) { 'still blocked: ' + $v } else { 'free' }))
}
foreach ($t in Get-WpsTasks) { Write-Log $log ('  ' + $t.TaskName.PadRight(34) + $t.State) }
$s = Get-Service wpscloudsvr -ErrorAction SilentlyContinue
if ($s) { Write-Log $log ('  wpscloudsvr ' + $s.Status + ' / ' + $s.StartType) }

Write-Log $log ''
Write-Log $log '===== done ====='
Write-Host ('log: ' + $log)
