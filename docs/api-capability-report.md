# 外部 API 实测能力报告

> 目的：记录 REQUIREMENTS.md 引用的外部 API 的**实测**能力边界，作为集成设计依据。
> 结论只写实测过的；未测的明确标"未测"。测试日期：2026-08-04。

## 1. AnySearch（已实测，可用）

`POST https://api.anysearch.com/v1/search`，Bearer key 认证；匿名模式可用（按 IP 限流，本机实测匿名请求成功）。

### 1.1 已验证能力

| 用途 | 调用方式 | 实测结论 |
| --- | --- | --- |
| 体验内容（知乎） | `tag=social_media.social_media` + `params.type=zhihu` | ✅ 真实回答正文，含作者名。"外滩值得去吗"返回本地人视角攻略、预算细节。质量可用 |
| 体验内容（微博） | 同上 `type=weibo` | ✅ 真实帖子，含发布时间/点赞数。⚠️ 混营销号软文（楼盘广告、地陪推广），需按互动数/内容过滤 |
| 事实与攻略 | `tag=general.general` + `zone=cn` | ✅ 知乎/携程/Trip.com 等，清洗后正文 1–4k 字 |
| 机票价格参考 | `tag=travel.flight` + `params:{departure,arrival,date}` | ✅ 传 IATA 码（DYG/SHA）返回航线级价格页，天巡结果含具体价格（如往返 ¥1709/人）。是价格快照参考，非可订报价 |
| 航班动态 | `tag=travel.flight_status` | 必填 departure/arrival/date，未深测 |

体验内容平台边界：知乎、微博、X、Reddit、LinkedIn、微信公众号。**没有小红书、没有 B 站。**

### 1.2 集成陷阱（都实测复现过）

1. **参数错误静默降级**：非法的 `params` 键或值不报错，返回 HTTP 200 + 通用搜索结果。`platform=bogus` 照样返回结果；正确参数名是 `type`。
2. **travel.flight 城市名静默降级**：`departure/arrival` 传中文城市名（"张家界"）不报错，但结果退化为携程/去哪儿**首页链接**，无航线信息。必须传 IATA 码 → 需要自建"城市→机场码"映射（张家界=DYG，上海=SHA/PVG）。
3. 缺必填参数才会报 `code:-1`（如 flight 缺 date）；参数值错误不会。
4. **集成必须做冒烟断言**：用已知查询验证结果形状（如 flight 结果 URL 含航线码），不能只看 HTTP 200。

### 1.3 配额与错误处理要点

- 402 匿名额度用尽时响应里直接带自动注册的账号和新 key（可程序化续命，但 Alpha 用正式 key 即可）；
- 429 带 `Retry-After` 和 `X-RateLimit-*` 头，客户端要处理退避；
- 5xx（`capability_temporarily_unavailable` 等）建议退避重试。

### 1.4 对需求的影响

- 2.3 节"不做实时价格"边界改为：**不承诺可购买，但可用价格快照估算大交通预算**（标注报价抓取时间）；
- 体验内容来源 = 知乎/微博检索 + 上海人工种子库兜底（REQUIREMENTS.md 4.1 已同步）。

## 2. 高德开放平台（已实测，可用）

Web 服务 API（`restapi.amap.com/v3/*`），key 认证。测试日期：2026-08-04。

### 2.1 已验证能力

| 用途 | 接口 | 实测结论 |
| --- | --- | --- |
| POI → 坐标 | `place/text`（POI 搜索） | ✅ "外滩"返回风景名胜类目 + 精确坐标 + 区名，一次 100 条 |
| 地址 → 坐标 | `geocode/geo` | ✅ 可用，但见 2.2 陷阱 1 |
| 市内公交 | `direction/transit/integrated` | ✅ 外滩→迪士尼返回 5 方案：耗时 87 分钟、费用 ¥5、步行距离、逐段地铁线路名 |
| 步行 | `direction/walking` | ✅ 距离/耗时/polyline 折线齐全（路书地图渲染的数据源） |
| 跨城驾车 | `direction/driving` | ✅ 张家界→上海：1260km、13 小时、过路费 ¥3158 |
| **跨城火车** | `direction/transit/integrated` + `city`/`cityd` | ✅ **超预期**：直接返回车次号和分席别票价。张家界→上海：G252（二等 ¥517）、K4918 直达（硬座 ¥128.5）等 |

