# file-assoc-guard

一个给 DeepSeek Harness 用的技能（skill），处理两类烦人的事：

- 文件关联被办公软件抢回去，默认打开方式自己变回来
- 关掉的自启动/更新任务过一阵又出现，禁不掉

原理和排查过程写在 `SKILL.md` 里；脚本在 `scripts\` 下，全部可以单独读、单独跑。

## 为什么"禁用了又回来"

以 WPS 为例：更新任务每小时跑一次 `ksolaunch.exe /wpsupdate -from=task -source=task`，
更新器进程里有一句 `kupdate::Execute cmd=[-repairtask]`，专门"修复自己的计划任务"——
重新建好、重新启用，顺手把 `wpscloudsvr` 服务也恢复。日志里能看到
`run repair schd exe success`（`%APPDATA%\kingsoft\office6\log\update\`）。

所以只禁用任务没用，下一小时它自己修回来。治本的做法是让更新器启动不了：
在 IFEO 里给 `wpsupdate.exe` / `updateself.exe` 挂一个立即退出的 Debugger，
启动器 `ksolaunch.exe` 不动，打开软件本体照常。

## 安装

技能就是一个目录，放到 DSH 的技能目录里即可（Windows）：

    git clone https://github.com/MSSZSD3925/file-assoc-guard "%USERPROFILE%\.dsh\skills\file-assoc-guard"

没有 git 就下载 ZIP，把解压出来的文件夹改名放到 `%USERPROFILE%\.dsh\skills\file-assoc-guard`。
放好之后重启 DSH，技能列表里会出现 `file-assoc-guard`。

## 用法

不用记命令，直接跟 DSH 说"WPS 又抢关联了"或"关掉的自启动又回来了"，它会在技能目录里
找到这些脚本自己跑。想手动跑也可以：

    # 只读复查，不需要管理员
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-status.ps1

    # 修复（会弹 UAC，自己点"是"）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fix-elevated.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\block-updater-elevated.ps1

    # 撤销
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\unblock-updater-elevated.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\revert-elevated.ps1

日志写在 `%LOCALAPPDATA%\file-assoc-guard\`。

## 提醒

这些脚本会改注册表（HKCU 的开关与 IFEO 的 HKLM 键）、计划任务和系统服务，
跑之前请自己读一遍 `scripts\` 里的代码。它们不会删文件、不会上传任何东西、不联网。

副作用：更新器被拦之后，软件不再自动升级；需要新版本时自己在软件里检查更新。

## 卸载

删掉技能目录，再按上面的方式跑一遍 `unblock-updater-elevated.ps1` 与
`revert-elevated.ps1`，把系统改回去。

## License

MIT
