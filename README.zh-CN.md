<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Oil Find Plus：苹果版的 Everything 增强版。按 ⇧⌘F，输入即出结果。">
</p>

<p align="center">
  <a href="https://github.com/Weicoz/oil-find-plus/releases/latest"><b>下载 DMG / ZIP</b></a>
  &nbsp;·&nbsp;
  <a href="./README.md">English</a>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./assets/readme/search-zh-dark.png">
  <img src="./assets/readme/search-zh-light.png" width="100%" alt="Oil Find Plus 的搜索面板：输入 readme，8 条结果按相关度排列，匹配的部分标成蓝色，底栏显示这次搜索用了 0.8 毫秒。">
</picture>
</p>

Oil Find Plus 是 macOS 上的极速文件搜索工具（基于 Oil Find 的增强全开源版本），思路和 Windows 上的 Everything 一样：自己给磁盘上的文件名建一份内存索引，不依赖 Spotlight。按 ⇧⌘F，屏幕正中弹出搜索框，每打一个字，结果就跟着出来；文件新建、改名、删除，索引都会实时更新。

**Plus 增强特性**：
- **集成 Pro 全功能开源**：文档（PDF、Word、RTF、TXT 等）全文搜索与 Apple Vision OCR 图片（PNG、JPG、JPEG、HEIC、WEBP）文字检索全量内置，开箱即用。
- **开放全盘扫描**：全盘任意用户空间与外置卷均可检索内容，智能过滤系统包与开发构建缓存，零垃圾索引。
- **能效核心与休眠调度**：降为后台 QoS 并在 OCR 间隙动态节流，零风扇狂转、不发烫。
- **数据库事务批处理**：杜绝 FTS5 SQLite 频繁刷盘与体积异常膨胀。
- **防闪屏优化**：彻底切断索引写入触发的列表闪烁循环。

## 为什么快

- **文件名放在一块连续的内存里。** 几十万个名称按列存放，搜索时从头到尾扫一遍，不给每个文件单独创建对象。
- **匹配交给 C 和 NEON。** 字符比较用 Apple 芯片的向量指令批量完成。
- **越打越窄。** 每多打一个字，只在上一次的结果里继续找。
- **只更新变化的部分。** 通过 FSEvents 监听文件变化，增量更新索引；应用重启后从上次停下的位置接着补齐。

下面是在一台 Apple M5（24 GB 内存）上，用仓库自带的命令行工具实测的结果，每条查询跑 20 次取中位数：

| 索引范围 | 文件数 | 建索引 | 常驻内存 | `readme` | `wd`（拼音） | `kind:image` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 默认范围 | 85 万 | 3.0 秒 | 45 MB | 0.6 ms | 0.3 ms | 3.9 ms |
| 整盘 | 750 万 | 27.2 秒 | 343 MB | 8.1 ms | 3.4 ms | 3.8 ms |

默认范围不含开发依赖、应用包内部、资源库和系统目录，需要的话可以在设置里打开。只打一个字母时命中的文件最多，也最慢：默认范围约 11 ms，整盘约 58 ms。

## 搜索语法

| 输入 | 意思 |
| --- | --- |
| `wd`、`wendang` | 拼音首字母或全拼，能找到「文档」 |
| `foo bar` | 同时包含 foo 和 bar |
| `foo \| bar` | 包含 foo 或 bar |
| `readme !node_modules` | 包含 readme，排除 node_modules 里的 |
| `*.png` | 通配符，匹配整个名称 |
| `~/Desktop/ png` | 只在桌面下面找 |
| `ext:pdf;docx` | 按扩展名 |
| `kind:image` | 按类型：folder、app、doc、image、video、audio、code、archive |
| `file:`、`folder:` | 只要文件，或只要文件夹 |
| `size:>10mb`、`size:1mb..5mb` | 按大小 |
| `dm:today`、`dm:week`、`dm:2026-10-01` | 按修改时间 |
| `regex:^IMG_\d+` | 正则表达式 |

从终端或编辑器复制来的路径可以直接粘贴：`file://` 链接、带引号或转义的路径、末尾带 `:行:列` 的路径都能识别。在搜索框里按 ⌘/ 可以随时打开语法速查。

## 键盘操作

