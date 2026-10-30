# fix-elevated.ps1 -- 关掉 WPS 自启动四件套 + 三个关联保护开关（需要管理员，会弹 UAC）

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

$log = Join-Path $LogDir 'fix.log'
Write-Log $log ("=== fix (elevated) " + (Get-Date).ToString('s') + " ===")
$ident = Assert-Elevated $PSCommandPath
Write-Log $log ("user = " + $ident.Name)

Write-Log $log ''
Write-Log $log '--- 1. disable WPS scheduled tasks ---'
$tasks = @(Get-WpsTasks)
if (-not $tasks.Count) { Write-Log $log 'SKIP  no WPS task found' }
foreach ($t in $tasks) {
  try { Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log $log ('OK    disabled ' + $t.TaskName) }
  catch { Write-Log $log ('FAIL  ' + $t.TaskName + ' : ' + $_.Exception.Message) }
}

Write-Log $log ''
Write-Log $log '--- 2. service wpscloudsvr ---'
try { Stop-Service wpscloudsvr -Force -ErrorAction Stop; Write-Log $log 'OK    stopped' } catch { Write-Log $log ('INFO  stop: ' + $_.Exception.Message) }
try { Set-Service wpscloudsvr -StartupType Disabled -ErrorAction Stop; Write-Log $log 'OK    startup -> Disabled' } catch { Write-Log $log ('FAIL  set service: ' + $_.Exception.Message) }

Write-Log $log ''
Write-Log $log '--- 3. association-protection switches -> 0 ---'
$b = 'HKCU:\Software\Kingsoft\Office\6.0\Common'
function Set-Sw($path, $name, $value) {
  if (-not (Test-Path $path)) { Write-Log $log ('SKIP  no key ' + $path); return }
  try { New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null; Write-Log $log ('OK    ' + $path + ' :: ' + $name + ' = ' + $value) }
  catch { Write-Log $log ('FAIL  ' + $name + ' : ' + $_.Exception.Message) }
}
Set-Sw $b 'first_detect_file_association_while_startup' 0
Set-Sw "$b\ksomisc\assoprotectinfo" 'AssoProtectSwitch' 0
Set-Sw "$b\ksomisc" 'emergasso' 0

Write-Log $log ''
Write-Log $log '--- 4. verify ---'
foreach ($t in Get-WpsTasks) { Write-Log $log ('  ' + $t.TaskName.PadRight(34) + ' State=' + $t.State) }
$s = Get-Service wpscloudsvr -ErrorAction SilentlyContinue
if ($s) { Write-Log $log ('  wpscloudsvr ' + $s.Status + ' / ' + $s.StartType) }
Write-Log $log ('  first_detect = ' + (Get-ItemProperty $b).first_detect_file_association_while_startup)
Write-Log $log ('  AssoProtectSwitch = ' + (Get-ItemProperty "$b\ksomisc\assoprotectinfo").AssoProtectSwitch)
Write-Log $log ('  emergasso = ' + (Get-ItemProperty "$b\ksomisc").emergasso)

Write-Log $log ''
Write-Log $log '--- 5. anything else pointing at WPS (services / tasks) ---'
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'WPS Office|Kingsoft' } |
  ForEach-Object { Write-Log $log ('  svc  ' + $_.Name + ' ' + $_.StartMode + '/' + $_.State + ' :: ' + $_.PathName) }
Get-ScheduledTask | Where-Object { ($_.Actions | ForEach-Object { $_.Execute }) -match 'WPS Office|Kingsoft' } |
  ForEach-Object { Write-Log $log ('  task ' + $_.TaskName + ' State=' + $_.State) }

Write-Log $log ''
Write-Log $log '===== done ====='
Write-Host ('log: ' + $log)
