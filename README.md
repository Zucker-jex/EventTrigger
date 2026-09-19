# EventTrigger

Project Zomboid（B42）管理员事件触发器模组 —— 在指定坐标放置触发区域，玩家进入时自动播放消息；并附带一套完整的**交付点（Delivery Point）**系统。

---

## 功能概览

### 触发器（Trigger）

- **区域触发**：在任意方格放置触发器，玩家进入指定半径即触发。
- **多种输出模式**：
  | 模式 | 说明 |
  |------|------|
  | `NAMED` | 具名系统消息（可自定义显示名） |
  | `SAY` | 触发者身份 + 头顶气泡 |
  | `DO` | 环境旁白 |
  | `LOW` | 低语 + 气泡 |
  | `YELL` | 大喊 + 气泡 |
  | `OOC` | 全局 OOC 频道 |
  | `HALO` | 头顶漂浮文字（不进入聊天日志） |
  | `BROADCAST` | 全服广播，可具名 |
- **延迟触发**：可设置 0–3600 秒延迟后再显示消息。
- **次数上限**：单触发器可设最大触发次数（-1 = 无限制）。
- **冷却机制**：支持真实时钟（wall clock）与游戏时钟（game clock），粒度到年 / 月 / 日 / 时 / 分。
- **触发历史**：记录每位玩家的触发时间与身份，最多保留 50 条。
- **启用 / 禁用**：可单独或一键禁用全部触发器。
- **创建者权限**：普通玩家仅能编辑 / 删除自己创建的触发器；管理员可操作全部。

### 交付点（Delivery Point）

- **物品兑换**：玩家进入交付点范围后弹出确认 UI，校验背包物品并发放奖励。
- **双重匹配**：客户端按 `FullType + DisplayName` 严格校验；服务器按 `FullType` 宽松执行（规避翻译差异）。
- **多分支奖励**：同一次消耗，可选多个奖励分支之一。
- **多消耗选项**：同一奖励，可选多个消耗物品之一。
- **批量兑换**：一次最多 N 次（上限 20），实时预览消耗与奖励总量。
- **冷却 / 上限**：支持单玩家上限、全局唯一玩家上限、单人冷却。
- **原子回滚**：奖励发放失败时，自动回滚已扣除的消耗物品。

### 数据与同步

- **服务器权威**：服务器 JSON 文件为唯一数据源，客户端登录 / 刷新时通过 `syncAll` 全量拉取。
- **乐观 UI**：客户端本地先执行操作以获得即时反馈，再由服务器确认。
- **向后兼容**：自动迁移旧版 `ModData` 触发器到 JSON 文件；冷却字段兼容旧版 `cooldownType/cooldownValue`。

### 可选集成

- **MongooseChat**：`SAY / LOW / YELL / DO / OOC` 频道通过 MongooseChat 管线广播；`NAMED` 通过 EventTrigger 服务器广播到系统频道。未安装 MongooseChat 时自动回退到原生 `ISChat` 或 `HALO`。

---

## 依赖

| 依赖             | 用途                            | 是否必需 |
| ---------------- | ------------------------------- | -------- |
| **ElyonLib**     | `Logger` / `JSON` / `FileUtils` | ✅ 必需  |
| **MongooseChat** | 语音频道 / 气泡 / 系统频道      | ⭕ 可选  |

---

## 安装

### 创意工坊订阅（推荐）

1. 打开 Steam 创意工坊页面：
   **[EventTrigger - Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3769432010)**

2. 点击 **「订阅」** 按钮。

3. 启动 Project Zomboid，在 **主菜单 → 模组** 中确认已启用 `EventTrigger`。

4. 确保依赖模组 **ElyonLib** 也已订阅并启用。

> 联机服务器端无需额外配置，服务器会自动加载

### 手动安装（备选）

将 `EventTrigger` 文件夹放入 `Zomboid/mods/` 目录，并在游戏内模组菜单中启用。

---

## 使用指南

### 管理员操作（联机）

1. **右键点击任意世界物体** → 弹出上下文菜单。
2. 选择：
   - `放置触发器 (x,y,z)` — 启动放置向导
   - `设置交付点 (x,y,z)` — 启动交付点向导（需交付模块已加载）
   - `打开管理器` — 打开主管理面板

### 触发器放置向导

依次输入：