| 按键 | 作用 |
| --- | --- |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> | 打开搜索，可以在设置里改 |
| <kbd>Return</kbd> | 打开 |
| <kbd>⌘</kbd><kbd>Return</kbd> | 在访达中显示 |
| <kbd>空格</kbd> / <kbd>⌘</kbd><kbd>Y</kbd> | 用 Quick Look 预览（选中结果后按空格） |
| <kbd>⌘</kbd><kbd>C</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> | 拷贝路径、拷贝名称 |
| <kbd>⌘</kbd><kbd>⌫</kbd> | 移到废纸篓 |
| <kbd>Tab</kbd> / <kbd>⌘</kbd><kbd>1</kbd>…<kbd>9</kbd> | 切换类型 |
| <kbd>⌘</kbd><kbd>/</kbd> | 语法速查 |

结果也可以直接拖到别的应用里。

## Oil Find Pro

免费版开源，永久免费。Pro 是在它之上的扩展功能，本仓库已完整开源内置。

| | 免费版 | Pro |
| --- | :---: | :---: |
| 按文件名搜索：拼音、通配符、正则，按类型、大小、时间筛选 | ✓ | ✓ |
| 实时更新、Quick Look 预览、拖放、全键盘操作 | ✓ | ✓ |
| 排除文件夹和文件类型、应用内更新 | ✓ | ✓ |
| 外置磁盘：插上就建立索引，实时更新 | ✓ | ✓ |
| 外置磁盘拔掉后也能搜到 | | ✓ |
| 图片内容：截图、照片里的文字与画面 | | ✓ |
| 文档内容：PDF、Word、PowerPoint、Excel、Pages、Markdown 等 | | ✓ |
| 源码 | 开源，MIT | 开源，MIT |

Pro 和免费版是同一个安装包：

- 本仓库构建的应用直接包含全部功能，无需授权码，也不会过期。
- 图片和文档都在本机处理，不上传。

## 安装

1. 从 [Releases](https://github.com/oil-oil/oil-find/releases/latest) 下载 `Oil-Find.zip`，解压后把 Oil Find 拖进「应用程序」。
2. 第一次打开时，macOS 会拦下来，因为它没有经过 Apple 公证。到「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。
3. 按 ⇧⌘F 开始搜索。
4. 可选：授予「完全磁盘访问权限」后，邮件附件和其他应用的数据也能搜到。不授予也能正常使用。

有新版本时，Oil Find 会提示你，点「更新并重启」就行。自动检查可以在设置里关掉。

安装包里带有 Pro，无需激活即可使用，区别见上面的 [Oil Find Pro](#oil-find-pro)。

卸载时退出 Oil Find，删掉「应用程序」里的 Oil Find 和 `~/Library/Application Support/Oil Find` 即可。

## 从源码构建

需要 macOS 14 和 Swift 5.10 以上（Xcode 15.3 或更新）。

```sh
git clone https://github.com/Weicoz/oil-find-plus.git
cd oil-find-plus
swift test
scripts/build-dmg.sh   # 生成 build/OilFind-Plus-v1.6.2-plus-macOS-arm64.dmg
scripts/install.sh     # 构建并安装到「应用程序」
```

本仓库已完整开源内置 Pro 全功能，无需额外购买或激活。自己构建的应用使用临时签名，首次运行请在「系统设置」->「隐私与安全性」允许运行。

## 隐私

- 只读取文件名、大小和修改时间，不读文件内容。开启图片或文档内容搜索后，只在本地小核后台读取文件提取文字，所有数据和 FTS 索引 100% 保存在本机。
- 索引只保存在本机的 `~/Library/Application Support/Oil Find/`。
- 不上报任何设备或使用数据。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/COilFind` | C 代码：批量读取目录、名称比较、搜索评分 |
| `Sources/OilFindCore` | 扫描、索引、查询、实时更新、持久化、应用更新 |
| `Sources/OilFindApp` | AppKit 应用和设置界面 |
| `Sources/OilFind` | 应用入口 |
| `Sources/oilfind-cli` | 命令行工具，用来测速和排查问题 |
| `Pro/Sources/OilFindPro` | Pro 扩展：全文内容检索（SQLite FTS5）、文档解析与 Vision OCR |
| `scripts` | 打包（`build-app.sh`、`build-dmg.sh`）与安装脚本 |

## 许可证

本仓库的代码基于 [MIT](./LICENSE) 许可证开源。
