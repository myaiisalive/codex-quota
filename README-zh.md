# CodexQuota

macOS 浮窗，显示 Codex（OpenAI ChatGPT Codex CLI）剩余额度——5 小时窗口 + 周窗口。完全本地读取，不联网。

[English →](README.md)

## 工作原理

Codex CLI 每次调用模型后会把限流信息写到本地会话日志里。CodexQuota 监听 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，解析最新的 `rate_limits` 字段后展示。不需要登录、不需要 API Key、不会向 OpenAI 发请求。

这也意味着：**数字只会在你真的跑 Codex 时变化**。空闲时显示的是上次快照，重置倒计时会自然往下走、到点归零。

## 安装

到 [Releases 页面](https://github.com/myaiisalive/codex-quota/releases) 下载一个包：

| 文件 | 适用 |
|---|---|
| `CodexQuota-x.y.z-universal.dmg` / `.zip` | Apple Silicon **和** Intel 都能用 |
| `CodexQuota-x.y.z-arm64.dmg` / `.zip` | 仅 Apple Silicon，体积更小 |

打开 DMG 把 `CodexQuota.app` 拖进 `/Applications`，或者解压 ZIP 后自己挪过去。

> 需要 macOS 13 或更高版本。

### 打不开怎么办（Gatekeeper 拦截）

发布的包用的是 ad-hoc 签名（没有 Apple 开发者证书，也没公证）。首次打开时 macOS 可能弹：*"无法打开 CodexQuota，因为 Apple 无法检查其是否包含恶意软件"*，或 *"已损坏，无法打开"*。

任选一个办法：

1. **在 Finder 里右键 app → 打开**，弹窗里点「打开」。这一步只需要做一次。
2. **系统设置 → 隐私与安全性**，拉到最下面，看到 CodexQuota 的提示后点「仍要打开」。
3. 如果还是不行（特别是浏览器下载之后出现 *"已损坏"* 这种，是因为系统加了 quarantine 标记），打开终端执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/CodexQuota.app
   ```

   然后正常启动。

这是没花 $99/年买 Apple 开发者证书带来的代价。介意的话可以自己构建（见下方「自己构建」），本地构建出来的 app 不会被 quarantine。

## 使用

启动之后：

- **菜单栏**会出现一个图标，旁边写着两条额度里更紧的那条的剩余百分比。
- **浮窗**默认从右上角弹出来，可以拖到任意位置，关掉再开还在原地。
- 浮窗会一直浮在所有窗口之上，跨 Space、跨全屏 app 都能看到。

### 浮窗操作

| 按钮 | 作用 |
|---|---|
| 左上角红色 | 关闭浮窗 |
| 左上角黄色 | 最小化到 Dock（Dock 上会出现图标，点一下回来） |
| 右上角 ↻ | 立即刷新 |
| 右上角 ⤡ | 收起成一行 / 展开还原 |

鼠标离开后浮窗会自动淡掉，鼠标移上去恢复 100%。

### 菜单栏图标

- **左键**——把浮窗叫出来（不会关闭浮窗；想关用红色按钮）。
- **右键**——弹出菜单：*立即刷新*、*偏好设置…*、*退出*。

### 偏好设置

`右键菜单栏图标 → 偏好设置…`（或者设置窗口聚焦时 `⌘,`）：

- **空闲时的透明度**——鼠标离开后浮窗变成多透明（5%–100%）。
- **变透明的延迟**——离开多久后开始淡（1–30 秒）。
- **自动刷新间隔**——多久重新读一次会话文件（5 秒–10 分钟）。除了这个间隔，文件一旦有变化也会立刻刷新，所以这里调长一点也没关系。

## 自己构建

需要 macOS 13+ 和 Command Line Tools（`xcode-select --install`，自带 Swift，不必装完整 Xcode）。

```sh
git clone git@github.com:myaiisalive/codex-quota.git
cd codex-quota

./bundle.sh           # 本地开发用 → ./CodexQuota.app
open CodexQuota.app

./release.sh 0.2.0    # 发布构建 → dist/ 下生成 universal + arm64 各 dmg/zip
```

`release.sh` 会交叉编译两个架构、用 lipo 合成 universal 二进制、给每个 `.app` 做 ad-hoc 签名，最终在 `dist/` 输出 4 个分发包。

## 已知限制

- 额度数据只在你真的调用 Codex 时更新——上游没有可轮询的接口。
- 如果这台机器从来没跑过 Codex，就读不到任何数据，会显示一个友好的「暂无数据」提示，跑一次 Codex 之后就会出现。
- 会话日志里 `rate_limits` 的格式不是 OpenAI 公开契约，如果以后改了，本应用需要相应做小调整。

## 许可证

MIT。
