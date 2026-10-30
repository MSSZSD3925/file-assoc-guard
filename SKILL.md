---
name: file-assoc-guard
description: 处理「文件关联被抢回去」「默认打开方式自己变回来」「关掉的自启动/更新任务过一阵又出现」这类问题，也用于复查现状或全部还原。当用户说"WPS 又抢关联了""默认打开方式变回 WPS 了""关掉自启动又回来了""更新任务禁不掉"时使用。
---

# 文件关联与自启动守卫

现成脚本就在本技能目录的 `scripts\` 下，别再重写：

```
scripts\check-status.ps1              只读复查，不需要管理员，随时可跑
scripts\fix-elevated.ps1              关掉自启动四件套 + 三个关联保护开关（要管理员）
scripts\block-updater-elevated.ps1    让更新器根本跑不起来（要管理员）
scripts\unblock-updater-elevated.ps1  只撤销上面那步
scripts\revert-elevated.ps1           把 fix 改过的项目还原（要管理员）
```

日志在 `%LOCALAPPDATA%\file-assoc-guard\`（`fix.log`、`block.log`）。

## 为什么"禁用了又回来"

以 WPS 为例，它的更新任务是每小时跑一次 `ksolaunch.exe /wpsupdate -from=task -source=task`，
更新器进程内部有一步 `kupdate::Execute cmd=[-repairtask]`，作用就是"修复自己的计划任务"：
重新建好、重新启用，顺手还把 `wpscloudsvr` 服务恢复。日志里表现为
`run repair schd exe success`（在 `%APPDATA%\kingsoft\office6\log\update\wpsupdate_*.log`）。

所以只 `Disable-ScheduledTask` 是治标的。要治本得让更新器启动不了：
在 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\`
下给 `wpsupdate.exe`、`updateself.exe` 挂 `Debugger = C:\Windows\System32\cmd.exe /c exit`，
这两个程序启动即退出；`ksolaunch.exe` 不动，打开 WPS 本体照常。
IFEO 按文件名生效，升级替换 exe 也绕不过。

## 流程

1. 先跑只读复查，看清楚哪条腿回来了：

       powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-status.ps1

   看三处：任务 `State=Ready`（被重建了）、关联行显示 WPS（UserChoice 被写回）、
   IFEO 段显示 `(not blocked)`。

2. 提权修复，UAC 由用户自己点，不要试图静默提权：

       Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Resolve-Path .\scripts\fix-elevated.ps1)

3. 如果任务反复回来（复查又是 Ready、任务 XML 的 mtime 是近期），跑根治脚本，再按下面的方式验证：

       Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Resolve-Path .\scripts\block-updater-elevated.ps1)

4. 验证不必等一小时，直接手动拉起更新器看日志体积：

       $f = "$env:APPDATA\kingsoft\office6\log\update\wpsupdate_" + (Get-Date -Format yyyy_MM_dd) + '.log'
       $b = (Get-Item $f).Length
       Start-Process (Join-Path $wpsDir 'ksolaunch.exe') -ArgumentList '/wpsupdate','-from=task','-source=task'
       Start-Sleep -Seconds 10
       (Get-Item $f).Length -eq $b   # True = 被拦住；同时 Get-Process wpsupdate 应为空

   注意：`Start-ScheduledTask` 对已禁用的任务会直接报"任务被禁用"，那不算验证。

5. 告诉用户代价：更新器被拦之后软件不再自动升级，要新版本时手动检查更新。

## 被抢的几条腿（排查清单）

自启动：更新任务（每小时）、登录任务（每次登录）、推送任务（登录拉起消息推送插件）、
`wpscloudsvr` 服务。关联保护开关在 `HKCU\Software\Kingsoft\Office\6.0\Common` 下：
`first_detect_file_association_while_startup`、`ksomisc\assoprotectinfo\AssoProtectSwitch`、
`ksomisc\emergasso`。关联本身写两处：`FileExts\<ext>\UserChoice`（真正生效）和
`HKCU\Software\Classes\.<ext>`。

## 环境约束

- 计划任务与服务必须管理员，UAC 弹窗要用户自己点。
- `.ps1` 存成 UTF-8 带 BOM：PowerShell 5.1 读无 BOM 的脚本按 GBK 解码，中文变乱码并报语法错。
- 任务名带用户名后缀（如 `WpsUpdateTask_<用户名>`），脚本按前缀 `^Wps(Update|Wake|Push)` 探测，别写死。
- `.pdf\UserChoice` 被系统自己的 Deny ACE 锁住，管理员也改不了，只能走「设置 -> 默认应用」。
- 想恢复自启：`unblock-updater-elevated.ps1`（只撤 IFEO）或 `revert-elevated.ps1`（连开关一起还原）。
