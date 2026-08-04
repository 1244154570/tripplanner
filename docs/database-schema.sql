-- ============================================================
-- TripPlanner —— AI 行程规划服务（Alpha v0.5 重建版）
-- 数据库初始化脚本
-- PostgreSQL 17（本地 Docker 与托管环境通用）
--
-- 设计原则（对应 REQUIREMENTS.md v0.5 + docs/api-capability-report.md）：
--   1. 路书真相 = trip_version.content 的完整 JSONB 快照（与 agent 交稿
--      schema 同构），不拆行存储；提案 = 未激活版本，回滚 = 换指针。
--   2. POI/城市不自建事实表——事实来自高德与 AnySearch 实时检索，
--      快照进版本 JSONB。旧版 22 张表中的张家界 POI 体系全部删除。
--   3. 表清单（6 张）：
--      t_user             用户（沿用旧结构，Java 代码已依赖）
--      t_trip             行程头：输入、状态、当前版本指针
--      t_trip_version     版本/提案：JSONB 快照 + 触发来源
--      t_generation_task  异步生成任务：状态机、阶段、轮数、token、错误
--      t_share_link       只读分享链接：可撤销、可过期
--      t_rate_limit       限流计数（账号/IP 维度，天粒度）
-- ============================================================

CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 1. 用户（沿用旧结构）
-- ============================================================

CREATE TABLE t_user (
    id              BIGSERIAL    PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL,
    password        VARCHAR(255) NOT NULL,
    nickname        VARCHAR(50),
    phone           VARCHAR(20),
    email           VARCHAR(100),
    avatar          VARCHAR(500),
    gender          SMALLINT     DEFAULT 0 CHECK (gender IN (0, 1, 2)),
    birthday        DATE,
    age_group       VARCHAR(20),
    role            VARCHAR(20)  NOT NULL DEFAULT 'user'
                    CHECK (role IN ('user', 'admin', 'moderator')),
    status          SMALLINT     NOT NULL DEFAULT 1,
    token_version   INTEGER      NOT NULL DEFAULT 0,
    last_login_at   TIMESTAMPTZ,
    last_login_ip   INET,
    register_source VARCHAR(20)  DEFAULT 'web',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted         BOOLEAN      NOT NULL DEFAULT FALSE
);
CREATE UNIQUE INDEX uk_user_username ON t_user(username) WHERE deleted = FALSE;
CREATE UNIQUE INDEX uk_user_phone    ON t_user(phone)    WHERE deleted = FALSE;
CREATE UNIQUE INDEX uk_user_email    ON t_user(email)    WHERE deleted = FALSE;
CREATE UNIQUE INDEX uk_user_username_lower ON t_user(LOWER(username)) WHERE deleted = FALSE;
CREATE UNIQUE INDEX uk_user_email_lower ON t_user(LOWER(email)) WHERE deleted = FALSE AND email IS NOT NULL;
CREATE TRIGGER trg_user_updated BEFORE UPDATE ON t_user
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
COMMENT ON TABLE t_user IS '平台用户主表';

-- ============================================================
-- 2. 行程头
-- ============================================================

CREATE TABLE t_trip (
    id                 BIGSERIAL    PRIMARY KEY,
    user_id            BIGINT       NOT NULL REFERENCES t_user(id),
    title              VARCHAR(200) NOT NULL,
    -- 城市不做字典外键：存名称 + 高德 adcode（实测 place/text 可解析任意城市）
    departure_city     VARCHAR(50)  NOT NULL,
    departure_adcode   VARCHAR(10),
    destination_city   VARCHAR(50)  NOT NULL,
    destination_adcode VARCHAR(10),
    start_date         DATE         NOT NULL,
    end_date           DATE         NOT NULL,
    total_days         INT          GENERATED ALWAYS AS (end_date - start_date + 1) STORED,
    people_count       INT          NOT NULL DEFAULT 1,
    budget_min         DECIMAL(10,2),
    budget_max         DECIMAL(10,2),
    -- 兴趣标签、特殊限制、澄清问题答案等结构化输入（3.1/3.2 节）
    requirement        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    -- 生命周期主状态（第 8 节）：draft/generating/planned/traveling/finished/failed/cancelled
    status             VARCHAR(20)  NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft','generating','planned','traveling','finished','failed','cancelled')),
    -- 派生风险标记（第 8 节）：["over_budget","unverified","experimental",...]
    risk_flags         JSONB        NOT NULL DEFAULT '[]'::jsonb,
    -- 当前生效版本；提案确认后指向新版本，回滚即改指针
    current_version_id BIGINT,
    -- 风险确认快照（6.3 节"开始出行"）
    risk_ack_at        TIMESTAMPTZ,
    risk_ack_snapshot  JSONB,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted            BOOLEAN      NOT NULL DEFAULT FALSE,
    CHECK (end_date >= start_date)
);
CREATE INDEX idx_trip_user   ON t_trip(user_id, updated_at DESC) WHERE deleted = FALSE;
CREATE INDEX idx_trip_status ON t_trip(status);
CREATE TRIGGER trg_trip_updated BEFORE UPDATE ON t_trip
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
COMMENT ON TABLE t_trip IS '行程头：用户输入、生命周期状态、当前版本指针';

-- ============================================================
-- 3. 版本 / 提案（路书真相）
-- ============================================================

