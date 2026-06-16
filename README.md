# CodexQuota

macOS 浮窗，显示 Codex（OpenAI ChatGPT Codex CLI）剩余额度——5 小时窗口 + 周窗口。

![preview](assets/preview.png)

## 数据来源

不调任何私有 API，直接读取本机 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 中 Codex CLI 写入的 `rate_limits` 字段。每次跑 Codex 时都会刷新。

## 安装

到 [Releases](https://github.com/myaiisalive/codex-quota/releases) 下载对应包：

- `*-universal.dmg / .zip`：Apple Silicon + Intel 都能用
- `*-arm64.dmg / .zip`：仅 Apple Silicon，体积更小

由于使用 ad-hoc 签名（未公证），首次打开如被拦截：右键 `.app` → 打开，或在「系统设置 → 隐私与安全性」点「仍要打开」。

## 自己构建

```sh
./bundle.sh         # 本地开发用，输出 ./CodexQuota.app
./release.sh 0.1.0  # 打包发布，输出 dist/ 下 4 个分发包
```

依赖：macOS 13+，Command Line Tools（自带 Swift）。

## 功能

- 浮窗悬浮在所有窗口之上，可拖动，位置会记忆。
- 左上角红/黄按钮：关闭浮窗 / 最小化到 Dock。
- 右上角刷新按钮（带旋转动画）+ 折叠按钮（折叠后变一行，仅显示百分比）。
- 鼠标离开后自动变透明（透明度和延时可在「偏好设置」中调）。
- 菜单栏图标显示更紧的那条额度的剩余百分比；左键唤回浮窗，右键打开菜单。

## 限制

数据只在你跑 Codex 时更新；长时间不用 Codex 时显示的是上次快照（重置时间会自然倒数到点后归零）。
