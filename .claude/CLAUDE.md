<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## 交接班规则

当用户说"交班"、"下班"、"交接"、"handoff" 时，按以下流程执行：

### 1. 提交并推送代码（必须先做）
- `git add -A` 暂存所有改动
- `git commit -m "chore: 下班交接 — <日期>"` 提交（功能改动在交接前自行提交，此处提交的是交接文档和规则变更）
- `git push` 推送到远端
- 所有改动必须纳入版本控制并推送，不允许有未提交的代码留在工作树

### 2. 编写交接文档
- 输出到 `.ai/HANDOFF.md`
- 文档结构：
  - **机器信息**：主机名、分支、最后提交 hash 和 message、工作树状态
  - **今日完成**：勾选列表，每项一句话
  - **文件变更清单**：表格，文件路径 + 变更说明
  - **编译状态**：Mac 端 & 鸿蒙端是否编译通过
  - **工作断点**：正在做什么、卡在哪里、下一步要做什么
  - **关键决策**：今天做的重要技术决策及原因
  - **待清理**：未完成的事项、遗留问题

### 3. 文档位置
- 固定输出到 `.ai/HANDOFF.md`（与 README 同级的隐藏目录）
- 不创建日期后缀的新文件，始终覆盖同一个文件