CREATE TABLE t_trip_version (
    id           BIGSERIAL    PRIMARY KEY,
    trip_id      BIGINT       NOT NULL REFERENCES t_trip(id) ON DELETE CASCADE,
    version_no   INT          NOT NULL,
    -- 完整路书快照，与 agent 交稿 schema 同构：
    -- { days:[{day,nodes:[{seq,name,start_time,end_time,transport_to_next,
    --   budget_cny,source_url,risk,lng,lat}],day_budget_cny}],
    --   budget_breakdown:{intercity,hotel,tickets,local_transport,food,buffer},
    --   total_budget_cny, risks:[], todos:[{text,status}], sources:[{url,title}],
    --   alternative:{...同构,可空}, experimental:bool }
    content      JSONB        NOT NULL,
    -- 版本来源：initial_generation / replan / user_edit / rollback
    created_by   VARCHAR(20)  NOT NULL
                 CHECK (created_by IN ('initial_generation','replan','user_edit','rollback')),
    -- 提案机制（6.1/6.2 节）：提案=未激活；确认后置 TRUE 并更新 trip.current_version_id
    is_active    BOOLEAN      NOT NULL DEFAULT FALSE,
    -- 触发原因/用户反馈/被拒原因等追溯信息
    trigger_note TEXT,
    task_id      BIGINT,      -- 产生该版本的生成任务（用户手动编辑时为空）
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (trip_id, version_no)
);
CREATE INDEX idx_version_trip ON t_trip_version(trip_id, version_no DESC);
COMMENT ON TABLE t_trip_version IS '路书版本与提案：JSONB 完整快照为唯一真相，回滚=换 trip.current_version_id 指针';

ALTER TABLE t_trip
    ADD CONSTRAINT fk_trip_current_version
    FOREIGN KEY (current_version_id) REFERENCES t_trip_version(id) DEFERRABLE INITIALLY DEFERRED;

-- ============================================================
-- 4. 异步生成任务
-- ============================================================

CREATE TABLE t_generation_task (
    id            BIGSERIAL    PRIMARY KEY,
    trip_id       BIGINT       NOT NULL REFERENCES t_trip(id) ON DELETE CASCADE,
    user_id       BIGINT       NOT NULL REFERENCES t_user(id),
    -- initial / replan（v0.5 单一重排动作）
    task_type     VARCHAR(20)  NOT NULL DEFAULT 'initial'
                  CHECK (task_type IN ('initial','replan')),
    -- 强度档（5.1 节）：fast≈8 轮 / deep≈20 轮
    mode          VARCHAR(10)  NOT NULL DEFAULT 'fast'
                  CHECK (mode IN ('fast','deep')),
    status        VARCHAR(20)  NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','running','succeeded','failed','cancelled')),
    -- 工具⇒阶段实时映射的当前阶段：searching/routing/pricing/composing/validating
    current_stage VARCHAR(30),
    -- 循环执行记录：轮数、每轮工具调用摘要（排障与 10 节可观测性要求）
    rounds_used   INT          NOT NULL DEFAULT 0,
    tool_trace    JSONB        NOT NULL DEFAULT '[]'::jsonb,
    -- 降级标记：模型两轮不调工具后转"一次合成"模式（5.1 节兜底）
    degraded      BOOLEAN      NOT NULL DEFAULT FALSE,
    model         VARCHAR(100),
    total_tokens  INT          NOT NULL DEFAULT 0,
    -- 面向用户的可理解失败原因（5.1 节"不得留下假完成状态"）
    error_summary VARCHAR(500),
    -- 内部错误详情（不含密钥）
    error_detail  TEXT,
    result_version_id BIGINT   REFERENCES t_trip_version(id),
    queued_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ
);
CREATE INDEX idx_task_trip   ON t_generation_task(trip_id, queued_at DESC);
CREATE INDEX idx_task_status ON t_generation_task(status) WHERE status IN ('queued','running');
CREATE INDEX idx_task_user_day ON t_generation_task(user_id, queued_at);
COMMENT ON TABLE t_generation_task IS '异步生成任务：状态机、阶段映射、工具轨迹、失败原因';

-- ============================================================
-- 5. 只读分享链接
-- ============================================================

CREATE TABLE t_share_link (
    id          BIGSERIAL    PRIMARY KEY,
    trip_id     BIGINT       NOT NULL REFERENCES t_trip(id) ON DELETE CASCADE,
    -- 不可猜测的分享码（服务端生成 ≥128bit 随机）
    share_code  VARCHAR(64)  NOT NULL UNIQUE,
    revoked     BOOLEAN      NOT NULL DEFAULT FALSE,
    expires_at  TIMESTAMPTZ,
    view_count  INT          NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_share_trip ON t_share_link(trip_id);
COMMENT ON TABLE t_share_link IS '只读分享链接：可撤销、可过期、禁止收录（7.2 节；展示时按脱敏规则过滤字段）';

-- ============================================================
-- 6. 限流计数（第 10 节 P0 防滥用）
-- ============================================================

CREATE TABLE t_rate_limit (
    id          BIGSERIAL    PRIMARY KEY,
    -- 维度：user_daily_gen（账号日生成）/ ip_daily_register（IP 日注册）
    limit_key   VARCHAR(30)  NOT NULL,
    -- 账号 ID 或 IP 文本
    subject     VARCHAR(64)  NOT NULL,
    day         DATE         NOT NULL,
    count       INT          NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (limit_key, subject, day)
);
COMMENT ON TABLE t_rate_limit IS '限流计数：账号日生成 5 次、IP 日注册 3 个；并发与全局队列由应用层内存控制';
