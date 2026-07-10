# Villode Caelestia

基于 [Caelestia Shell](https://github.com/caelestia-dots/shell) 的个人二次开发整合项目。

本仓库提供统一安装入口，各功能仍由独立仓库维护。安装时可以自由选择中文化、Dock、Desktop 和 Launcher，不会把所有组件强制捆绑在一起。

## 组件

| 组件 | 作用 | 独立仓库 |
| --- | --- | --- |
| 中文化 | Caelestia Shell 简体中文界面 | [caelestia-zh-cn](https://github.com/Villode/caelestia-zh-cn) |
| Dock | macOS 风格 Dock、实时毛玻璃、拖放固定 | [villode-dock](https://github.com/Villode/villode-dock) |
| Desktop | 静态图片、视频和 HTML 桌面层 | [villode-desktop](https://github.com/Villode/villode-desktop) |
| Launcher | macOS 风格应用启动台，与 Dock 拖放联动 | [villode-launcher](https://github.com/Villode/villode-launcher) |

安装器通过 `components.tsv` 锁定每个组件的提交版本，避免上游仓库更新造成不可重复安装。

## 前提

- Hyprland / Wayland
- Git
- 中文化组件需要已安装 `caelestia-shell` 和 `caelestia-cli`
- 使用 `--with-deps` 时需要 `sudo` 权限

## 交互式安装

```bash
git clone https://github.com/Villode/villode-caelestia.git
cd villode-caelestia
./install.sh
```

安装器会显示组件菜单，可以输入一个或多个编号。

## 一键安装全部组件

```bash
./install.sh --all --with-deps
```

只安装指定组件：

```bash
./install.sh --components zh,dock,launcher --with-deps
```

只部署文件，不启动程序，也不修改 Hyprland 配置：

```bash
./install.sh --all --no-start --no-hyprland
```

已经下载过对应版本后，可以离线安装：

```bash
./install.sh --all --offline
```

## 卸载

交互式选择：

```bash
villode-caelestia-uninstall
```

卸载全部组件：

```bash
villode-caelestia-uninstall --all
```

卸载指定组件并清理它们的用户数据：

```bash
villode-caelestia-uninstall --components dock,launcher --purge
```

默认卸载不会删除组件用户数据。中文化卸载也不会自动删除 `~/.config/quickshell/caelestia`，避免误删用户自行修改的 QML。

## 项目边界

- 统一仓库只负责编排安装，不复制各组件源码。
- 每个组件可独立安装、更新和卸载。
- 不包含本机配置、缓存、日志、密钥或个人素材。
- Caelestia Shell 的上游代码仍遵循 GPL-3.0-only。

## 许可

统一安装器以 MIT License 发布；被安装组件分别遵循各自仓库中的许可证。
