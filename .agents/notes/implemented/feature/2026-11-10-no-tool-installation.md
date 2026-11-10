# Agent Note: 工具安装从包里移出，Windows 侧只做发现与报告

Status: implemented

## Problem

Windows 侧的 bootstrap 是**安装器**：`bootstrap-reverse.ps1` 按 `bootstrap-manifest.json` 的
`installDir` 把 jadx、apktool、radare2、ghidra、SecLists、ProxyCat、bkcrack 等工具下载/克隆到
`%USERPROFILE%\Tools\...`，`ToolDiscovery.ps1` 的发现目录里也硬编码了一整批
`%USERPROFILE%\Tools\*` 与 `%USERPROFILE%\Desktop\IDA Pro...` 探测点，`lib\BootstrapSupplyChain.ps1`
负责把这些安装钉版本、跑 pnpm/pip、把 token 写进用户数据目录。

这在一个**不允许写用户目录**的机器上直接不可用：跑一次 bootstrap 就是往 `%USERPROFILE%` 落文件；
连回归测试 `test-bootstrap-supply-chain.ps1` 都要在 `%USERPROFILE%\Tools\SecLists` 里
临时建一个假仓库来验证供应链校验会拒绝它。工具装在哪、装不装，本来也是**操作者**的决定，
包不该替他做。

## Decision

PowerShell 侧现在是**只发现、只报告**，不安装任何东西，也不写用户目录：

- `bootstrap-reverse.ps1` 对每个 capability 输出一条 JSON：`ready` /
  `configured-not-ready` / `manual-required` / `missing-definition` / `failed`。
  缺工具时给 `hint` 与 `docs_url`，正文明确「装工具是操作者的事」。
  它不再下载、解压、`pip install`、`npm install -g`、`go install`、`git clone`、
  不再改 `PATH`、不再写 MCP token。
- `bootstrap-manifest.json` 不再有 `installDir`，所有 capability 一律 `canAutoInstall: false`；
  安装用的 pin/哈希仍留在文件里作为来源凭证，但没有任何代码路径消费它们去执行安装。
- `ToolDiscovery.ps1` 的发现目录只剩两类来源：`PATH`（`Get-Command`）与操作系统给出的事实位置
  （`%LOCALAPPDATA%`/`%APPDATA%` 下的 SDK、Python 脚本目录）。`%USERPROFILE%\Tools` 与
  `%USERPROFILE%\Desktop` 的探测点全部删除，`Resolve-ReversePathTemplate` 不再展开 `%USERPROFILE%`。
- `lib\BootstrapSupplyChain.ps1` 与 `test-bootstrap-supply-chain.ps1` 删除；
  新增 `test-bootstrap-detect-only.ps1` 守住新契约：脚本里不得出现
  `Invoke-WebRequest`/`Expand-Archive`/`%USERPROFILE%`/`$env:USERPROFILE`
  与包管理器安装调用；把 `USERPROFILE` 等变量重定向到临时家目录后跑一次 bootstrap，
  断言它什么都没创建、也没有建出 `Tools`。
- `skills/browser-automation/scripts/setup.ps1` 同样从安装器改成就绪检查：缺 node/npm/
  agent-browser/Playwright 浏览器时输出 `status=manual-required` 与非零退出，并给出安装指引。
- `-StartServices` 仍然接受但被忽略（打印弃用警告）；**`-McpHostTarget` 不变**——它是显式 opt-in 的
  客户端 MCP 配置注册，默认 `None` 不写任何客户端配置，`test-client-neutral-bootstrap.ps1` 继续守这条。

`must`：**安装行为不从包里出现。** 需要某个工具时，答案是「告诉操作者装什么」，不是「替他装」。

`must`：**改过的 vendored 文件从镜像里排除，而不是同步后再打补丁。**
`tools/sync-upstream.mjs` 新增 `LOCALLY_MAINTAINED_PATHS`（22 个路径：13 个脚本/清单 +
`smoke.ps1` + 8 个说明这份契约的文档）：它们不参与镜像、同步也不会把它们当成「上游已删除」而删掉；
`tools/upstream-files.json` 里对应的摘要条目已移除，`upstream.json` 的 `vendoredFiles`
从 592 变为 570，其余文件仍是逐字节镜像。

## Alternatives considered

