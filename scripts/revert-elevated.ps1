# revert-elevated.ps1 -- 把 fix 脚本改过的项目还原（需要管理员，会弹 UAC）
# 注意：文件关联本身（UserChoice）不在这里恢复 —— 那是系统给用户自己选的，
# 想让 WPS 重新接管，直接在「设置 -> 默认应用」里改回去即可。

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
Write-Log $log ("=== revert (elevated) " + (Get-Date).ToString('s') + " ===")
$ident = Assert-Elevated $PSCommandPath
Write-Log $log ("user = " + $ident.Name)

Write-Log $log ''
Write-Log $log '--- 1. association-protection switches -> 1 ---'
$b = 'HKCU:\Software\Kingsoft\Office\6.0\Common'
function Set-Sw($path, $name, $value) {
  if (-not (Test-Path $path)) { Write-Log $log ('SKIP  no key ' + $path); return }
  try { New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null; Write-Log $log ('OK    ' + $name + ' = ' + $value) }
  catch { Write-Log $log ('FAIL  ' + $name + ' : ' + $_.Exception.Message) }
}
Set-Sw $b 'first_detect_file_association_while_startup' 1
Set-Sw "$b\ksomisc\assoprotectinfo" 'AssoProtectSwitch' 1
Set-Sw "$b\ksomisc" 'emergasso' 1

Write-Log $log ''
Write-Log $log '--- 2. re-enable WPS tasks ---'
foreach ($t in Get-WpsTasks) {
  try { Enable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Write-Log $log ('OK    enabled ' + $t.TaskName) }
  catch { Write-Log $log ('FAIL  ' + $t.TaskName + ' : ' + $_.Exception.Message) }
}

Write-Log $log ''
Write-Log $log '--- 3. service back to Manual ---'
try { Set-Service wpscloudsvr -StartupType Manual -ErrorAction Stop; Write-Log $log 'OK    wpscloudsvr -> Manual' }
catch { Write-Log $log ('FAIL  set service: ' + $_.Exception.Message) }

Write-Log $log ''
Write-Log $log '--- 4. verify ---'
foreach ($t in Get-WpsTasks) { Write-Log $log ('  ' + $t.TaskName.PadRight(34) + $t.State) }
$s = Get-Service wpscloudsvr -ErrorAction SilentlyContinue
if ($s) { Write-Log $log ('  wpscloudsvr ' + $s.Status + ' / ' + $s.StartType) }

Write-Log $log ''
Write-Log $log '===== done ====='
Write-Host ('log: ' + $log)
