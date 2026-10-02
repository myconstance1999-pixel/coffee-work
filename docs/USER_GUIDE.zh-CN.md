# Coffee Work 1.5 用户手册（简体中文）

> 适用于 **Coffee Work 1.5 源码预览版**。本手册面向使用者，解释 Coffee Work
> 会做什么、不会做什么，以及 Codex 停止、Mac 睡眠、锁屏、断电等情况下会发生
> 什么。构建、安装与钩子（hooks）配置步骤请见 [README.md](../README.md)
> （英文），本手册不重复那些命令。

## 目录

1. [一句话回答](#1-一句话回答coffee-会不会影响-codex-或强制-mac-睡眠)
2. [先分清四个概念](#2-先分清四个概念)
3. [自动保持：什么时候才会生效](#3-自动保持什么时候才会生效)
4. [手动定时器：独立的显式请求](#4-手动定时器独立的显式请求)
5. [120 秒宽限期与“释放”的含义](#5-120-秒宽限期与释放的含义)
6. [菜单与 Details 说明文字](#6-菜单与-details-说明文字)
7. [快速上手](#7-快速上手)
8. [场景总表](#8-场景总表)
9. [时间线](#9-时间线)
10. [排错](#10-排错)
11. [验证状态、覆盖范围与限制](#11-验证状态覆盖范围与限制)
12. [证据锚点（可选）](#12-证据锚点可选)
13. [可选：实现与隐私细节](#13-可选实现与隐私细节)

## 1. 一句话回答：Coffee 会不会影响 Codex 或强制 Mac 睡眠？

先回答最常被问的那个问题：**Coffee 不会主动关闭或取消 Codex**。它不接管 Codex，
也没有“结束任务”这个动作。

但要如实说明边界：

- **释放保持后，macOS 可能按你的节能设置进入睡眠。** 睡眠可能**暂停或干扰本机的
  任务执行和网络连接**；之后能否恢复、恢复成什么样，取决于 Codex 和 macOS 自身，
  Coffee **不做保证**。Coffee 只是不主动对 Codex 采取动作，并不代表释放保持后本地
  任务一定不受间接影响。
- **Coffee 不控制远程/云端任务。** 它只观察本机受支持的桌面版 Codex 活动
  （见第 3 节）；独立 CLI、headless 或云端任务不在其控制范围内。

具体到 Coffee Work 自己，它**不会**：

- 关机、重启或强制 Mac 进入睡眠；
- 取消、重启、暂停或继续 Codex 的任务，也不会批准、拒绝或阻断任何工具调用；
- 锁定、解锁、唤醒你的 Mac，也不会阻止你主动睡眠；
- 阻止屏幕关闭或变暗，也不会阻止合盖睡眠。

它**只**在你符合条件时，启动一个仅请求“阻止系统空闲睡眠”的 `caffeinate` 进程。

> 实现与隐私细节（接收器的退出码、读取哪些字段）见第 13 节，不影响上面的结论。

## 2. 先分清四个概念

| 概念 | 含义 | Coffee 的行为 |
| --- | --- | --- |
| 屏幕关闭 / 变暗 | 显示器休眠，屏幕变黑 | **屏幕黑本身不算锁定**：会话仍是“活动且未锁定”，保持继续。但 macOS 可能按你的“需要密码”等设置在显示器睡眠时或之后**自动锁屏**；一旦真的锁定，按下面的“锁定”一行处理。 |
| 锁定（锁屏） | 登录会话还在，但屏幕已锁定 | 立即释放保持（没有宽限），并记住“已锁定”；解锁后才可能恢复。 |
| 系统空闲睡眠 | Mac 因一段时间无输入而自动睡眠 | Coffee 唯一要阻止的事情。 |
| 关机 / 重启 / 强制睡眠 | 关机、重启、合盖、低电量强制睡眠、Apple 菜单 >“睡眠” | **不阻止**，也无法把 Mac 唤醒。 |

关键区别：Coffee 的 `caffeinate` 只带 `-i`（阻止系统空闲睡眠），从不带 `-d`
（显示器）。所以**“屏幕黑了”本身不等于“锁屏了”**，Coffee 不会因为屏幕变黑就
释放保持；但如果你的 macOS 设置在显示器睡眠时/之后自动锁屏，锁屏一旦真的发生，
Coffee 仍会立即释放。想确认当前状态，以 Details 里的 `Auto: paused — screen locked`
与 `session inactive` 文案为准。
来源：[`toggle.zsh`](../toggle.zsh) 与 [`MenuBar.swift`](../MenuBar.swift) 中的
`ActivitySnapshot`/`AwakeGate` 逻辑。

（从 v1.4 升级时，遗留的 `-d -i` 记录仍会被识别并且可以停止；但 v1.5 新发起的
请求一律只用 `-i`。）

## 3. 自动保持：什么时候才会生效？

自动保持（菜单中的 `Auto awake for Codex`）只有在**四个条件同时满足**时才会持有：

1. `Auto awake for Codex` 开关处于打开状态；
2. 电源是外接电源（AC）——**充电状态被忽略，充满或暂停充电仍算外接电源**；
3. 当前控制台（console）会话是活动的、已过登录且未锁定；
4. 至少有一个已知的 **Codex 桌面版**任务回合处于 `working` 状态。

任何一条不满足，自动保持都不能新持有。其中：

- 电池供电、电源未知或读不到 → 立即释放（没有宽限）；
- 锁定、睡眠、会话非活动、会话状态未知 → 立即释放（没有宽限）；
- **只是打开了 Coffee 或 Codex，但没有正在工作的回合 → 不算工作**，不会保持
  （如果之前在工作，则进入 120 秒宽限，见下一节）。

**为什么“只打开 App 不算工作”**：活动快照只由 Codex 桌面版的钩子事件写入。
`UserPromptSubmit` 才会开启一个回合；`PreToolUse`/`PostToolUse` 只刷新已有回合，
绝不会凭空创建；`PermissionRequest` 把回合标为 `waiting`（等待审批，不是
working）；`Stop`/`Interrupt` 关闭恰好一个回合；`SessionEnd` 清理一个会话。未知
或格式错误的事件被忽略。

**接收器是桌面版专用**，只承认以下精确路径：

- `/Applications/ChatGPT.app/Contents/Resources/codex`
- `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`
- `/Applications/Codex.app/Contents/Resources/codex`
- `/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`

独立的、headless 的、或由终端/其它进程托管（即使外层祖先恰好是桌面版）的 CLI
`codex` 一律不算。独立 CLI，或没有这些本机桌面钩子事件的远程任务，不会触发
自动保持；Coffee 不检查云端后台的真实进度。手动定时器仍可单独使用。

## 4. 手动定时器：独立的显式请求

菜单 `Keep awake for` 提供 `1 hour` / `4 hours` / `8 hours` / `Custom hours…`
（1–24 整小时，默认 8）。手动定时器：

- **忽略电源**：在电池上也照常请求阻止空闲睡眠；
- 仍然遵守会话条件：锁定、睡眠、非活动或未知时会**挂起**，会话恢复为活动且解锁
  后自动**继续**；
- 挂起**不延长**截止时间：helper 保存原始的绝对截止时间（`Expires:` epoch）和
  剩余秒数，恢复时只用剩余时间；
- 如果在挂起期间到达截止时间，定时器被释放（OFF），**不会复活**；
- `Stop timer` 或退出 App 会取消它。

“挂起/恢复”的会话判断由 Coffee 的 App 完成：App 在会话不合适时调用 helper 的
`suspend`，在会话恢复后调用 `resume`。helper 本身只管理定时器和 `caffeinate`
进程，不读取电源或会话状态——这正是“手动定时器在电池上也能用”的原因。

自动保持与手动定时器是**两个互相独立的保持来源**，可以同时存在。菜单栏杯子图标
填满（`cup.and.saucer.fill`）表示“至少有一个来源在保持”。

## 5. 120 秒宽限期与“释放”的含义

当最后一个正在工作的回合停止（完成、`Stop`、`Interrupt`，或只剩“等待审批”）时，
如果 Coffee 此前正在自动保持，而且插电、未锁定等资格仍满足，它把**自动保持再延续
120 秒**，然后释放。本来没有自动保持时，不会凭空启动宽限；手动定时器不受这段
宽限影响。

- 新的工作会**立即取消**这段宽限；
- 在宽限期间失去资格（电池、电源未知、锁定、睡眠、会话非活动/未知）会**立即
  释放**并清除宽限。

**重要：120 秒不是“再过 120 秒就会睡眠”的时间表。** 它只是 Coffee 在最后一个回合
结束后**继续阻止空闲睡眠的时长**。释放之后，Mac 什么时候睡眠由 macOS 的节能设置、
其它应用持有的保持，以及你当时有没有输入来决定。Coffee 无法、也不会替你安排一个
精确的睡眠时刻。

一个具体例子：任务在 **14:00** 结束，自动保持大约到 **14:02** 释放；这不是“14:02
一定关机或睡眠”，只是 Coffee 从那一刻起不再阻止空闲睡眠。

同理，自动保持内部每 **240 秒**会把 `caffeinate -i -t 300` 换成一个新进程（每个
进程最多 300 秒，并用 `-w <App 进程>` 绑定 App 的生命周期）。这只是让保持进程
在崩溃或异常时仍然有界，**不是**任务在 240 秒后超时，也**不是**任务被结束。

## 6. 菜单与 Details 说明文字

菜单自上而下是五行内容：

1. **状态行**（只读）：`Normal sleep`、`Awake until HH:MM`、
   `Timer paused — until HH:MM`、`Automatic awake`，或
   `Codex Work Mode: status unavailable`。
2. **`Auto awake for Codex`**：勾选开关。这是唯一会被记住的设置（重启 App 后保留）。
3. **手动定时器**：没有手动会话时是 `Keep awake for` 子菜单；有手动会话（包括已
   暂停）时是一个直接的 `Stop timer` 行。
4. **`Details`**（只读子菜单）：
   - `Codex: working` / `Codex: idle` / `Codex: waiting for approval` /
     `Codex: connection not yet seen`
   - `Auto: ...`（见下表）
   - `Power source: Power Adapter / Battery / Unavailable / Loading…`
   - `Energy mode: High Power / Low Power / Automatic / Unavailable / Loading…`
5. **`Stop and Quit`**（有活动手动定时器时）或 **`Quit`**。

`Codex:` 行**能区分** `waiting for approval`（有回合在等待审批）和 `idle`（没有
正在工作的回合）——二者都不算 working。若此前正在自动保持且其它资格仍满足，
就走 120 秒宽限；本来没有自动保持时，不会为它们启动宽限。

`Auto:` 行是“为什么自动保持是现在这样”的直接解释：

| Details 文字 | 含义 |
| --- | --- |
| `Auto: off` | 开关关闭。 |
| `Auto: paused — asleep` | 系统正在睡眠。 |
| `Auto: paused — screen locked` | 屏幕已锁定。 |
| `Auto: paused — session inactive` | 当前会话不是活动的前台会话（例如快速用户切换后）。 |
| `Auto: paused — session unavailable` | 会话状态无法确定（fail closed，宁可暂停）。 |
| `Auto: paused — on battery` | 正在使用电池。 |
| `Auto: paused — power source unavailable` | 电源状态无法确定（fail closed）。 |
| `Auto: holding (120s grace)` | 正在保持，处于最后一个回合结束后的 120 秒宽限内。 |
| `Auto: holding` | 正在保持。 |
| `Auto: not holding — assertion unavailable` | 想保持，但保持进程没能启动或提前退出；会在续期边界重试一次。 |
| `Auto: starting` | 有工作，正在启动保持。 |
| `Auto: ready — no Codex work` | 资格都满足，但没有正在工作的回合。 |

注意：`Power source` 与 `Energy mode` 两行是**只读显示**。系统节能模式（High Power /
Low Power / Automatic）是 macOS 的外部设置，与 Coffee 是否保持清醒是两回事；切换
这些模式本身不会让 Coffee 释放或获得保持，Coffee 只是读取并显示。自动保持的门槛用
的是 IOKit 的电源事件源，而不是这两行，所以它们偶尔显示 `Unavailable` 只表示探测
没读到，不代表 Coffee 改变了任何电源或安全设置。

## 7. 快速上手

已经安装并接好 hooks 的用户直接从第 4 步开始；无需重新构建或重复添加 hooks。

1. 按 [README.md](../README.md) 的 **Build** 从源码构建，并按 **Install (manual)**
   安装 App、helper（`toggle.zsh`）和接收器（`activity-hook.py`）。
2. 用 `./hooks/render-hooks.py` 生成 hooks 模板，把七个 Coffee 条目**追加**到你
   自己的 `~/.codex/hooks.json` 对应事件的数组中（`UserPromptSubmit`、`PreToolUse`、
   `PostToolUse`、`PermissionRequest`、`Stop`、`Interrupt`、`SessionEnd`），不要
   覆盖你已有的条目。模板见 [`hooks/hooks.template.json`](../hooks/hooks.template.json)。
3. 在**你自己的** Codex hooks 界面里启用并信任这七个处理器。信任是你的决定；本
   项目不会绕过信任或降级安全设置。
4. 从 `$HOME/Applications` 启动 App，点击菜单栏的杯子图标。
5. 想手动保持：选 `Keep awake for` → `1 hour` / `4 hours` / `8 hours` /
   `Custom hours…`。
6. 想用自动保持：保持 `Auto awake for Codex` 打开并接上电源，然后在 Codex 桌面版
   里开始一个任务。Details 里的 `Codex:` 变成 `working`、`Auto:` 变成 `holding`
   才算真的生效。

## 8. 场景总表

除异常情况行外，以下行为以 Coffee 正常运行、系统与钩子事件正常送达为前提。
120 秒宽限仅延续已存在的自动保持；不会凭空开启保持，也不改变手动截止时间。

| # | 场景 | 自动保持（Auto awake） | 手动定时器 |
| --- | --- | --- | --- |
| 1 | Codex 正在实际工作 | 资格满足时立即持有；Details 显示 `Auto: holding` | 与自动互不影响 |
| 2 | 一轮结束（完成 / `Stop` / `Interrupt`） | **在没有其它 working 回合时**：120 秒宽限后释放自动保持；新工作立即取消宽限 | 不受影响 |
| 3 | 等待审批（`PermissionRequest`，`waiting`） | **没有其它 working 回合时**，等待审批不算工作（Details 显示 `waiting for approval`）：原有自动保持经过 120 秒宽限后释放。批准还不够：需同时满足 AC + 活动未锁会话，且该回合之后出现新的工具事件才重新持有 | 不受影响 |
| 4 | 多个任务同时进行 | 只要**至少一个**回合在工作就保持；`Stop` 只关闭它自己的那个回合，不会误清新回合 | 不受影响 |
| 5 | Codex 关闭 / 崩溃 | 所有者进程消失 → 记录判为 `idle` → 120 秒宽限后释放 | 不受影响 |
| 6 | 任务卡住 / 网络卡住（回合未关闭、事件停止更新） | Coffee **无法检测“卡住”**：在收到下一个事件前仍按 working 处理。回合打开约 24 小时后会被当作陈旧记录丢弃（这是**近似**的安全上限，不是精确的关机/睡眠/任务超时；见第 9 节） | 不受影响 |
| 7 | 钩子缺失 / 延迟 / 未信任 | 没有快照或没有工作回合 → 不保持（`Codex: connection not yet seen` / `idle`）。**事件丢失会误判**：工作后丢失 `Stop`/`Interrupt` 可能一直显示 working，直到所有者退出或年龄过滤；丢失 `PermissionRequest` 也可能把等待审批误显示成 working。请以 Details 为准，但不保证每个瞬间都与真实任务状态一致 | 不受影响 |
| 8 | 睡眠 / 锁定 / 会话非活动 / 会话未知 | **立即释放**（无宽限）并清除宽限 | **挂起**，保留原截止时间 |
| 9 | 仅屏幕关闭（暗屏） | 若会话仍活动且未锁定 → 保持继续；若 macOS 随后自动锁屏，则按第 8 行立即释放 | 继续（锁定后挂起） |
| 10 | 电池 / 拔出电源 / 电源未知 | **立即释放**（无宽限） | **忽略电源，继续** |
| 11 | 重新接入 AC | 若仍有 working 回合则重新持有；没有工作回合则不持有 | 不变 |
| 12 | 手动定时器在电池上 | 无关 | 照常请求阻止空闲睡眠 |
| 13 | 暂停期间的固定截止时间 | 不适用 | 截止时间不变；到点即释放，不复活 |
| 14 | 自动与手动同时请求 | 两个来源各有一个独立进程，可同时存在 | 同上 |
| 15 | 关闭 `Auto awake for Codex` | 立即释放自动保持；手动不受影响 | 不受影响 |
| 16 | `Stop timer` vs `Quit` / `Stop and Quit` | `Stop timer` 只停手动；退出会释放自动 | `Stop timer` 取消；`Quit`/`Stop and Quit` 退出时也会取消（**包括已暂停的**） |
| 17 | Coffee 正常退出/重开 vs 崩溃/强制退出 | 正常 `Quit` / `Stop and Quit` 会释放自动保持；崩溃时自动进程绑定 App（`-w`），App 消失时释放；如果 App 卡死但未退出，无法续期的当前自动进程最多运行到它原有的 300 秒上限。重开后重新评估**当前**有效工作 | **正常退出会取消手动定时器且不恢复**；崩溃/强制退出时独立 helper（`nohup`）**可能**继续跑到原截止时间。App 不在或卡死时，无法为该 helper 执行锁定/睡眠/用户切换的暂停，helper 只是在跑自己的时钟 |
| 18 | 重启 Mac | Coffee **不会自行安装登录启动项**，App 不会因此自动启动。若你**自己**配置了登录项，则重启后可能随登录启动，并重新评估当前有效工作；重启前的旧定时器/旧进程所拥有的工作不会被复活 | 不会自动恢复；暂停记录按启动标识判定为过期，不会复活 |
| 19 | 合盖 / 低电量 / 主动睡眠 | 不阻止，也无法唤醒 | 不阻止，同样无法阻止这些系统行为 |
| 20 | 独立 CLI / 没有本机桌面事件的远程任务 | 不触发自动保持（见第 3 节）；Coffee 不检查云端后台进度 | 可单独使用 |

自动保持与手动定时器是两个独立来源，除明确说明同时退出两者的情况外，“释放/取消”只作用于对应的保持来源：例如
`Stop timer` 之后自动保持可能仍在；自动宽限到期只看自动一侧，手动定时器不受影响。

## 9. 时间线

**自动保持的一个回合：**

1. **T0 — 你提交提示词。** `UserPromptSubmit` 为该回合写入 `working` 状态。若四个
   资格条件都满足，Coffee 启动 `caffeinate -i -t 300 -w <App 进程>`，Details 变为
   `Auto: holding`。
2. **T0–T1 — 工作中。** 每 240 秒把保持进程换新一次；工具调用前后的
   `PreToolUse`/`PostToolUse` 刷新该回合。事件稀疏**不会**切断一个正在工作的回合。
3. **T2 — 等待审批。** `PermissionRequest` 把回合标为 `waiting`，不再算 working，
   120 秒宽限开始。若你长时间不批准，Coffee 会在宽限结束后释放，Mac 可能睡眠。
   Details 能区分 `waiting for approval` 和 `idle`，区别只在显示；**释放策略相同**
   ——都不是 working，都走 120 秒宽限。批准本身不足以恢复保持：还需资格满足
   （开关开、AC、活动未锁会话）并且该回合之后出现新的工具事件。
4. **T3 — 你批准后工具再次开始。** `PreToolUse` 把回合刷新回 `working`，宽限立即
   取消；资格仍满足时保持恢复。
5. **T4 — 最后一个回合结束。** 完成、`Stop` 或 `Interrupt` 后进入 120 秒宽限，
   然后释放。**此后是否睡眠由 macOS 与其它应用决定**。
6. **T5 — 宽限期间失去资格。** 锁定、睡眠、拔电、电源/会话未知都会立即释放并清除
   宽限。
7. **T6 — 约 24 小时的陈旧记录安全上限。** 一个回合的 `opened` 时间超过约 24 小时
   后会被当作陈旧记录忽略（接收器在下次收到事件时清理，App 在下次读取快照时过滤）。
   这不是精确的 24 小时关机/睡眠/任务超时：App 只在“下一次采样”才发现，而自动保持
   每 240 秒续期一次才重新读取，所以可能比 24 小时再多持续约 240 秒；若此后没有其它
   有效工作，再按正常规则走 120 秒宽限后释放。回合的后续更新（`PreToolUse` /
   `PostToolUse` 等）只刷新 `refreshed`，**不会延长**最初打开的时间戳，所以 Coffee
   不能保证把一个超过 24 小时的回合一直维持下去。

**手动定时器：**

1. 你选择 `4 hours`：helper 启动 `caffeinate -i -t 14400`，并记录绝对 `Expires:`
   截止时间。
2. 锁定 / 睡眠：App 调用 `suspend`，释放进程并把记录标记为 `paused`，保留原截止
   时间与剩余秒数。
3. 解锁 / 唤醒且会话活动：App 调用 `resume`，只用剩余秒数，截止时间不变。
4. 到点（或在挂起中到点）：helper 报 OFF，记录被清除，不复活。
5. `Stop timer` 或退出 App：OFF。

一个具体例子：手动定时器 **13:00–17:00**。14:00 锁屏 → 挂起（释放进程，保留 17:00
截止）；15:00 解锁且会话活动 → 恢复，仍然到 **17:00** 结束，不会延长。

## 10. 排错

先区分两类操作：

- **状态检查**：看 `Details`、读 helper 的 `status`。这不是停止指令，也不改安全/
  电源设置；App 在刷新状态时仍会正常执行自动判断与必要的暂停/恢复。
- **可选的人工动作**（会改变状态，但你自己随时可做）：打开
  `Auto awake for Codex`、开始一个任务、重新接入电源、解锁/唤醒。

helper 的 `status` **不会**启动或停止一个正在运行的保持进程，也**不会**延长截止
时间；但它可能在读取时清理已经过期的暂停记录（例如跨重启的旧记录），所以不要把它
理解成“完全不改任何数据”。

**先看 `Details` 子菜单的 `Codex:` 和 `Auto:` 两行**，它们直接给出原因：

- `Codex: connection not yet seen`：目前没有可读取的活动快照（也可能快照被移除）。
  通常是七个钩子条目尚未安装、
  未启用或未信任，或者当前 Codex 不是受支持的桌面版路径/版本。按
  [README.md](../README.md) “Install (manual)”第 5 步检查；**不要**用绕过信任或
  降低安全设置的方式“修复”。
- `Codex: idle`：有快照，但没有正在工作的回合。开始一个任务；注意“只打开 Codex”
  不算工作。
- `Codex: waiting for approval`：正在等待审批。没有其它工作回合时，原有自动保持在符合条件的 120 秒宽限后释放。
  批准**本身不足以**恢复保持：还需资格满足（开关开、AC、活动未锁会话），并且该回合
  之后出现新的工具事件。
- `Auto: off`：打开 `Auto awake for Codex`。
- `Auto: ready — no Codex work`：资格满足但没有工作回合，等待你开始任务。
- `Auto: paused — on battery`：接上电源。
- `Auto: paused — power source unavailable`：电源读取失败而“安全暂停”。接上电源或
  检查实际供电连接，再观察状态；不需要你修改节能设置。
- `Auto: paused — screen locked` / `asleep` / `session inactive` /
  `session unavailable`：解锁、唤醒，或切回控制台会话。
- `Auto: not holding — assertion unavailable`：保持进程无法启动或提前退出。Coffee
  会在续期边界自行重试一次，不需要你反复点开关。
- `Auto: holding` / `Auto: holding (120s grace)`：正常状态。

**手动定时器排错**：查询 helper 状态不会启动/停止保持进程或延长截止
时间（但可能在读取时清掉已过期的暂停记录）：

```sh
/bin/zsh "$HOME/Library/Application Support/Codex Work Mode/toggle.zsh" status
```

- `ON`：正在保持，并显示 `Automatic stop:` 截止时间。
- `PAUSED`：会话不合适而被挂起，仍显示原截止时间与剩余秒数；解锁且会话活动后会自动
  继续，且**不会**延长时间。
- `OFF`：没有定时器。

如果状态长期停留在 `PAUSED`，通常说明会话没有回到“活动且解锁”的状态，而不是定时器
坏了。如果 `Power source` / `Energy mode` 显示 `Unavailable`，那只是这两个显示行读
不到，它本身不代表自动保持一定失败——请以 `Auto:` 行为准。

## 11. 验证状态、覆盖范围与限制

- **源码预览**：v1.5 是源码预览，需要自行构建；没有 Developer ID 签名、已公证的
  下载；本地构建是 ad-hoc 签名。构建、安装、测试入口见 [README.md](../README.md)
  与 [RELEASE_NOTES.md](../RELEASE_NOTES.md)。
- **已实际观察**：物理证据仅来自当前的开发 Mac（2026-09-30），**锁定、睡眠、锁屏
  状态下唤醒、解锁**这四个转换通过，因此这些转换上的暂停/恢复得到确认。
- **尚未物理验证**：物理拔掉/重新接入电源、菜单打开时的电源变化、合盖行为、快速
  用户切换。
- **fixture 覆盖不等于物理验证**：自动化隔离测试覆盖了自动资格门槛、自动保持状态
  机、活动快照解析、接收器的所有者过滤与隐私、以及 helper 生命周期；它们不能替代
  上一条列出的物理检查。
- **平台覆盖有限**：`arm64-apple-macosx13.0` / macOS 13.0 只是**最低构建目标**，
  不是“已在 macOS 13.0 上物理验证”；实际物理证据仅限当前开发 Mac，不保证在所有
  macOS 版本上行为一致。
- **只观察桌面版 Codex**：接收器只认受支持的已安装桌面版路径；独立 CLI、headless，
  以及没有本机桌面钩子事件的远程任务不触发自动保持；不检查云端后台进度。
- **能力边界**：Coffee 无法检测“任务是否卡住”，无法把 Mac 从睡眠中唤醒，无法阻止
  合盖、低电量强制睡眠或你主动选择的睡眠，也不会强制关机或重启。

## 12. 证据锚点（可选）

想要核对上述细节的读者，可以从这些位置开始：

- 自动资格与 `Auto:` 文案：[`MenuBar.swift`](../MenuBar.swift) 中的 `AwakeGate`
  （`autoEligible`、`autoDetail`）。
- 120 秒宽限、300 秒进程上限、240 秒续期：[`MenuBar.swift`](../MenuBar.swift) 中的
  `AutoAwakeEngine`（`graceSeconds`、`assertionSeconds`、`renewalSeconds`）。
- 约 24 小时的陈旧回合安全上限与快照解析：[`MenuBar.swift`](../MenuBar.swift) 中的
  `ActivitySnapshotParser`（`maximumTurnAge`）；接收器侧为
  [`activity-hook.py`](../activity-hook.py) 中的 `MAX_TURN_AGE_SECONDS` 与
  `reduce_state`（`opened` 不会被后续事件延长）。
- 回合语义（谁开启、谁刷新、`waiting`、`Stop`/`Interrupt`）：[`activity-hook.py`](../activity-hook.py)
  顶部“Turn contract”。
- 手动定时器的挂起/恢复与绝对截止时间：[`toggle.zsh`](../toggle.zsh) 的 `suspend`、
  `resume`、`Expires:` 记录处理。
- 隔离测试：[`tests/auto-awake-main.swift`](../tests/auto-awake-main.swift)、
  [`tests/helper-lifecycle-tests.sh`](../tests/helper-lifecycle-tests.sh)、
  [`tests/activity-hook-tests.py`](../tests/activity-hook-tests.py)。
- 验收与已知缺口：[README.md](../README.md) “Acceptance summary”。

## 13. 可选：实现与隐私细节

本节是给想核对细节的读者看的，不影响第 1 节的结论。

- 接收器 [`activity-hook.py`](../activity-hook.py) 以退出码 `0` 结束，除 `Stop` 事件
  按官方约定输出 `{}` 外不输出内容，因此不可能授予、拒绝、阻断或继续一个 Codex
  回合。
- 接收器会读取并解析 Codex 传入的**整个 JSON 输入**（`json.loads`），但**只使用**
  `hook_event_name`、`session_id`、`turn_id` 三个字段来构建快照，并且只把 session/turn
  的哈希、时间戳与桌面所有者信息写入快照；提示词正文、工具输入输出、cwd、transcript
  路径等字段不会被写入快照，也不保留日志。换句话说，它**会读到**整段输入，但**不会
  把提示词等内容存下来**。
- 自动保持用到的三个常量：宽限 120 秒、单进程上限 300 秒、续期间隔 240 秒，见
  [`MenuBar.swift`](../MenuBar.swift) 中的 `AutoAwakeEngine`。