### 2.2 集成陷阱（实测复现）

1. **geocode 歧义返回错区**："外滩"的 geocode 首条是**浦东新区**外滩（住宅区），真正的景点在黄浦区。POI 定位一律用 `place/text`（返回类目可过滤"风景名胜"），`geocode/geo` 只用于用户输入的模糊地址。
2. 跨城公交必须同时传 `city`（起点城市名）和 `cityd`（终点城市名），坐标本身不够。
3. 返回 `status:"1"` 才是成功；HTTP 永远 200，失败靠 `infocode` 判断——又一个"不能只看 HTTP 状态"的 API。

### 2.3 对需求的影响（重大）

- **大交通预算不再依赖搜索估算**：火车车次 + 分席别票价可直接从高德拿到，机票用 AnySearch travel.flight 快照补充。黄金场景的超支判断（K 字头硬座 2 人往返 ≈ ¥514 vs 高铁二等 ≈ ¥2068）有了权威数据源；
- 5.3 节"往返大交通"类目的估算口径可标"高德车次票价，抓取时间 X"，可信度升一档；
- 待补测：个人开发者日配额（地理编码/路线各 5000 次/日，官网数字，未实测撞限）。

## 3. 模型 API（已实测，可用）

**正式网关：阿里云 DashScope compatible-mode（`https://dashscope.aliyuncs.com/compatible-mode/v1`），模型 `deepseek-v4-flash-0731`。** Alpha 先只支持 DeepSeek。网关有 234 个模型，deepseek-v4-pro、MiniMax/MiniMax-M3 等在列，后续备用模型有货。测试日期：2026-08-04。

> 此前在测试网关（161.118.207.12:3000）跑过同一套矩阵，结论差异很大（json_schema 模式在测试网关 5/5 失败、在 DashScope 3/3 通过）——**结构化输出的可靠性是"网关+模型"组合属性，不是模型属性。换网关必须重跑本节测试。**

### 3.1 DashScope + deepseek-v4-flash-0731 实测矩阵

| 能力 | 结果 |
| --- | --- |
| 简单 function calling（参数抽取） | ✅ 1.5s，参数正确 |
| tool call 提交结构化路书（`tool_choice:"auto"`） | ✅ **5/5 全过**，3–6s，schema 字段完整 |
| `response_format: json_schema` | ✅ 3/3 过，4–7s |
| named `tool_choice`（指定必须调某工具） | ❌ 400："not support required or object in thinking mode"——只能 `"auto"`，"模型没调工具"必须作为失败分支处理 |
| 黄金场景完整生成（5 天路书，喂入核验数据） | ✅ 两次均成功：32–43s，out 4.4k–6.6k token，`max_tokens:8000` 也够（未复现测试网关的空输出问题，但防御性检查保留） |

### 3.2 黄金场景输出质量（两次运行）

- 5 天 10 节点；总预算 ¥2994–3000，压线但在区间内；
- 大交通 ¥514 = K4918 硬座 ¥128.5 × 2 人往返，**精确引用喂入数据**；
- 预算六分类齐全（含机动余量），风险/待办合理；
- **来源诚实性 2/2 通过**：只引用喂入的真实 URL，其余填 `unverified`，零编造。

### 3.3 集成要点

1. `tool_choice` 只能 `"auto"`（thinking 模式限制，DashScope 与测试网关一致）→ system prompt 强调必须调用 + 客户端把"无 tool call"当可重试失败；
2. "finish_reason=length 且无 tool call"当失败处理（测试网关复现过 thinking 吃空 8000 token 返回空消息不报错；DashScope 未复现，防御保留）；
3. 完整路书 `max_tokens` 建议 16000：DashScope 实测 8000 够用，但留 thinking 余量；
4. 成本：单次完整生成 in ~0.8k / out ~6.6k token。DashScope deepseek flash 档按主流价格单次远低于 ¥1，✅ 成本假设成立（精确单价以 DashScope 计费页为准）；
5. 5–10 分钟承诺：单次 32–43s，多轮工具调用 + 重试仍有巨大余量，✅。