1. **延迟**（秒）
2. **范围**（格，最小 0.5）
3. **最大触发次数**（-1 = 无限制）
4. **消息内容**
5. **输出模式**
6. **显示名**（仅 `NAMED` 模式）
7. **冷却**（模式 + 时长）

### 交付点设置向导

依次输入：

1. **提示文本**（HaloText 显示）
2. **半径**
3. **全局玩家上限** / **单人上限**
4. **匹配模式**（`all` = 全部满足 / `any` = 任一满足）
5. **冷却**
6. **奖励分支数量**（1–10）
7. **需求物品**（资格门槛，可勾选 "消耗"）
8. **消耗选项**（可选，多个互斥）
9. **各分支奖励**

### 主管理面板

| 按钮                   | 功能                          |
| ---------------------- | ----------------------------- |
| `Set Delivery Pt`      | 设置交付点                    |
| `Add Trigger`          | 在当前位置添加触发器          |
| `Disable All`          | 一键禁用所有触发器 + 交付点   |
| `Delete All`           | 删除全部（需输入 `YES` 确认） |
| `Refresh`              | 手动刷新列表                  |
| `Show All / Show Mine` | 切换查看全部 / 仅自己的       |

每行提供 **Edit / X / Disable|Enable / R / Hist** 操作按钮。

---

## 目录结构

```
EventTrigger/
├── EventTriggerClient.lua       -- 客户端主逻辑
├── EventTriggerDelivery.lua     -- 交付点系统
├── EventTriggerShared.lua       -- 旧版扁平结构常量（兼容层）
├── EventTriggerPersistence.lua  -- 旧版扁平结构持久化（兼容层）
└── EventTrigger/
    ├── Shared.lua               -- 常量 / 指令 / 数据结构
    ├── Persistence.lua          -- JSON 文件 I/O
    └── Server.lua               -- 服务器端指令处理
```

### 服务器数据目录（存档内）

```
EventTrigger/
├── index.json                 -- 触发器 ID 索引
├── <triggerId>.json           -- 单个触发器数据
├── history/
│   └── <triggerId>.json       -- 触发器触发历史
└── delivery/
    ├── index.json             -- 交付点 ID 索引
    └── <deliveryId>.json      -- 单个交付点数据
```

---

## 指令协议

所有指令通过 `sendClientCommand` / `sendServerCommand` 使用模块名 `"EventTrigger"` 传输。

### 客户端 → 服务器

| 指令                  | 参数                                                             | 说明                |
| --------------------- | ---------------------------------------------------------------- | ------------------- |
| `requestSync`         | `{ all }`                                                        | 请求全量同步        |
| `placeTrigger`        | 触发器字段                                                       | 创建触发器          |
| `deleteTrigger`       | `{ id, index }`                                                  | 删除触发器          |
| `resetTrigger`        | `{ id, index }`                                                  | 重置触发计数        |
| `deleteAllTriggers`   | `{ all }`                                                        | 删除全部 / 仅自己的 |
| `editTriggerMessage`  | `{ id, message }`                                                | 编辑消息            |
| `editTriggerParams`   | `{ id, delay, range, maxTriggers, cooldown }`                    | 编辑参数            |
| `editTriggerOutput`   | `{ id, outputType, outputName }`                                 | 编辑输出            |
| `toggleTrigger`       | `{ id, enabled }`                                                | 启用 / 禁用         |
| `disableAll`          | `{ all }`                                                        | 禁用全部            |
| `recordTrigger`       | `{ id, playerId, timestamp, timeStr }`                           | 记录触发            |
| `placeDeliveryPoint`  | 交付点字段                                                       | 创建交付点          |
| `deleteDeliveryPoint` | `{ id }`                                                         | 删除交付点          |
| `editDelivery`        | 交付点字段                                                       | 编辑交付点          |
| `resetDelivery`       | `{ id }`                                                         | 重置交付点          |
| `toggleDelivery`      | `{ id, enabled }`                                                | 启用 / 禁用         |
| `confirmDelivery`     | `{ id, batchCount, branchId, costOptionIndex, selectedORIndex }` | 确认交付            |

### 服务器 → 客户端

| 指令             | 参数                           | 说明         |
| ---------------- | ------------------------------ | ------------ |
| `syncAll`        | `{ triggers, deliveryPoints }` | 全量状态同步 |
| `namedMessage`   | `{ message, outputName }`      | 具名消息广播 |
| `deliveryResult` | `{ action, message, reason }`  | 交付结果     |

---

## 数据字段

