# DMG 打包优化与更新逻辑规范

## Purpose

统一 DMG 作为面向用户的唯一分发格式，优化 DMG 安装体验（美观的拖拽安装界面），同时确保自动更新逻辑使用 ZIP 静默完成，用户无感知。解决此前自动更新误下载 DMG 导致更新失败的问题。

## Scope

- `build.sh` 改为 release 构建，明确 Apple Silicon only
- 优化 DMG 安装窗口的视觉布局和交互
- 确保自动更新（app 内）始终走 ZIP 路径，不触碰 DMG
- GitHub Release 同时上传 DMG（手动下载）和 ZIP（自动更新），明确各自用途
- 发布流程加入资产校验步骤

## Non-Goals

- 不做 notarization（Apple 公证）— 项目免费开源，目标用户是开发者，可接受 Gatekeeper 右键绕过
- 不做 Universal Binary（Intel 支持）— 只支持 Apple Silicon
- 不做自动发布 GitHub Release 的 CI/CD pipeline
- 不改动 Updater 的版本检查频率、通知逻辑等现有行为
- 不改动 app 内的更新 UI（`UpdateView.swift`）

## Constraints

- 目标架构：arm64 only（Apple Silicon Mac）
- 构建模式：release（`swift build -c release`）
- 签名：Developer ID Application 证书（已有）
- 分发：GitHub Releases，无 notarization，用户首次打开需右键→打开绕过 Gatekeeper

---

## 1. build.sh 构建修正

### 现状问题

| 问题 | 当前代码 | 影响 |
|------|---------|------|
| debug 构建 | `swift build`（第 8 行） | 产物未优化，体积大，含调试符号 |
| 硬编码 debug 路径 | `.build/arm64-apple-macosx/debug/` （第 14 行） | 如果改 release 构建则路径失效 |

### 改动

```
swift build → swift build -c release
BINARY 路径 → .build/arm64-apple-macosx/release/ClaudeTOC
```

用 `swift build -c release --show-bin-path` 动态获取产物路径更稳健，避免硬编码架构目录。

---

## 2. DMG 安装界面优化

### 现状

`build.sh` 用 `hdiutil create -srcfolder` 生成原始 DMG，打开后是普通 Finder 目录视图，没有背景、没有图标布局、没有视觉引导。

### 目标

打开 DMG 后看到一个精心设计的安装窗口：

```
┌─────────────────────────────────────────────┐
│                                             │
│     ┌─────────┐          ┌─────────┐        │
│     │  App    │   ───>   │ Appli-  │        │
│     │  Icon   │          │ cations │        │
│     └─────────┘          └─────────┘        │
│    TOC for Claude Code     Applications     │
│                                             │
└─────────────────────────────────────────────┘
```

### 实现方式

使用 AppleScript 配合 `hdiutil` 设置 DMG 窗口属性：

1. 创建 read-write DMG
2. Mount DMG
3. 用 AppleScript 设置 Finder 窗口属性：
   - 窗口尺寸：`600 x 400`
   - 图标视图模式，图标大小 `128`
   - App 图标位置：左侧 `(160, 180)`
   - Applications 快捷方式位置：右侧 `(440, 180)`
   - 背景色：白色或浅灰（Finder 默认）
   - 隐藏 toolbar 和 status bar（这两个属性稳定可控）
4. Unmount
5. 转换为 read-only 压缩格式 (UDZO)

### AppleScript 稳定性约束

Finder AppleScript 操作 DMG 窗口布局存在已知不稳定因素，实现时必须遵守：

| 约束 | 原因 |
|------|------|
| mount 后等待 Finder 识别卷（`delay 2` 或轮询） | Finder 异步挂载，立即操作可能找不到窗口 |
| 操作完成后显式 `close` Finder 窗口再 detach | 确保 `.DS_Store` 写入磁盘 |
| detach 前额外 `delay 1` | `.DS_Store` 落盘有延迟 |
| 记录 mount 返回的 device path，detach 时使用 | 避免 detach 错误的卷 |
| 不依赖 sidebar 隐藏 | Finder sidebar visible 属性不稳定，改为设置足够大的窗口让 sidebar 不影响布局即可 |
| 脚本失败时清理临时 DMG | `trap` 清理，避免残留 |

### build.sh DMG 段落改动

替换当前 `# Create DMG` 段落（约第 63-74 行），新逻辑：

```
1. 创建临时目录，放入 .app + Applications symlink
2. hdiutil create -volname ... -srcfolder ... -format UDRW → 创建 read-write DMG
3. DEVICE=$(hdiutil attach -readwrite -noverify ... | grep Apple_HFS | awk '{print $1}')
4. 等待 Finder 识别卷（delay 或轮询 /Volumes/... 存在）
5. osascript 设置窗口布局（图标位置、窗口大小、视图选项）
6. osascript 关闭 Finder 窗口
7. delay 等待 .DS_Store 落盘
8. hdiutil detach "$DEVICE"
9. hdiutil convert -format UDZO → 压缩为 read-only 最终 DMG
10. 删除临时 read-write DMG
```

