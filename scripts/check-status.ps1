# check-status.ps1 -- 只读复查。不改任何东西，不需要管理员，随时可跑。

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

Write-Output '=== 1. 关联保护开关（HKCU\Software\Kingsoft\Office\6.0\Common）==='
$b = 'HKCU:\Software\Kingsoft\Office\6.0\Common'
Write-Output ('  first_detect_file_association_while_startup = ' + (Get-ItemProperty $b).first_detect_file_association_while_startup)
Write-Output ('  AssoProtectSwitch                           = ' + (Get-ItemProperty "$b\ksomisc\assoprotectinfo").AssoProtectSwitch)
Write-Output ('  emergasso                                   = ' + (Get-ItemProperty "$b\ksomisc").emergasso)

Write-Output ''
Write-Output '=== 2. 文件关联实际生效值 ==='
$tmp = Join-Path $env:TEMP 'assoc-probe'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$exts = '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.csv', '.pdf'
foreach ($e in $exts) { New-Item -ItemType File -Force -Path (Join-Path $tmp "probe$e") | Out-Null }
$ns = (New-Object -ComObject Shell.Application).NameSpace($tmp)
foreach ($e in $exts) {
  $uc = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$e\UserChoice").ProgId
  if (-not $uc) { $uc = '(none)' }
  Write-Output ('  ' + $e.PadRight(7) + $ns.ParseName("probe$e").Type.PadRight(34) + 'UserChoice=' + $uc)
}
Remove-Item $tmp -Recurse -Force

Write-Output ''
Write-Output '=== 3. 计划任务与服务 ==='
foreach ($t in Get-WpsTasks) { Write-Output ('  task ' + $t.TaskName.PadRight(34) + $t.State) }
$s = Get-Service wpscloudsvr
if ($s) { Write-Output ('  svc  ' + 'wpscloudsvr'.PadRight(34) + $s.Status + ' / ' + $s.StartType) }
else { Write-Output '  svc  wpscloudsvr  MISSING' }

Write-Output ''
Write-Output '=== 4. 更新器拦截（IFEO）==='
foreach ($exe in 'wpsupdate.exe', 'updateself.exe') {
  $v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe" -Name Debugger).Debugger
  Write-Output ('  ' + $exe.PadRight(16) + $(if ($v) { 'blocked -> ' + $v } else { '(not blocked)' }))
}

Write-Output ''
Write-Output '=== 5. 开机自启（Run 键）==='
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  $p = Get-ItemProperty $k
  $hit = @()
  if ($p) { foreach ($n in $p.PSObject.Properties.Name) { if ($n -match 'wps|kingsoft|kso') { $hit += $n } } }
  if ($hit.Count) { Write-Output ('  ' + $k + ' -> ' + ($hit -join ',')) }
  else { Write-Output ('  ' + $k + ' -> clean') }
}

Write-Output ''
$procs = (Get-Process | Where-Object { $_.Name -match 'wps|kso|kingsoft' } | ForEach-Object { $_.Name }) -join ','
Write-Output ('=== 6. 正在运行的 WPS 进程: ' + $(if ($procs) { $procs } else { 'none' }))
