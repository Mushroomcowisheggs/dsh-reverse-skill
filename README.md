# dsh-reverse-skill

[English](./README.en.md) | **简体中文**

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-topic-2f6feb)](https://github.com/topics/dsh-plugin) [![upstream](https://img.shields.io/badge/upstream-zhaoxuya520%2Freverse--skill-informational)](https://github.com/zhaoxuya520/reverse-skill)

把上游 [`zhaoxuya520/reverse-skill`](https://github.com/zhaoxuya520/reverse-skill) 的完整语料
封装成 [DSH](https://github.com/deepseek-ai) 插件的 **skill provider** —— 88 个技能，覆盖逆向工程、
渗透测试、CTF、恶意代码分析、移动/固件以及安全文档编写。

它取代了已停止维护的 `@dhicoc/dsh-reverse-skill`：原样 vendor 上游内容，并自动跟随上游更新。

## 安装

```bash
dsh plugin --profile <profile> add github:iuuuuuuuu/dsh-reverse-skill
```

pnpm 会把这个 spec 解析成固定到某个 commit 的 codeload tarball；因为 `package.json` 里声明了
`dsh.bundle.patch`，DSH 会自动把它注册成插件。不需要先跑 `pnpm install` —— 仓库安装会自己拉依赖。

验证接线：

```bash
dsh --profile <profile> --dump-config
```

插入的条目是 `reverse-skill-upstream`，指向 `dsh-reverse-skill`。

### 更新

仓库安装被 lockfile 钉在某个 commit 上，所以它**不会自己动**，只有你主动更新才会移动：

```bash
dsh plugin --profile <profile> update dsh-reverse-skill
```

这条命令会按仓库默认分支重新解析 spec 并改写 lockfile 里的 pin。跑完重启 DSH，让新语料被重新扫描。

要让一次更新真正带上新技能，需要先后发生两件事：

1. 夜间 workflow 的 `chore: sync upstream reverse-skill @<commit>` PR 已被合并 —— 仓库里确实有了更新的语料；
2. 你执行了上面的 update 命令。

### 其他安装方式

```bash
# 从本地 checkout 安装 —— link: 让目录保持「活的」，仓库改动与上游同步无需重新打包或重装即可生效
dsh plugin --profile <profile> add link:/absolute/path/to/dsh-reverse-skill
pnpm install   # link: 安装需要该 checkout 自己的依赖

# 从打包好的 tarball 安装
pnpm pack
dsh plugin --profile <profile> add /absolute/path/to/dsh-reverse-skill-<version>.tgz
```

### 替换旧插件

```bash
dsh plugin --profile <profile> remove @dhicoc/dsh-reverse-skill
```

两个插件可以共存：它们注册的 provider 名不同（`reverse-skill` 与 `reverse-skill-upstream`），
不会有冲突。卸掉旧的只是为了不把同一批技能暴露两遍。

## 注册了什么

| | |
|---|---|
| provider 名 | `reverse-skill-upstream` |
| rank | `600`（bundled 层） |
| 扫描根 | `skills/`、`CTF-Sandbox-Orchestrator/` |
| 发现方式 | 递归扫描 `SKILL.md` |

与 DSH 内置的文件系统 provider 不同，本 provider 会下探嵌套目录，因此
`skills/pentest-tools/src-hunter/SKILL.md`、`skills/reverse-engineering/dsl-vm-reverse/SKILL.md`
这类布局也能被发现。同名技能出现在多层时，路径最浅的胜出。

因为 rank 是 `600`，同名技能里项目级/用户级优先 —— 你随时可以在本地覆盖某个 bundled 技能。

## 与上游同步

```bash
pnpm run sync         # 镜像上游、重生成清单、自动 +1 patch 版本
pnpm run sync:check   # 只报告漂移；上游动了就 exit 1
pnpm run verify       # 校验 vendor 树与插件清单
pnpm test             # verify + 跑一遍 provider 契约
```

`tools/sync-upstream.mjs` 会在 `.sync-cache/upstream` 里维护一个浅克隆，镜像各 vendor 目录、
删除上游已删的文件，并记录：

- `upstream.json` —— 上游仓库、commit、commit 日期、上游 `VERSION`
- `tools/upstream-files.json` —— 逐文件 SHA-256，用于检测漂移
- `package.json` → `upstreamCommit`，内容变化时自动 +1 patch 版本

用 `node tools/sync-upstream.mjs --upstream /path/to/reverse-skill` 可以指向已有的本地克隆，
不走网络。

`.github/workflows/sync-upstream.yml` 每晚跑同一个脚本，语料漂移时开 PR；不会自动发布任何东西。

清单记录的是 **git 对象**的摘要（`git cat-file --batch`）而不是工作树字节，因此同一上游 commit
在 Windows 与 Linux 上会算出相同结果 —— 即使本机 `core.autocrlf=true` 把工作树改成了 CRLF。
这是夜间任务不会在无漂移时开出空 PR 的原因。

### 本地自维护的文件（不从上游镜像）

上游的 Windows 脚本会把工具装进 `%USERPROFILE%\Tools`。本包不做这件事：**装工具是操作者的职责**，
本包只发现、只报告。这些文件因此与上游有意分叉，由本仓库自己维护 ——
`tools/sync-upstream.mjs` 的 `LOCALLY_MAINTAINED_PATHS` 把它们排除出镜像，
`tools/upstream-files.json` 也不再记录它们的摘要，所以 `pnpm run verify` 依然对得上：

| 路径 | 为什么归本地 |
|---|---|
| `skills/scripts/bootstrap-reverse.ps1` | 检测并报告 capability；不再下载、安装、改 `PATH` |
| `skills/scripts/bootstrap-manifest.json` | 去掉 `installDir`，全部 `canAutoInstall: false` |
| `skills/scripts/lib/ToolDiscovery.ps1` | 发现只走 `PATH` 与系统事实位置，不探测 `%USERPROFILE%\Tools` |
| `skills/scripts/lib/BootstrapSupplyChain.ps1` | 删除：整个文件只为安装服务 |
| `skills/scripts/test-bootstrap-supply-chain.ps1` | 删除：它需要在 `%USERPROFILE%\Tools` 里造假仓库 |
| `skills/scripts/test-bootstrap-detect-only.ps1` | 新增：把「不安装、不写用户目录」变成可执行断言 |
| `skills/scripts/smoke.ps1` | 把上面那条断言接进 smoke 套件 |
| `skills/apk-reverse/scripts/decode.ps1` · `frida-run.ps1` · `rebuild-sign-install.ps1` | 缺工具时给指引报错，不再自动 bootstrap |
| `skills/browser-automation/scripts/setup.ps1` | 就绪检查；不再 winget/`npm install -g` 装东西 |
| `skills/ida-reverse/scripts/open.ps1` · `start-gui.ps1` · `start.ps1` | 候选目录去掉 `%USERPROFILE%` 探测 |
| `skills/radare2/scripts/recon.ps1` | 探测失败时的提示改成「自行安装」，不再自称自动安装 |
| `skills/SKILL.md` · `skills/CONTRIBUTING.md` · `skills/apk-reverse/SKILL.md` · `skills/browser-automation/SKILL.md` · `skills/ida-reverse/SKILL.md` · `skills/radare2/SKILL.md` · `skills/ops/sandbox-profile.md` · `skills/ops/skill-supply-chain.md` | 文档改成「只探测、由操作者安装」，不再指导自动安装 |

代价写在 `tools/sync-upstream.mjs` 的注释里：**上游改这些文件不会自动进来**，要手工比对。
夜间同步仍会更新其余文件；新的契约记在
[`.agents/notes/implemented/feature/2026-11-10-no-tool-installation.md`](./.agents/notes/implemented/feature/2026-11-10-no-tool-installation.md)。

Linux / macOS / Kali 侧（`bootstrap-reverse.sh`、`kali/scripts/*`）**仍是安装式**：
`REVERSE_SKILL_TOOLS_DIR` 覆盖根目录，默认 `$HOME/tools`。这条路本次没有改。

## 目录结构

```
lib/                        技能 provider（本包唯一新增的代码）
cordis.patch.yml            DSH bundle patch，用于插入插件
upstream.json               当前 vendor 的上游 commit
tools/                      同步与校验脚本
skills/                     上游语料（46 个 SKILL.md + references/、field-journal/ 等）
CTF-Sandbox-Orchestrator/   上游 CTF 语料（42 个 SKILL.md + references/）
docs/ examples/ kali/ scripts/ burp-mcp-full/ reports/   上游附带目录
UPSTREAM-*.md               上游的 README，重命名以免与本文件冲突
```

除 `lib/`、`cordis.patch.yml`、`package.json`、`README.md`、`README.en.md`、`LICENSE` 与 `tools/`
之外，其余都是上游内容，逐字节复制。两棵上游目录保持原来的相对位置，因为技能正文之间用相对路径互相引用
（例如 `skills/ctf-sandbox/SKILL.md` 链接 `../../CTF-Sandbox-Orchestrator/ctf-sandbox-orchestrator/SKILL.md`）。

上游的 `plugins/`（Codex 适配器）没有被 vendor：它的 router 与 `skills/SKILL.md` 重复，而后者内容更全。

## 技能首次运行

上游语料依赖一份生成的工具索引。在装好的包目录里先生成它，再依赖工具路径：

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File skills/scripts/refresh-tool-index.ps1
```

```bash
# Linux / macOS
bash skills/scripts/refresh-tool-index.sh
# Kali
bash kali/scripts/refresh-tool-index.sh
```

`skills/tool-index.md` 有意不提交。上游脚本按当前目录解析工作根，所以从你自己的项目里跑 case，
运行产物（`work/`）不会落进这个包里。

## 环境要求

- Node.js >= 22
- 带 `skills` 服务的 DSH（任意版本 —— 本包不声明任何 `@deepseek-ai/dsh*` peer 依赖，
  因此永远不会被某个具体 DSH 版本卡住）

## 许可

MIT。vendor 的语料版权归 `Copyright (c) 2026 zhaoxuya520`
（见 [UPSTREAM-LICENSE](./UPSTREAM-LICENSE)）；DSH 封装部分归
`Copyright (c) 2026 dsh-reverse-skill contributors`（见 [LICENSE](./LICENSE)）。
