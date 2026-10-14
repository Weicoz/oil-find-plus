# Oil Find

免费开源的 macOS 原生文件搜索工具（苹果版的 Everything），按 ⇧⌘F 唤起搜索面板。架构与索引不变量见 `docs/ARCHITECTURE.md`。

## 目录

- `Sources/COilFind/`：C 批量目录读取、名称比较与搜索评分。
- `Sources/OilFindCore/`：扫描、索引、查询、实时更新、持久化和应用更新。
- `Sources/OilFindApp/`：AppKit 应用库与 SwiftUI 设置；免费界面文案集中在 `L10n.swift`，中性扩展点为 `ApplicationExtension`。
- `Sources/OilFind/main.swift`：可执行应用的组装入口。
- `Sources/oilfind-cli/`：命令行验证工具。
- `Tests/`：核心引擎、应用界面与脚本测试。
- `Resources/`：应用元数据和图标。
- `scripts/`：构建、打包、安装与卸载。
- `site/`：Next.js App Router 官网、搜索演示、更新日志与静态更新清单。

## 构建与测试

部署目标 macOS 14，面向 Apple 芯片。

```sh
swift build -c release
swift test
python3 Tests/Scripts/test_uninstall.py
python3 Tests/Scripts/test_open_core.py
scripts/build-app.sh
scripts/build-app.sh --debug
scripts/package.sh
```

`Pro/` 是工作区内可选的独立私有仓库，不属于本公开仓库，由 `/Pro/` 忽略规则排除。缺少私有模块时构建免费版；本机存在私有模块时可强制验证免费版：

```sh
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter '<受影响的测试>'
```

官网使用 Node.js 22 与 pnpm：

```sh
cd site
pnpm install --frozen-lockfile
pnpm dev
pnpm test
pnpm build
```

## 上游同步与合并原则

1. **独立演进**：
   - 官方上游（`https://github.com/oil-oil/oil-find.git`）仅作为只读参考源与新功能跟踪源；本仓库（`https://github.com/Weicoz/oil-find-plus.git`）独立演进并已内置开源 Pro 全功能。
   - 应用更新完全对接自建仓库（`updates/latest.json`），不与官方上游服务通信。
2. **合并决策规范（策略优劣对比）**：
   - 跟踪上游变动时通过 `git fetch upstream` 审查其提交；
   - 严禁盲目整体合入官方代码。合并前必须严格对比**自研策略与官方策略**：
     - **能效与稳定性优先**：自研已实现的能效小核后台调度（`qos: .background` + 80ms 动态休眠）、FTS5 批事务控制（防 SQLite 暴增）及防闪屏死循环切断机制，必须坚决保留，不得被官方策略降级覆盖。
     - **全盘内容检索优先**：自研全盘智能降噪与内容检索策略优先于官方有限范围或付费限制逻辑。
     - 仅在确认上游变动不冲突或确有更优算法改进时，方可按最小改动合入。
