---
name: coco-review
description: 调本机 coco CLI 做代码评审，把结果作为我的 review 建议反馈。三种模式：findbugs（评 diff）、inspect（全量评既有代码，逐文件）、arch（架构级数据损坏风险审计，直接调 coco 可注入前期发现）。只评审、绝不改代码（一次性 git worktree 隔离，用完即删）。模型优先 GPT-5.5，失败回退 GLM-5.1。触发词：'/coco-review'、"用 coco 评审"、"coco findbugs"、"让 coco 审架构/数据损坏风险"、"coco inspect"。
user-invocable: true
---

# coco-review

把本机已安装的 `coco`（Trae code agent）当成一个外部 code reviewer：用**本 skill 自带的提示词**驱动 coco 跑一遍评审，再由我把发现整理成给你的 review 建议。

> ⚠️ **不调用 coco 自带的 `/findbugs` skill。** 三个模式（findbugs / inspect / arch）全部用 `scripts/coco-review.sh` 里内置的自定义 prompt 驱动 coco，**不**走 coco 的 `/findbugs`。这样评审维度、输出格式、力度都由本 skill 完全控制。

## 三个固定约定

1. **调用本机 coco** —— 通过 `coco -p -y`（headless）运行（评审 prompt 内部要跑 Bash 取 diff / 读文件，必须能无人值守执行）。
2. **模型 GPT-5.5 ⇒ GLM-5.1** —— 优先 `GPT-5.5`，报错或无输出时自动回退 `GLM-5.1`。这层回退由 `scripts/coco-review.sh` 实现，**不要**自己手写 `-c model.name=`。
3. **用本 skill 的自定义 prompt 作为 review 建议** —— 评审结果（来自我们自己的 prompt，而非 coco `/findbugs`）就是给用户的建议来源，我负责转达、归纳、必要时补一句我自己的判断。

## ⛔ 只评审，绝不改代码（硬约束）

这是本 skill 不可违背的红线。脚本用三层防护保证 **coco 不会动你的任何文件**：

1. **隔离 worktree（核心保证）** —— git 仓库会开一个一次性 **git worktree** 到 `/tmp/coco-review-wt/<仓库绝对路径>`，coco 在 worktree 上评审；**评审结束（含失败/中断，由 trap 保证）立即 `git worktree remove` 删除**。即便 coco 通过 Bash 写文件，也只落在 worktree，**你的真实工作区一个字节都不会变**。
   - worktree 只 checkout **已提交**文件，所以脚本会把你的**未提交改动**（tracked diff + untracked 新文件）回放进 worktree —— 否则默认的"工作区变更"评审会看到空 diff。
   - worktree 共享 `.git` 对象库，**自动跳过 `node_modules`/build 产物**，几乎瞬间完成，比整盘复制轻得多。
   - 非 git 目录回退到一次性 `cp -a` 副本（`/tmp/coco-review-src/...`），同样用完即删。
   - 为什么非隔离不可：评审 prompt 依赖 Bash 取 diff / 读文件，而 Bash 能绕过 Edit/Write 工具限制直接写文件（已实测），单靠"禁用写工具"给不了绝对保证。
2. **禁用写工具** —— 同时 `--disallowed-tool` 掉 `Edit/Write/Replace/ApplyPatch/CreateFile/DeleteFile` 等。
3. **prompt 硬约束** —— 每个评审 prompt 末尾都追加 `GUARD_RO`："只读评审、禁止修改任何文件、禁止进入修复阶段、不要询问是否修复"。

**我（Claude）自己也绝不能在本 skill 流程里改代码。** 即便用户说"顺手修一下"，也要先明确这是另一件事、退出本 skill 的"只评审"语义后再单独处理（见下方「修复」）。

---

## 何时用 / 不用

- **用**：用户说"用 coco 评审 / coco findbugs / 让 coco review 一下"，或调用 `/coco-review`。
- **不用**：用户只想让**我自己**做 review（没提 coco）—— 直接评审即可，别绕 coco。

## 怎么做

### 1. 选模式

脚本有三种模式，覆盖"评 diff / 评既有代码 / 评架构"三类需求。`${skill dir}` = 本 SKILL.md 所在目录的绝对路径，所有命令都自带 worktree 隔离 + 模型回退 + 用完即删。

#### 模式 1：`findbugs`（默认）—— 评 **diff**

评审变更行。用本 skill 内置的 diff 评审 prompt 驱动 coco（**不走 coco `/findbugs`**），脚本自己解析下列参数：

| 用户意图 | 命令 |
|---|---|
| 默认（当前仓库工作区变更，deep；含新增未跟踪文件） | `"${skill dir}/scripts/coco-review.sh"` |
| 快速反馈 | `… fast` |
| 复杂重构 / 安全敏感 | `… deep` |
| 不带 lint 级提示 | `… --with-lint=false` |
| 评审某个 MR | `… --mr <url>` |
| 评审某个范围/提交 | `… <git-ref 或 range，如 main..HEAD>` |
| 指定仓库 | `… --repo <abs_path> …` |

