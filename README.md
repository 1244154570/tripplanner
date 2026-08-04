# TripPlanner — 重开蓝图

> 2026-08-04 从 demo 仓库重开。旧仓库（demo 主仓 + backend/frontend 子模块）封存不再改动。
> 需求基线：`docs/REQUIREMENTS.md`（v0.5，冻结）
> 实测边界：`docs/api-capability-report.md`（AnySearch / 高德 / DashScope+DeepSeek）
> 数据库：`docs/database-schema.sql`（6 张表，JSONB 版本快照为路书真相）

## 带走的东西（全部在 docs/，已就位）

旧代码一行不带。三份文档是五轮 grilling + 三组 API 实测的全部沉淀，也是新代码的唯一依据。

## 仓库形态

单仓库 monorepo，无子模块：

```text
tripplanner/
├── docs/                  # 需求、实测报告、库结构（已就位）
├── backend/               # Spring Boot 3 + MyBatis-Plus + PostgreSQL 17
│   └── src/main/java/com/tripplanner/
│       ├── auth/          # 注册/登录/JWT（重写，兼容旧前端契约无意义，按新设计来）
│       ├── trip/          # t_trip / t_trip_version：行程头、版本、提案、回滚
│       ├── task/          # t_generation_task：异步队列、状态机、工具⇒阶段映射
│       ├── agent/         # agent 循环：DeepSeek client、工具注册表、轮数上限、降级合成
│       ├── tool/          # 三个外部 client，各带实测出的形状断言：
│       │                  #   AmapClient（status=="1" 业务断言、geocode 只做模糊地址、POI 用 place/text）
│       │                  #   AnySearchClient（tag/params 冒烟断言、IATA 映射、营销号过滤）
│       │                  #   （模型 client 在 agent/ 内，tool_choice=auto、无 tool call 兜底）
│       ├── share/         # t_share_link 只读分享
│       ├── ratelimit/     # t_rate_limit + 应用层并发/全局队列闸门（P0）
│       └── common/        # R/异常/JSONB handler（可参考旧仓思路，代码重写）
├── frontend/              # Vue 3 + Vite + TS（全新脚手架）
│   └── src/
│       ├── views/wizard/  # 结构化向导 + 提交前澄清问题（≤6，可跳过）
│       ├── views/task/    # 生成进度：工具⇒阶段实时映射、失败原因
│       ├── views/trip/    # 路书视图（按天/节点/路线段/预算/待办/风险）、提案对比、版本回滚
│       └── views/auth/    # 登录/注册（重写）
└── docker-compose.yml     # app + PostgreSQL 17 + Redis 7 + Caddy（无 PostGIS/pgvector——新库不需要）
```

## 技术栈（2026-08-04 grilling 定稿，Day 1 按此动工）

| 层 | 选型 | 关键理由 |
| --- | --- | --- |
| 后端 | JDK 21 + Spring Boot 3.3 + 虚拟线程 | agent 循环是长阻塞 HTTP 密集型（模型 3–60s、工具 1–3s），虚拟线程下直接同步写法 |
| ORM | MyBatis-Plus | 沿用熟练度；JSONB 用 TypeHandler |
| 数据库 | PostgreSQL 17 | 6 表结构见 docs/database-schema.sql；无 PostGIS/pgvector |
| 队列/限流 | Redis 7 + Lettuce 裸用（不引 Redisson/Stream） | 队列 LPUSH/BRPOP；限流 INCR+EXPIRE（原子，免竞态）。任务可安全重跑，不需要 Stream 的不丢保证；崩溃恢复 = 启动时扫 t_generation_task 表，queued/running 但不在队列的孤儿任务标失败让用户重试。t_rate_limit 表降为审计对账 |
| 进度推送 | 前端 2s 轮询任务状态接口 | 1–3 分钟任务轮询开销可忽略；断线天然恢复，不做 SSE |
| 前端 | Vue 3 + Vite + TS + Tailwind 自建组件 | 不引组件库：三个核心视图都是沉浸式强视觉页面（用户先前反馈：消费级产品不要后台风） |
| 地图 | 高德 JS API（Web 端 Key 单独申请，与后端 REST Key 分开） | 路书 polyline/节点 marker 原生支持；实测 polyline 已能拿到 |
| PDF | 暂不定型 | 降级序列第一位；第 6 天真要做时再在"浏览器打印渲染 vs Java 模板"里选 |
| 部署 | 单 VPS docker-compose：app + PostgreSQL + Redis + Caddy（自动 HTTPS） | 公开 Alpha 最简可行形态 |

## 核心架构决定（来自 v0.5，不再重议）

1. **agent 循环**：模型 function calling 自主调工具，`tool_choice:"auto"`；快速档≈8 轮 / 深入档≈20 轮；两轮不调工具→降级"程序备上下文+一次合成"（实测可靠路径）。
2. **路书真相 = `t_trip_version.content` JSONB**，与 agent 交稿 schema 同构；提案=未激活版本；回滚=改指针；用户编辑=打补丁写新版本。
3. **程序校验是质量闸门**：结构/日期/时间冲突/可达性/预算求和/引用存在性，校验失败带错误回炉。
4. **所有外部调用不信 HTTP 200**：三组 API 各有实测出的"业务级成功断言"（报告 1.2/2.2/3.3 节）。
5. **限流 P0**：账号并发 1、日生成 5、全局队列 20、IP 日注册 3。

## 实施顺序（REQUIREMENTS 14.1，映射到本仓）

| 天 | 交付 | 验证方式 |
| --- | --- | --- |
| 1 | docker-compose + 新库建表；backend 骨架（启动/健康检查）；task 模块异步骨架挂 Mock 工具 | 提交任务→状态流转→失败可见，curl 全链路 |
| 2 | auth 重写（注册/登录/JWT/限流计数）；AmapClient + AnySearchClient 带断言 | 单测 + 真实 key 冒烟 |
| 3 | agent 循环 + DeepSeek client + 程序校验 + 降级合成 | 黄金场景端到端出路书 |
| 4 | trip/version：提案、确认、回滚；前端脚手架 + 向导 + 进度页 | 手动全流程 |
| 5 | 路书视图 + 编辑写新版本 + 重新规划 | 黄金场景验收项逐条过 |
| 6 | 分享链接 + PDF（或按 14.2 降级）+ 澄清问题 | 验收清单 |
| 7 | 5 组场景验收 + 部署 | REQUIREMENTS 第 11 节 |

## 明日第一件事

Day 1 的异步骨架。不碰模型、不碰外部 API——先让"提交→排队→阶段流转→成功/失败可见"在 Mock 上跑通。
