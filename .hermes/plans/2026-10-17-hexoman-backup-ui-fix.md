# HexoMan 备份页 UI hang 修复

**时间**：2026-10-17
**症状**：点开"备份"页后，整页 UI 不出（菜单栏/标题/新建备份按钮都没），绝大多数操作无反应；窗口控件（隐藏侧栏、关窗）正常。每次必出。
**现状**：main 分支 HEAD = 7415f5f「修主题管理与备份页三个长期挂着的 UI bug」。上一版没修干净。

## 根因分析（3 个嫌疑）

按可能性排序：

1. **`refreshAll` 主线程跑重型 I/O**（最可能）
   - HexoManModel.swift:382-414，`selectSite` / `push` / `pull` / `restore` 后同步跑
   - 包含 `SiteProbe.inspect`、`PostStore.load(site:)`（扫所有文章 front matter）、`PageStore.pagesOnly + 逐文件 load`、`ConfigStore.list`、`GitService.remotes`
   - 切站点或冷启动 init() 时跑，主线程阻塞几百 ms 到几十秒；SwiftUI body 卡在评估中，整个右侧没出来

2. **`BackupManager.collectFiles` 只对当层目录名做剪枝**
   - BackupManager.swift:140-143 只看 `url.lastPathComponent`
   - 漏掉 `themes/landscape/node_modules`、`source/_drafts/.cache` 这类嵌套命中
   - 第一次进 backup 页时 `refreshPlan` 在后台跑这个遍历，可能好几秒；界面应该不会卡死，但首次进入会显示「正在统计…」很久，体感像挂死

3. **`.onChange(of: includeLarge)` 首次进入也触发**
   - BackupView.swift:70
   - 配合 onAppear 那一拍，子线程可能堆两个 plan Task 互相 cancel

## 修复方案（4 改）

最小、确定、不改 API：

1. **`refreshAll` 移到 `Task.detached(priority: .userInitiated)`**
   - 不阻塞主线程
   - 涉及 5 个调用点：selectSite 内 + 3 处手动 refreshAll（push/pull/restore 后）+ init() 末尾恢复站点时

2. **`collectFiles` 按路径 component 命中即剪枝**
   - 在循环里检查 `url.pathComponents` 是否包含任一排除目录
   - 注意：必须用 `skipDescendants()` 而不是 `continue`——已经是这样做了，只要把判定改为「路径任一段命中」

3. **`.onChange(of: includeLarge)` 加一个「是否是第一次回调」的守卫**
   - 用 `@State private var didFirstRefresh = false` 标记
   - 第一次不触发；之后才触发

4. **`loadBackups` 改后台异步**
   - 用 `Task.detached` 跑 `BackupManager.listBackups`，回到 MainActor 写 `@State`
   - 现在数据量小不卡，但形态上保持和 plan 一致

## 不在范围

- 不改 BackupView 的视图结构 / 视觉
- 不改 BackupManager 的 zip/unzip 流程
- 不动 SiteStore / PostStore 等核心扫描逻辑（这些是另一个 P-level 工作）
- 不动 `~/Library/Application Support/HexoMan/Backups/zi7S95Nt` 孤儿文件（是 v0.7.0 重构产物，删它会丢用户的临时数据，要单独确认）

## 验收

- Debug + Release 双编过
- 自检：进 backup 页时 Title「站点备份」+ 「新建备份」按钮可见
- onAppear 的两次 state 变更不卡 UI
- 嵌套 node_modules 在 collectFiles 里被剪枝（手动造个 `themes/foo/node_modules/` 测）

## 改了什么 / 没改什么

改：HexoManModel.swift (refreshAll + selectSite + 3 处手动调用)、BackupManager.swift (collectFiles 剪枝判定)、BackupView.swift (onChange 守卫 + loadBackups 异步)
没改：UI 视觉、其它视图、构建脚本、plist