# PasteHub 跨设备同步实施计划

> 状态：已实施 · 更新：2026-11-15 · 分支：`claude/cross-device-capability-589dd2`
> 协议规范见 [sync-protocol.md](../sync-protocol.md)，服务端运维见 [Server/README.md](../../Server/README.md)。

## 1. 目标与范围

本计划在 **iPhone 与 Mac 之间**同步 PasteHub 的剪贴板历史：在任一台设备上复制的内容，能在其他设备的历史里找到并粘贴。

**本期范围**

- 平台：macOS（现有 App）与 iOS（新建 App、键盘扩展、分享扩展、快捷指令动作）。
- 内容类型：现有已支持的纯文本、链接、RTF / HTML 富文本、图片。
- 同步动作：新增与再次复制、置顶 / 取消置顶、删除。
- 中继服务：自建，部署在 gomami，地址 `https://paste.hawkingrad.com`。

**明确不做**

- 单条同步载荷超过 **5 MB** 的内容不同步，只保留在复制它的那台设备上。
- 账号体系与设备配对流程。
- Finder 文件复制、Windows / Android / Web 客户端、APNs 推送。
- 网络时延专项测试。

## 2. 决策

| 决策 | 结论 |
|---|---|
| 中继服务器 | gomami（`23.148.204.228`），灰云直连 |
| 支持平台 | iPhone + Mac |
| 大小上限 | 单条同步载荷超过 5 MB 不同步 |
| 接入方式 | **不做账号**。客户端配置「服务器地址 + 同步密钥」后才同步；未配置时完全本地 |
| 准入控制 | 同步密钥由服务端 `keygen` 生成并登记；未登记的密钥一律 401 |
| 远端条目落点 | 默认只进历史；Mac 上可选「自动写入本机剪贴板」 |
| 清空历史 | 只清本机，不同步 |
| Apple 开发者账号 | 真机安装需要在生成工程前设置 `PASTEHUB_TEAM_ID`；付费账号可长期安装，免费账号 7 天失效 |

## 3. 总体架构

```
┌────────── Mac ──────────┐                       ┌──────── iPhone ─────────┐
│ ClipboardWatcher        │                       │ App / 键盘 / 分享扩展 /  │
│   → ClipStore (GRDB)    │                       │ 快捷指令动作             │
│   → syncOutbox          │                       │   → ClipStore (App Group)│
│ SyncEngine ── WebSocket ┼──┐                 ┌──┼── HTTPS 提交 / 拉取      │
└─────────────────────────┘  │                 │  └─────────────────────────┘
                             ▼                 ▼
              paste.hawkingrad.com:443（灰云直连 gomami）
                → nginx stream SNI 分流 → 127.0.0.1:5251（TLS 终止）
                  → pastehub-sync 127.0.0.1:9021（Go 单二进制，systemd）
                      SQLite（space / 操作日志） + 本地 blob 目录
```

核心原则：

1. **端到端加密**。服务器只保存和转发密文。
2. **本地优先**。每台设备保有完整历史；服务器丢失只影响离线补收。
3. **配置才同步**。服务器地址或同步密钥任一为空，客户端不联网、不记录待发变更。

## 4. 安全模型

### 4.1 同步密钥

- 格式：`phs1_` + 32 字节随机数的 base64url（共 48 字符）。
- 在 gomami 上执行 `pastehub-sync keygen -label <名称>` 生成，同时登记一个 space；密钥只打印一次，服务器不保存。
- 所有设备填同一把密钥即属于同一个 space。吊销用 `pastehub-sync revoke <space id>`，该 space 的全部设备随即失效。

### 4.2 密钥派生

用 HKDF-SHA256（salt `PasteHub sync v1`）从密钥派生三把子密钥：

| 用途 | 说明 |
|---|---|
| `auth` | Bearer 令牌。服务器只存其 SHA-256 作为 space ID，拿不到密钥本身 |
| `enc` | ChaCha20-Poly1305 加密操作内容 |
| `mac` | HMAC-SHA256 计算条目主键 `itemKey`，服务器据此去重与清理，但无法反推内容 |

服务器只拿得到 `auth`，因此无法解密任何内容。Go 与 Swift 两端用同一组测试向量保证派生一致。

### 4.3 隐私过滤

`PrivacyFilter` 拦截的内容（密码管理器来源、验证码）不入库，也就不会同步。iPhone 端的所有采集入口同样经过 `PrivacyFilter`。

## 5. 同步协议与语义

协议细节见 [sync-protocol.md](../sync-protocol.md)。要点：

| 项目 | 规则 |
|---|---|
| 顺序与冲突 | 以服务器 `seq` 为准，后到者生效（LWW） |
| 操作类型 | `upsert`（携带完整内容与置顶状态）、`pin`、`delete` |
| 回声抑制 | 本地修改在同一事务内写 `syncOutbox`；应用远端操作不写；拉取时跳过本设备的操作 |
| 大内容 | 单个格式 ≤ 32 KB 内联在密文里；更大的先作为加密 blob 上传，每个 blob 一把随机密钥 |
| 5 MB 上限 | 不含缩略图的各格式合计超过 5 MB 时不上传，标记 `tooLarge`，历史里显示「未同步」 |
| 历史上限淘汰 | 只在本地生效 |
| 首次接入 | 第一次使用某把密钥时，把本机现有历史全部排入待发队列 |
| 离线 | 待发队列持久化，联网后补发；拉取从本地游标继续，游标落后于清理边界时从 0 重建 |
| 时间 | 远端 `upsert` 不会把本地 `lastUsedAt` 往回拨 |

