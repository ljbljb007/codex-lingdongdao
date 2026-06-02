# Codex 灵动岛

macOS 顶部悬浮窗，用灵动岛样式显示 Codex 当前 5 小时和 1 周用量窗口的剩余百分比。

## 功能

- 显示 5 小时窗口剩余用量
- 显示 1 周窗口剩余用量
- 每 5 秒从本机 Codex 会话日志刷新
- 点击展开详情，右键退出
- 支持安装为开机自启

## 数据来源

应用只读取本机 `~/.codex/sessions` 下 Codex 写入的 `rate_limits` 快照，不联网、不上传数据。

显示值和 Codex 设置菜单一致：`100 - used_percent`，即剩余百分比。

## 构建

```bash
./scripts/build.sh
```

构建产物会生成在 `dist/CodexUsageIsland.app`。

## 运行

```bash
open dist/CodexUsageIsland.app
```

## 自检

```bash
dist/CodexUsageIsland.app/Contents/MacOS/CodexUsageIsland --print-usage
```

## 安装开机自启

```bash
./scripts/install-launch-agent.sh
```

安装后会立即启动应用。

## 卸载开机自启

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.codex.usage-island.plist"
rm "$HOME/Library/LaunchAgents/local.codex.usage-island.plist"
```
