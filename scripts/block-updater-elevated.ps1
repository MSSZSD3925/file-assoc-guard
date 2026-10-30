# block-updater-elevated.ps1 -- 让更新器根本跑不起来（需要管理员，会弹 UAC）
#
# 为什么需要这一步：更新任务每次运行，更新器内部都会执行 -repairtask，
# 把它自己的计划任务重新建好、重新启用（日志里是 run repair schd exe success）。
# 所以只禁用任务，下一小时它自己又修回来。
# 办法：在 Image File Execution Options 里给更新器挂一个立即退出的 Debugger，
# 这两个程序启动即退出，任务没有可执行的东西，也就没人修任务了。
# 启动器 ksolaunch.exe 不动，打开 WPS 本体照常。

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
Write-Log $log ("=== block updater (elevated) " + (Get-Date).ToString('s') + " ===")
$ident = Assert-Elevated $PSCommandPath
Write-Log $log ("user = " + $ident.Name)

$wpsDir = Get-WpsDir
Write-Log $log ('WPS dir = ' + $wpsDir)

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$debugger = 'C:\Windows\System32\cmd.exe /c exit'
Write-Log $log ''
Write-Log $log '--- 1. IFEO block ---'
foreach ($exe in 'wpsupdate.exe', 'updateself.exe') {
  $key = Join-Path $ifeo $exe
  try {
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Debugger' -Value $debugger -PropertyType String -Force | Out-Null
    Write-Log $log ('OK    blocked ' + $exe)
  } catch { Write-Log $log ('FAIL  ' + $exe + ' : ' + $_.Exception.Message) }
}

Write-Log $log ''
Write-Log $log '--- 2. disable tasks + service ---'
foreach ($t in Get-WpsTasks) {
  try { Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log $log ('OK    disabled ' + $t.TaskName) }
  catch { Write-Log $log ('FAIL  ' + $t.TaskName + ' : ' + $_.Exception.Message) }
}
try { Stop-Service wpscloudsvr -Force -ErrorAction Stop } catch { Write-Log $log ('INFO  stop: ' + $_.Exception.Message) }
try { Set-Service wpscloudsvr -StartupType Disabled -ErrorAction Stop; Write-Log $log 'OK    wpscloudsvr -> Disabled' } catch { Write-Log $log ('FAIL  set service: ' + $_.Exception.Message) }

Write-Log $log ''
Write-Log $log '--- 3. verify: launch the updater by hand, watch the log file size ---'
$day = Get-Date -Format 'yyyy_MM_dd'
$uLog = Join-Path $env:APPDATA ("kingsoft\office6\log\update\wpsupdate_$day.log")
$before = (Get-Item $uLog -ErrorAction SilentlyContinue).Length
$launcher = if ($wpsDir) { Join-Path $wpsDir 'ksolaunch.exe' } else { '' }
if ($launcher -and (Test-Path $launcher)) {
  Start-Process $launcher -ArgumentList '/wpsupdate', '-from=task', '-source=task'
  Start-Sleep -Seconds 10
  $still = Get-Process wpsupdate -ErrorAction SilentlyContinue
  $after = (Get-Item $uLog -ErrorAction SilentlyContinue).Length
  Write-Log $log ('  updater process now: ' + $(if ($still) { 'RUNNING (block failed)' } else { 'none' }))
  Write-Log $log ('  update log size: ' + $before + ' -> ' + $after)
  Write-Log $log ('  verdict: ' + $(if ($after -eq $before -and -not $still) { 'blocked' } else { 'NOT blocked' }))
} else {
  Write-Log $log 'SKIP  launcher not found, run the task once by hand and check the update log'
}

Write-Log $log ''
Write-Log $log '===== done ====='
Write-Host ('log: ' + $log)
