# Agent Note: 任务记录默认落在工作对象，不在 skill 包里

Status: implemented

## Problem

语料在任务完成清单里要求把经验**回写进包内的 `field-journal/`**：
`RULES.md` 的 Completion Checklist 第 3 项、`RULES_zh.md` 第 3/4/6 项，以及 `skills/SKILL.md`
的「自动进化」一节。同样的强制写入还出现在错误处理表（「Write to field-journal」）
和「用户中途切换话题 → 存进度到 field-journal」的规则里。

包目录在安装后是 `node_modules/dsh-reverse-skill/**`，所以这条指令有两个后果：

1. 写进去的内容**下一次 `pnpm update` 就被覆盖**；
2. 所有任务共用同一个目录，**后一个任务会读到前一个任务留下的记录** —— 跨任务污染。

用户的要求是：保存可以有，但默认落在**当前工作对象**下，不要影响别的任务。
不涉及强制写入的部分（总控路由、读先例、查索引）一律不动。

## Decision

只改「强制在工作区外写文件」的那几句，写入目标统一改为当前工作对象：

- `RULES.md` / `RULES_zh.md` 完成清单第 3 项：`field-journal/` → 当前工作对象的 `notes/`
  （默认 `work/<case>/notes/`，仍要求脱敏）。
- 第 4 项「沉淀搜索到的知识」：写入位置改为当前工作对象的 `notes/`；
  「更新 bootstrap-manifest / routing-*.json / MASTER-ROUTING.md」这类包内更新
  加上前置条件 —— **仅当本任务就是维护本仓库时**。
- 第 6 项「更新系统索引」：同样加上「仅当本任务就是维护本仓库时」的前置条件。
- 错误处理表里「Write to field-journal」/「写入 field-journal 踩坑记录」→ 当前工作对象的 `notes/`。
- 多任务中断：「切换话题时存进度」「回来时恢复上下文」的目标从 field-journal 改为该 `notes/` 文件。
- `skills/SKILL.md`「自动进化」：写入位置改为工作对象 `notes/`，并写明包内目录只读。

未改动的部分（刻意保留）：`reverse-skill-router` 仍在技能目录里；`field-journal/precedent-*.md`
的读取指令、`_index.md` 的路由前查询、「Do NOT skip field-journal lookup」全部原样保留；
社区贡献问答也原样保留。

`must`：**强制写入只能落在当前工作对象内。** 包目录只读。
`may`：包内只读材料（`field-journal/precedent-*.md`、`_index.md`）照旧读。

## Alternatives considered

- **删掉整个 field-journal 机制（读 + 写）** —— 最彻底。否掉因为**用户只要求去掉强制写包外**：
  读先例、查索引这些是静态材料，不会把别的任务的状态带进来，删掉属于扩大改动面。
- **把 notes 放到用户级目录（如 `~/.reverse-skill/notes`）** —— 更省事、可跨项目复用。否掉因为
  **那还是跨任务**：用户要的是「这次分析自己的记录」。
- **完全不落任何记录** —— 否定因为用户明确说「如果想保存，默认保存到 …notes 文件夹」，
  也就是保留保存能力，只改位置。

## Consequences

- **收益**：任务结束后的经验、进度、错误记录都落在当前工作对象，后一个任务读不到；
  `pnpm update` 也不会吞掉任何人的笔记。
- **代价与已知上限**：`RULES.md` / `RULES_zh.md` 因此与上游分叉，进入
  `LOCALLY_MAINTAINED_PATHS`（24 个路径），上游改这两份规则不会自动进来，需要手工比对。
- **代价与已知上限**：完成清单里「更新包内索引」类动作现在只在本任务就是维护本仓库时执行；
  如果模型在普通任务里发现了新工具/新场景，它应当汇报给用户，而不是直接改包。
- **代价与已知上限**：`refresh-tool-index` 仍会生成包内的 `skills/tool-index.md`（gitignore 的缓存）。
  它不是任务记录，本次不动；若要求包目录绝对零写入，这个需要单独设计。

## Verification

- `grep` 层面：`RULES.md` / `RULES_zh.md` 里对 `field-journal` 的**写入**指令为 0，
  只剩读取与「维护本仓库时」的索引更新；`skills/SKILL.md` 的「自动进化」指向工作对象 `notes/`。
- `node tools/test-provider.mjs` —— provider 仍暴露 88 个技能（`reverse-skill-router` 未改动）。
- `node tools/verify.mjs` —— 0 failure；`vendoredFiles` 568（`RULES.md` / `RULES_zh.md` 已移出镜像）。
- `powershell -File skills/scripts/verify-doc-facts.ps1` —— 0 failure。
- `powershell -File skills/scripts/verify-routing-coherence.ps1` —— ALL PASSED。