### Done When

- [ ] 双击 DMG 后 Finder 窗口自动以正确尺寸打开
- [ ] 左侧显示 app 图标（128px），右侧显示 Applications 文件夹图标
- [ ] 拖拽 app 到 Applications 完成安装
- [ ] 无多余文件可见（无 .fseventsd 等）
- [ ] 在 clean macOS 环境下重复执行 `build.sh` 3 次，布局一致

---

## 3. 自动更新逻辑

### 现状分析

| 组件 | 当前行为 | 风险 |
|------|---------|------|
| `Updater.assetName` | 硬编码 `"TOC.for.Claude.Code.app.zip"` | 安全，始终下载 ZIP |
| `performUpdate()` | 下载 ZIP → unzip → 替换 .app → relaunch | 正确路径 |
| GitHub Release | 同时上传 `.dmg` 和 `.zip` | 如果 release 漏传 ZIP 会 404 |

### 结论：自动更新代码路径正确，无需改动逻辑

`Updater.swift` 硬编码了 `assetName = "TOC.for.Claude.Code.app.zip"`，下载链接拼接为：

```
https://github.com/{repo}/releases/download/{tag}/TOC.for.Claude.Code.app.zip
```

始终下载 ZIP，不会触碰 DMG。

### 防护措施

在 `Updater.swift` 的 `assetName` 声明处添加注释说明为什么必须是 ZIP：

```swift
/// Asset name on GitHub Releases for auto-update.
/// MUST be .zip — the update logic uses unzip to extract.
/// DMG is for manual download only; auto-update cannot mount DMG.
private let assetName = "TOC.for.Claude.Code.app.zip"
```

注：注释不能防止发布时漏传 ZIP，发布校验见第 4 节。

### 关于 verifyCodeSignature

当前实现校验签名完整性 + bundle ID 一致性，**不校验签名者身份**（不验证是否为同一个 Developer ID）。这意味着如果攻击者用自己的证书签了一个同 bundle ID 的 app 并替换了 GitHub Release 资产，校验会通过。对于 GitHub Releases 的开源项目，这个风险可接受，暂不改动。

### 不需要改动的部分

- `performUpdate()` 的下载、解压、替换、重启流程
- `prepareInstall()` 的 unzip + script + relaunch 流程
- `verifyCodeSignature()` 的校验逻辑

---

## 4. GitHub Release 产物与发布流程

### 产物策略

| 文件 | 命名 | 用途 | 保留 |
|------|------|------|------|
| DMG | `TOC for Claude Code.dmg` | 用户手动下载安装 | 是 |
| ZIP | `TOC.for.Claude.Code.app.zip` | app 内自动更新 | 是 |

两个都保留。DMG 面向手动下载用户，ZIP 供自动更新消费。

### build.sh 产物

```
build/
├── TOC for Claude Code.app      # 本地开发使用
├── TOC for Claude Code.dmg      # GitHub Release 上传（手动安装）
└── TOC.for.Claude.Code.app.zip  # GitHub Release 上传（自动更新）
```

注：DMG 文件名含空格（`TOC for Claude Code.dmg`），ZIP 文件名用点替代空格（`TOC.for.Claude.Code.app.zip`）。这是因为 `Updater.swift` 已硬编码点分隔的 ZIP 名，不可更改。

### 发布流程（手动）

```bash
# 1. 更新 Info.plist 版本号
# 2. 构建
./build.sh

# 3. 校验产物存在且文件名正确
test -f "build/TOC for Claude Code.dmg" || { echo "ERROR: DMG missing"; exit 1; }
test -f "build/TOC.for.Claude.Code.app.zip" || { echo "ERROR: ZIP missing"; exit 1; }

# 4. 发布
gh release create v{version} \
  "build/TOC for Claude Code.dmg" \
  "build/TOC.for.Claude.Code.app.zip" \
  --title "v{version}" \
  --notes "..."

# 5. 发布后校验：确认 ZIP 资产可下载（自动更新依赖此文件）
gh release view v{version} --json assets -q '.assets[].name' | grep -q "TOC.for.Claude.Code.app.zip" \
  || echo "WARNING: ZIP asset not found in release, auto-update will fail"
```

---

## Assumptions

- [ASSUMPTION: 不需要自定义背景图片，使用 Finder 默认白/浅灰背景 + 图标布局即可]
- [ASSUMPTION: DMG 卷名保持 `"TOC for Claude Code"`，与现有一致]
- [ASSUMPTION: 发布仍为手动执行 `gh release create`，不涉及 CI 自动化]
- Apple Silicon only（arm64），不构建 Universal Binary

---

## 变更清单

| 文件 | 改动 |
|------|------|
| `build.sh` | `swift build` → `swift build -c release`；动态获取 binary 路径；替换 DMG 创建段落为 AppleScript 布局方案 |
| `Updater.swift` | 添加注释说明 `assetName` 必须为 ZIP，无逻辑改动 |