- **保留安装，只把根目录换成 `REVERSE_SKILL_TOOLS_DIR` 之类的环境变量** —— 改动最小，
  也和 bash 侧已有的 `REVERSE_SKILL_TOOLS_DIR` 对称。否掉因为**它还是安装器**：
  默认值一旦缺失就要再发明一个默认目录，而「操作者自己装」本来就不需要包知道装在哪。
- **只删写入路径，保留 `%USERPROFILE%\Tools` 的只读探测** —— 兼容已按旧方式装好的机器。否掉因为
  **发现结果不再可信**：包已经不往那里装东西了，继续扫那里等于把「上一次安装的残留」当成本包的约定。
- **就地改 vendored 文件，不管同步与摘要校验** —— 最省事。否掉因为**下次同步会覆盖、CI 会红**：
  夜间 workflow 会把 12 个文件改回上游版本，`pnpm run verify` 也会报摘要漂移，等于这次修复活不过一天。
- **同步时先镜像再由本包覆盖（copy-then-patch）** —— 能保留漂移检测。否掉因为
  **两个来源写同一个文件**：哪一份赢、覆盖何时生效都要靠约定维持，最容易出现的失败是
  「上游改了、本包盖回去，没人发现」。排除法只有一条规则：这些文件不由上游提供。

## Consequences

- **收益**：Windows 上的 bootstrap 与技能脚本**不再产生任何用户目录写入**，可以在锁死的机器上跑；
  `test-bootstrap-detect-only.ps1` 把这条约束变成可执行断言，退化会被立刻抓住。
- **收益**：工具归属变清楚——包只报告缺失与出处，操作者对装什么、装哪里负责。
- **代价与已知上限**：失去自动安装的便利。以前一条命令补齐工具链，现在要按 `hint`/`docs_url` 手工装。
- **代价与已知上限**：`LOCALLY_MAINTAINED_PATHS` 里的 22 个文件**不再自动跟随上游**，
  上游改了它们也不会进本包；同时这些路径的摘要漂移检测没有了。
  上游若声明修复了其中某个问题，必须手工比对并决定是否合并 —— 这是排除法的固有代价。
- **代价与已知上限**：`canAutoInstall` 与 `installDir` 是 **Windows 与 Linux/macOS/Kali 共用**的一份清单。
  这里把整份清单改成 `canAutoInstall: false` 并移除 `installDir`，只对 Windows 成立；
  `skills/scripts/bootstrap-reverse.sh` 仍按 `$TOOLS_ROOT` 安装（它不读这两个字段，
  但 `refresh-tool-index.sh` 会读 `canAutoInstall` 并在 Linux 索引里显示 ✗）。
- **代价与已知上限**：`-StartServices` 变成静默无效（有警告）。依赖它拉起 anything-analyzer /
  idapro 服务的用法要改成操作者自己启动；`configured-not-ready` 会如实报告端口没人听。
- **代价与已知上限**：MCP 客户端配置仍然会被 `-McpHostTarget` 写进 `~/.claude` / `~/.codex` ——
  这是显式 opt-in 的另一件事，不在本次「不写用户目录」的范围内，重访信号是它被改成默认开启。

## Verification

- `node tools/verify.mjs` —— 88 个技能、0 failure；被移除摘要的 12 个路径不再参与校验。
- `powershell -File skills/scripts/test-bootstrap-detect-only.ps1` —— 五项断言全过：
  无安装原语、无 `installDir`、全部 `canAutoInstall=false`、缺工具报 `manual-required` 且退出 0、
  重定向后的家目录里只出现 PowerShell 自己的 `AppData`。
- `powershell -File skills/scripts/verify-routing-coherence.ps1` —— 全部通过（含
  skills/kali 清单能力名对齐、供应链接 pin 门禁）。
- `powershell -File skills/scripts/test-client-neutral-bootstrap.ps1` —— 通过：默认不写客户端配置，
  显式 `-McpHostTarget` 才写，且只写被选中的那个。
- `powershell -File skills/scripts/test-bootstrap-codex-encoding.ps1` —— 通过：
  重写后保留下来的 TOML/UTF-8 三条函数行为不变。
- `grep` 层面：`skills/**/*.ps1` 中不再出现 `%USERPROFILE%`、`$env:USERPROFILE`、
  `Invoke-WebRequest`、`Expand-Archive` 与包管理器安装调用（`test-*.ps1` 自身除外）。
