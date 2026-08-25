# PasteHub

macOS 上的 Win+V：全局热键弹出不抢焦点的浮层，选中一条后粘贴回刚才那个 App。

MVP 做文本（含 RTF/HTML 原样还原）和图片，不做云同步、片段库。

## 体验

- 菜单栏常驻，不进 Dock
- 默认热键 `⌃V`（Control+V，设置里可改）
- 浮层是 `NSPanel` `.nonactivatingPanel`，前台 App 尽量不丢
- 回车：写回系统剪贴板并模拟 `⌘V`
- `⇧↩` 纯文本粘贴，`⌘P` 固定，`⌫` 删除，`Esc` 关闭
- 纯本地 SQLite，数据库文件权限 `0600`

## 构建

需要完整 Xcode（不只是 Command Line Tools）。

```bash
make test
make run
```

产物在 `dist/PasteHub.app`。建议拷到 `/Applications` 再日常使用，否则辅助功能和开机启动会随构建路径变化。

设置里可以改热键、开机启动、历史上限、隐私过滤，并从 [GitHub Releases](https://github.com/caork/PasteHub/releases) 检查更新。发布：

```bash
# 先改 AppSupport/Info.plist 里的版本号并提交
zsh Scripts/release.sh
```

Release 资源必须叫 `PasteHub.app.zip`，应用才会识别。

首次粘贴需要在 **系统设置 → 隐私与安全 → 辅助功能** 里勾选 PasteHub。没有这个权限时，选中条目只会进入剪贴板，还得自己再按一次 `⌘V`。

## 架构

```
ClipboardWatcher  →  ClipStore (GRDB/SQLite)
HotKey / StatusItem → Overlay NSPanel (SwiftUI list)
                    → PasteEngine (self-write + Cmd+V)
```

交互按方案 A。图片存 PNG + 缩略图，列表只读缩略图；超过 10MB 的图跳过。
