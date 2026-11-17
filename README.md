# HiDPI

一个很小的 macOS 菜单栏应用：给**任何显示器**（比如 2K / 2560×1440 屏）开启“软件 HiDPI”，并且可以一键切换分辨率。
基于虚拟显示器 + 镜像实现，不需要 root、不改系统文件。

## 使用

```bash
./scripts/build-app.sh            # 生成 build/HiDPI.app（universal，ad-hoc 签名）
./scripts/build-app.sh --install  # 同时复制到 /Applications
open build/HiDPI.app
```

| 菜单项 | 作用 |
|---|---|
| **Software HiDPI** | 勾选即开启；默认保持当前 UI 大小，只是变清晰 |
| **Resolution ▸** | 切换分辨率。未开 HiDPI 时是系统原生模式（标记 HiDPI / Native）；开启后是 2x 的 “looks like” 列表 |
| Show Low Resolution Modes | 显示已有 HiDPI 版本的 1x 重复模式 |
| Launch at Login | 开机启动（建议先把 app 放进 /Applications） |

开启状态和所选分辨率会被记住：下次启动、或显示器重新插上时自动恢复。

**随时可还原**：取消勾选、退出 app，甚至 app 崩溃，虚拟屏都会随进程消失，显示器自动回到原来的模式。

## 代码结构

```
Package.swift
Sources/
  VirtualDisplayShim/     Objective-C：私有虚拟屏 API（运行时查找类，不链接私有框架）
                          macOS 27+ 用 SkyLight SLVirtualDisplay，≤26 用 CGVirtualDisplay
  HiDPI/
    HiDPIApp.swift        入口、AppDelegate（退出时还原）
    StatusMenu.swift      原生 NSStatusItem + NSMenu
    DisplayManager.swift  显示器列表、HiDPI 会话、偏好保存、开机启动
    HiDPISession.swift    建虚拟屏 → 选模式 → 镜像；生成 “looks like” 分辨率列表
    Displays.swift        CoreGraphics 公共 API：模式枚举、切换、镜像
    SelfTest.swift        --list / --menu / --selftest
Resources/Info.plist      LSUIElement（无 Dock 图标）
scripts/build-app.sh      打包 .app
```