## 6. 服务端（gomami）

- 代码：`Server/`（Go module，依赖 `modernc.org/sqlite` 与 `github.com/coder/websocket`）。
- 部署：systemd `pastehub-sync.service`（独立用户、只监听回环、内存上限 256 MB）；nginx stream 分流表新增 `paste.hawkingrad.com 127.0.0.1:5251`；证书走 certbot `dns-cloudflare`。未启用 gomami 的 cloudflared，未改动 WireGuard。
- 保留：每小时压缩一次。被新操作覆盖的旧操作立即清理；30 天前的操作清理（当前置顶的条目除外）；无引用的 blob 一小时后删除；每个 space 容量上限 500 MB。
- 备份：不做。

## 7. Mac 客户端

| 模块 | 改动 |
|---|---|
| `ClipStore` | 迁移 `v2-sync`：`clipItem` 增加 `originDeviceName`、`syncState`；新增 `syncOutbox`、`syncMeta` 表；支持 `DatabasePool` 以便 iOS 多进程共享 |
| `PasteHubCore/Sync/` | `SyncKeys`（派生）、`SyncWire`（报文与加解密）、`SyncClient`（HTTP / WebSocket）、`SyncEngine`（提交、拉取、长连接与退避）、`SyncSettings`（配置与 Keychain） |
| `SyncController` | 读取配置；已配置时启动 `SyncEngine.runLive()`，未配置时停用待发队列 |
| 设置 | 新增「远端同步」：服务器地址、同步密钥、设备名称、自动写入剪贴板开关、保存并连接（先校验服务器认可该密钥）、立即同步、关闭同步、状态与待上传数 |
| 历史面板 | 显示来源设备；超限条目显示「未同步」图标 |

## 8. iPhone 客户端

`iOS/project.yml`（XcodeGen）生成三个 target，通过 App Group `group.com.kaitaocao.PasteHub` 共享数据库、配置与 Keychain：

| Target | 作用 |
|---|---|
| `PasteHubPhone`（产物 PasteHub.app） | 历史列表、搜索、点按复制、左右滑固定 / 删除、下拉同步；系统「粘贴」按钮保存当前剪贴板（不触发系统询问）；可选「回到 App 时读取剪贴板」；设置页；快捷指令动作「发送剪贴板 / 文本 / 图片到 PasteHub」 |
| `PasteHubKeyboard` | 在任意 App 里浏览最近 40 条并插入；图片写入剪贴板后由用户粘贴；需要「允许完全访问」 |
| `PasteHubShare` | 分享菜单接收文本、链接、图片，保存后立即同步 |

iPhone 不保持长连接，在 App 回到前台、键盘弹出、快捷指令或分享扩展运行时执行一次「提交 + 拉取」。Mac 保持 WebSocket，实时接收。

## 9. 验证记录

| 项目 | 结果 |
|---|---|
| Go 服务端测试（`go test -race`） | 8 项通过：鉴权、幂等、顺序、校验、blob 与配额、压缩与重建、WebSocket 通知 |
| Swift 单元测试（`swift test`） | 37 项通过，含 Go / Swift 密钥派生同一向量、加解密与篡改检测、待发队列与回声抑制 |
| 端到端（本地中继与 gomami 线上各一次） | 两台模拟设备：文本 + 置顶、200 KB 图片走 blob、6 MB 图片保持本地、反向删除与新增、未登记密钥被拒，全部通过 |
| iOS 模拟器（iPhone 17 Pro，iOS 26.5） | App 从 gomami 拉到 Mac 端内容，置顶与来源设备显示正确 |
| gomami 邻近服务 | 改动后 `pan`、`sub2api` 返回 200，sing-box 运行正常 |

尚未做的验证：Mac 新版本未安装到 `/Applications` 进行界面实测；iPhone 键盘、分享扩展、快捷指令与「粘贴」按钮未在模拟器里逐一点按；尚未在真机上安装。

## 10. 使用步骤

1. 在 gomami 上生成密钥（已为 kevin 生成一把，存在本机 Keychain，服务 `pastehub-sync-key`）：
   `security find-generic-password -s pastehub-sync-key -a paste.hawkingrad.com -w`
2. Mac：`make build CONFIG=release` 安装新版本，打开设置 →「远端同步」，填 `https://paste.hawkingrad.com` 与密钥，点「保存并连接」。
3. iPhone：`cd iOS && PASTEHUB_TEAM_ID=<团队 ID> xcodegen`，用 Xcode 打开 `PasteHub-iOS.xcodeproj` 装到真机；在 App 设置里填同样的地址与密钥；按需添加 PasteHub 键盘并允许完全访问。