### 触发器

```lua
{
    id          = "et_<timestamp>_<rand>",
    x, y, z     = 0,               -- 坐标
    message     = "Trigger activated!",  -- 消息（≤500 字）
    delay       = 3,               -- 延迟（秒，≥0）
    range       = 2,               -- 范围（格，≥0.5）
    outputType  = 7,               -- 输出模式（1-7）
    outputName  = "",              -- 具名模式显示名（≤100 字）
    maxTriggers = -1,              -- 最大触发次数（-1 = 无限制）
    triggerCount = 0,              -- 已触发次数
    enabled     = true,            -- 启用状态
    cooldown    = { mode = 0, years = 0, months = 0, days = 0, hours = 0, minutes = 0 },
    lastTriggerAt = nil,           -- 上次触发时间戳
    creator     = "unknown",       -- 创建者用户名
    createdAt   = os.time(),       -- 创建时间
}
```

### 交付点

```lua
{
    id            = "dlv_<timestamp>_<rand>",
    type          = "delivery",
    x, y, z       = 0,
    hintText      = "Delivery Point",   -- 提示文本（≤500 字）
    range         = 3,                  -- 半径（格）
    requiredItems = { ... },            -- 资格门槛物品（含 collect 标记）
    rewardItems   = { ... },            -- 旧版奖励（单分支时使用）
    matchMode     = "all",              -- "all" | "any"
    branches      = { ... },            -- 多分支（含 costOptions + rewards）
    maxPlayers    = -1,                 -- 全局唯一玩家上限
    maxPerPlayer  = -1,                 -- 单人上限
    cooldown      = { mode = 0, ... },
    playerDeliveries = { [playerKey] = count },
    playerCooldowns  = { [playerKey] = timestamp },
    triggerCount  = 0,
    triggeredBy   = { { playerId, timestamp, timeStr } },
    enabled       = true,
    creator       = "unknown",
    createdAt     = os.time(),
}
```

---

## 冷却模式

| 常量            | 值  | 说明                                       |
| --------------- | --- | ------------------------------------------ |
| `COOLDOWN_NONE` | 0   | 无冷却                                     |
| `COOLDOWN_WALL` | 1   | 真实时钟（`os.time()` 秒）                 |
| `COOLDOWN_GAME` | 2   | 游戏时钟（`getWorldAgeHours() * 3600` 秒） |

时长换算：`(年 × 365 + 月 × 30 + 日) × 24 小时 + 时 → 分 → 秒`

---

## 依赖常量

| 常量                      | 值  | 说明                 |
| ------------------------- | --- | -------------------- |
| `MAX_TRIGGERS`            | 200 | 触发器数量上限       |
| `MAX_DELIVERY_POINTS`     | 100 | 交付点数量上限       |
| `MAX_HISTORY_PER_TRIGGER` | 50  | 每触发器历史记录上限 |
| `VERSION`                 | 1   | 数据结构版本         |

---

## 权限说明

- **管理员**（`getAccessLevel() == "admin"`）：
  - 可见右键菜单全部选项
  - 可操作所有触发器 / 交付点
  - 可执行 `Delete All`（`all=true`）
  - 可切换 `Show All / Show Mine`
- **普通玩家**（联机）：
  - 无右键菜单入口
  - 通过 UI 仅可查看 / 操作自己创建的条目

---

## 兼容性

- **Project Zomboid**：B42（主路径 `42/media/lua/server/EventTrigger/Server.lua`）
- **联机模式**：服务器 JSON 权威，客户端本地缓存
- **旧数据迁移**：首次加载自动将 `ModData.EventTrigger` 中的触发器迁移到 JSON 文件

---

## 已知限制

- PZ 无文件删除 API，删除操作仅从索引中移除，旧 JSON 文件仍保留在磁盘（标记 `_deleted = true`）。
- 触发历史保留最近 50 条（超出自动裁剪），`recordTrigger` 不实时广播以减少网络开销。
- 交付点分支模型下，`selectedORIndex` 仅在旧版 `any` 模式下生效。
- UI 布局在极小分辨率下会被 `fitW / fitH` 钳制到屏幕 94%。

---

## 调试

客户端 `EventTrigger.DEBUG = true` 时输出 `[EventTrigger-CLIENT]` 日志。

服务器端 `print` 与 `Logger:info` 输出 `[EventTrigger-SERVER]` / `[EventTrigger-IO]` 日志。