> ⚠️ findbugs 只评 **diff**（变更行）。工作区干净 / 想审既有代码 → 用模式 2 或 3。
> ⚠️ `--with-lint` 现在**不再实际跑 linter**（那是 coco `/findbugs` 的能力）——它只控制 prompt 是否允许 coco 附带次要的规范/lint 级问题（标为 P3）。要真 lint 请单独跑工具。
> ⚠️ `--mr` 走只读拉取（`gh pr diff`/`curl`），**不会** `git fetch`，以免写入与真实仓库共享的 `.git`。

#### 模式 2：`inspect <files...>` —— 全量评**既有代码**（无需 diff）

把每个文件当全新内容全量审，**逐文件 loop**。适合"工作区干净但想让 coco 审某几个旧文件的具体 bug"：

```bash
"${skill dir}/scripts/coco-review.sh" --repo <repo> inspect [--mode fast|deep] <file1> <file2> ...
# 例：审 3 个高风险文件
"${skill dir}/scripts/coco-review.sh" --repo <repo> inspect --mode deep \
    internal/commit/protocol.go internal/lock/owner.go internal/recovery/cow.go
```
- 用本 skill 内置的全量评审 prompt 驱动 coco（**不走 coco `/findbugs`**），输出结构化 P0–P3。
- **逐文件**，不做跨组件推理。要跨组件/架构级 → 用模式 3。

#### 模式 3：`arch` —— **架构级 / 数据损坏风险**审计

findbugs/inspect 聚焦单文件或变更行，给不了跨组件推理。`arch` 用 coco（仍模型回退 + 隔离 + 只读），内置一个聚焦**数据损坏风险**的架构审计 prompt（崩溃一致性 / 提交协议 / fencing / CoW·GC·recovery 竞态 / 错误处理），并对照 WAS·Bigtable·Spanner·Kafka·Raft 指出差距：

```bash
"${skill dir}/scripts/coco-review.sh" --repo <repo> arch ["本次重点的自由描述"]
# 把前期发现（如 Explore agent 的结论）作为上下文注入，让 coco 验证/补充/对比：
"${skill dir}/scripts/coco-review.sh" --repo <repo> --context /path/to/findings.md arch "重点看 commit 路径和脑裂"
```
- `--context <file>`：把任意文本（前期发现 / 设计文档）喂给 coco 当上下文。
- 末尾自由文本 = 本次重点，会拼进 prompt。
- **最佳实践**：模式 2 先挖各文件具体 bug → 把结果存文件 → 模式 3 `--context` 注入做架构综合。

### 2. 运行（自带隔离 + 模型回退）

脚本行为：① 开一次性 git worktree（非 git 目录回退到 `cp -a` 副本），并回放未提交改动；② 在隔离树上先用 **GPT-5.5** 跑（findbugs / inspect 逐文件 / arch），失败则回退 **GLM-5.1**；③ stdout = 报告，stderr = 进度 + `model_used=<模型>`（inspect 逐文件标注）；④ **退出时自动删除 worktree/副本**。

- worktree 共享 `.git`、跳过 `node_modules`，开/删都很快；deep+lint 评审本身可能数分钟。运行时给较长 timeout（建议 ≥ 300000ms），别中途打断。
- 真实仓库永不被改；隔离树用完即删（trap 保证失败/中断时也删）。

### 3. 读取结果

现在三个模式都用本 skill 的自定义 prompt（不走 coco `/findbugs`），coco **不会**再生成 `/tmp/code-review/.../issue_comments.jsonl` 那套结构化 JSONL —— 评审结论直接打在 **stdout**（按 prompt 要求的 P0–P3 文本格式）。**一律以 stdout 为准。**

### 4. 反馈为 review 建议

把 coco 的发现整理给用户：按优先级（P0→P3）列出 **文件:行号 + 问题 + 修复建议**；标注来源是 **coco（本 skill 自定义评审 prompt，模型：实际使用的 GPT-5.5 或 GLM-5.1）**；没发现就说"coco 未发现问题"。我对某条有不同看法（误报 / 漏报）可补充，但要和 coco 原始输出区分开。

### 5. 修复（本 skill 之外）

**本 skill 永不改代码。** 用户想修时，这是一件独立的事：明确告知"评审已结束，下面是修复（会改文件）"，征得同意后用我自己的工具在**真实仓库**改，改完可建议再 `/coco-review` 复审。绝不要在评审流程里顺手改。

## 失败处理

- 退出码 `127`：本机没装 coco，提示安装。
- 退出码 `3`：建快照失败（磁盘 / 权限），把 stderr 转达用户。
- 退出码 `1`（两个模型都失败）：转达 stderr 里两个模型的报错。常见原因：网络 / 鉴权（MR 需 `X_CODE_USER_PAT` 等 token）/ 模型名变更（`coco models` 查可用模型）。
- `no uncommitted changes found`：当前无工作区变更，问用户是否评审最近一次提交或指定范围。
