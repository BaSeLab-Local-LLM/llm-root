-- ==============================================================================
--                    LLM PLATFORM - DATABASE INITIALIZATION
-- ==============================================================================
-- 이 파일은 PostgreSQL 컨테이너 최초 기동 시 자동 실행됩니다.
-- 경로: /docker-entrypoint-initdb.d/01-init-schema.sql
-- 재실행 시: docker volume rm llm-postgres-data 후 docker compose up -d
-- ==============================================================================

-- 확장 모듈
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 스키마 생성 (LiteLLM 테이블과 분리)
CREATE SCHEMA IF NOT EXISTS llm_app;

-- search_path 설정
SET search_path TO llm_app, public;

-- ==============================================================================
--                              ENUM TYPES
-- ==============================================================================

CREATE TYPE llm_app.user_role AS ENUM ('admin', 'student');
CREATE TYPE llm_app.message_role AS ENUM ('system', 'user', 'assistant');
CREATE TYPE llm_app.feedback_type AS ENUM ('thumbs_up', 'thumbs_down');

-- ==============================================================================
--                             1. USERS TABLE
-- ==============================================================================
-- 사용자 인증, API Key 관리, 사용량 할당량(Quota) 관리
-- ==============================================================================

CREATE TABLE llm_app.users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    api_key         VARCHAR(128) NOT NULL UNIQUE,
    username        VARCHAR(64)  NOT NULL UNIQUE,
    password_hash   VARCHAR(256) NOT NULL,
    role            llm_app.user_role NOT NULL DEFAULT 'student',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    failed_login_attempts INTEGER NOT NULL DEFAULT 0,  -- 로그인 실패 횟수 (10회 이상 시 계정 비활성화)

    -- Quota (사용량 할당량)
    daily_token_limit   BIGINT DEFAULT 100000,       -- 일일 토큰 한도 (NULL = 무제한)

    -- 사용자 프로필 정보
    display_name    VARCHAR(64),                     -- 실명 또는 표시 이름
    class_name      VARCHAR(64),                     -- 소속 수업/반

    -- API Key 만료
    api_key_expires_at  TIMESTAMPTZ,                 -- NULL = 만료 없음

    -- 강제 로그아웃 관리
    token_version   INTEGER NOT NULL DEFAULT 1,      -- 증가 시 기존 JWT 무효화 (강제 로그아웃)

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스
CREATE INDEX idx_users_api_key ON llm_app.users (api_key);
CREATE INDEX idx_users_role ON llm_app.users (role);
CREATE INDEX idx_users_is_active ON llm_app.users (is_active);

-- ==============================================================================
--                          2. USAGE_LOGS TABLE
-- ==============================================================================
-- LLM 호출별 토큰 사용량, 응답 시간, 상태 코드 기록
-- Prometheus/Grafana 대시보드 연동 대상
-- ==============================================================================

CREATE TABLE llm_app.usage_logs (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             UUID NOT NULL REFERENCES llm_app.users(id) ON DELETE CASCADE,
    model_name          VARCHAR(128) NOT NULL,
    prompt_tokens       INTEGER NOT NULL DEFAULT 0,
    completion_tokens   INTEGER NOT NULL DEFAULT 0,
    total_tokens        INTEGER NOT NULL DEFAULT 0,
    duration_ms         DOUBLE PRECISION,            -- 응답 소요 시간 (ms)
    status_code         INTEGER,                     -- HTTP 상태 코드
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스: 사용자별 사용량 조회, 일별/월별 집계
CREATE INDEX idx_usage_logs_user_id ON llm_app.usage_logs (user_id);
CREATE INDEX idx_usage_logs_created_at ON llm_app.usage_logs (created_at);
CREATE INDEX idx_usage_logs_user_created ON llm_app.usage_logs (user_id, created_at);

-- ==============================================================================
--                        3. CONVERSATIONS TABLE
-- ==============================================================================
-- 대화 세션 관리 (프론트엔드 사이드바 히스토리)
-- ==============================================================================

CREATE TABLE llm_app.conversations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES llm_app.users(id) ON DELETE CASCADE,
    title           VARCHAR(256) DEFAULT '새 대화',
    model_name      VARCHAR(128),
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스: 사용자별 대화 목록 (최신순)
CREATE INDEX idx_conversations_user_id ON llm_app.conversations (user_id, updated_at DESC);

-- ==============================================================================
--                          4. MESSAGES TABLE
-- ==============================================================================
-- 개별 메시지 저장 → LLM 프롬프트 컨텍스트 반영
-- conversation_id 기준으로 created_at 순 조회 → messages[] 배열 구성
-- ==============================================================================

CREATE TABLE llm_app.messages (
    id                  BIGSERIAL PRIMARY KEY,
    conversation_id     UUID NOT NULL REFERENCES llm_app.conversations(id) ON DELETE CASCADE,
    role                llm_app.message_role NOT NULL,
    content             TEXT NOT NULL,
    token_count         INTEGER,                     -- 해당 메시지의 토큰 수
    feedback            llm_app.feedback_type,       -- 👍/👎 (assistant 메시지용)
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스: 대화별 메시지 시간순 조회 (프롬프트 컨텍스트 구성)
CREATE INDEX idx_messages_conversation_id ON llm_app.messages (conversation_id, created_at ASC);

-- ==============================================================================
--                       5. SYSTEM_SETTINGS TABLE
-- ==============================================================================
-- 전역 시스템 설정 (Key-Value)
-- 비상 제어: llm_enabled = 'false' → 전체 LLM 추론 비활성화 (GPU 보호)
-- ==============================================================================

CREATE TABLE llm_app.system_settings (
    key             VARCHAR(64) PRIMARY KEY,
    value           TEXT NOT NULL,
    description     VARCHAR(256),
    updated_by      UUID REFERENCES llm_app.users(id) ON DELETE SET NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==============================================================================
--                         6. AUDIT_LOGS TABLE
-- ==============================================================================
-- 관리자 행위 감사 추적
-- 예: 사용자 비활성화, 비상 제어 토글, Quota 변경 등
-- ==============================================================================

CREATE TABLE llm_app.audit_logs (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES llm_app.users(id) ON DELETE SET NULL,
    action          VARCHAR(64) NOT NULL,            -- 'user.deactivate', 'system.llm_toggle', 'quota.update' 등
    target_type     VARCHAR(64),                     -- 'user', 'system_setting', 'conversation' 등
    target_id       VARCHAR(128),                    -- 대상 레코드 ID
    old_value       JSONB,                           -- 변경 전 값
    new_value       JSONB,                           -- 변경 후 값
    ip_address      VARCHAR(45),                     -- IPv4/IPv6
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스: 시간순 감사 로그 조회, 사용자별 행위 조회
CREATE INDEX idx_audit_logs_created_at ON llm_app.audit_logs (created_at DESC);
CREATE INDEX idx_audit_logs_user_id ON llm_app.audit_logs (user_id);
CREATE INDEX idx_audit_logs_action ON llm_app.audit_logs (action);

-- ==============================================================================
--                        7. LOGIN_HISTORY TABLE
-- ==============================================================================
-- 로그인 성공/실패 이력 (보안 감사)
-- ==============================================================================

CREATE TABLE llm_app.login_history (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES llm_app.users(id) ON DELETE SET NULL,
    ip_address      VARCHAR(45),                     -- 접속 IP
    user_agent      VARCHAR(512),                    -- 브라우저/클라이언트 정보
    success         BOOLEAN NOT NULL DEFAULT true,
    failure_reason  VARCHAR(128),                    -- 'invalid_password', 'account_disabled', 'key_expired' 등
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 인덱스: 사용자별 로그인 이력, 실패 기록 조회
CREATE INDEX idx_login_history_user_id ON llm_app.login_history (user_id, created_at DESC);
CREATE INDEX idx_login_history_success ON llm_app.login_history (success) WHERE NOT success;

-- ==============================================================================
--                     8. OPERATION_SCHEDULES TABLE
-- ==============================================================================
-- LLM 운영 시간 스케줄링 (요일/시간대별 GPU 사용 제어)
-- 우선순위: llm_enabled=false (비상정지) > 스케줄 > 기본 허용
-- ==============================================================================

CREATE TABLE llm_app.operation_schedules (
    id              SERIAL PRIMARY KEY,
    day_of_week     SMALLINT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=일, 1=월, ..., 6=토
    start_time      TIME NOT NULL,                   -- 운영 시작 시각
    end_time        TIME NOT NULL,                   -- 운영 종료 시각
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_by      UUID REFERENCES llm_app.users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_time_range CHECK (start_time < end_time),
    CONSTRAINT uq_day_of_week UNIQUE (day_of_week)   -- 요일당 하나의 스케줄
);

-- ==============================================================================
--                          UPDATED_AT TRIGGER
-- ==============================================================================
-- users, conversations, operation_schedules 테이블의 updated_at 자동 갱신

CREATE OR REPLACE FUNCTION llm_app.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_users_updated_at
    BEFORE UPDATE ON llm_app.users
    FOR EACH ROW EXECUTE FUNCTION llm_app.update_updated_at_column();

CREATE TRIGGER trigger_conversations_updated_at
    BEFORE UPDATE ON llm_app.conversations
    FOR EACH ROW EXECUTE FUNCTION llm_app.update_updated_at_column();

CREATE TRIGGER trigger_schedules_updated_at
    BEFORE UPDATE ON llm_app.operation_schedules
    FOR EACH ROW EXECUTE FUNCTION llm_app.update_updated_at_column();

-- ==============================================================================
--                            SEED DATA
-- ==============================================================================

-- 기본 관리자 계정
-- 초기 비밀번호는 generate_keys.py 스크립트로 설정됩니다.
-- generate_keys.py를 실행하여 관리자 계정을 초기화하세요.
DO $$
BEGIN
    -- 임시 관리자 계정 (generate_keys.py 실행 전까지 사용)
    -- generate_keys.py가 실행되면 이 계정은 TRUNCATE 후 재생성됩니다.
    INSERT INTO llm_app.users (api_key, username, password_hash, role, is_active, daily_token_limit)
    VALUES (
        'sk-admin-' || encode(gen_random_bytes(24), 'hex'),
        'admin',
        crypt('1234', gen_salt('bf', 12)),
        'admin',
        true,
        NULL
    );

    RAISE NOTICE '============================================';
    RAISE NOTICE 'Admin account created with default password.';
    RAISE NOTICE '============================================';
END $$;

-- 시스템 설정 초기값 (updated_by = 관리자 계정)
INSERT INTO llm_app.system_settings (key, value, description, updated_by) VALUES
    ('llm_enabled',           'true',  'LLM 추론 활성화 여부 (false = 비상 정지, GPU 미사용)',
        (SELECT id FROM llm_app.users WHERE username = 'admin')),
    ('schedule_enabled',      'false', '운영 시간 스케줄 활성화 (false = 24시간 운영, true = 스케줄 기반)',
        (SELECT id FROM llm_app.users WHERE username = 'admin')),
    ('max_context_tokens',    '4096',  'LLM 프롬프트에 포함할 최대 컨텍스트 토큰 수',
        (SELECT id FROM llm_app.users WHERE username = 'admin')),
    ('default_daily_limit',   '100000','신규 사용자 기본 일일 토큰 한도',
        (SELECT id FROM llm_app.users WHERE username = 'admin'));

-- 운영 스케줄 초기값 (24시간 7일 운영)
INSERT INTO llm_app.operation_schedules (day_of_week, start_time, end_time, is_active) VALUES
    (0, '00:00', '23:59', true),    -- 일요일
    (1, '00:00', '23:59', true),    -- 월요일
    (2, '00:00', '23:59', true),    -- 화요일
    (3, '00:00', '23:59', true),    -- 수요일
    (4, '00:00', '23:59', true),    -- 목요일
    (5, '00:00', '23:59', true),    -- 금요일
    (6, '00:00', '23:59', true);    -- 토요일

-- ==============================================================================
--                          USEFUL VIEWS
-- ==============================================================================

-- 사용자별 일일 토큰 사용량 요약
CREATE OR REPLACE VIEW llm_app.v_daily_usage AS
SELECT
    u.id AS user_id,
    u.username,
    DATE(ul.created_at) AS usage_date,
    SUM(ul.total_tokens) AS daily_tokens_used,
    u.daily_token_limit,
    CASE
        WHEN u.daily_token_limit IS NULL THEN false
        ELSE SUM(ul.total_tokens) >= u.daily_token_limit
    END AS limit_exceeded
FROM llm_app.users u
LEFT JOIN llm_app.usage_logs ul ON u.id = ul.user_id
    AND DATE(ul.created_at) = CURRENT_DATE
GROUP BY u.id, u.username, DATE(ul.created_at), u.daily_token_limit;

-- 현재 LLM 운영 가능 여부 확인 뷰
CREATE OR REPLACE VIEW llm_app.v_llm_availability AS
SELECT
    (SELECT value = 'true' FROM llm_app.system_settings WHERE key = 'llm_enabled') AS emergency_enabled,
    (SELECT value = 'true' FROM llm_app.system_settings WHERE key = 'schedule_enabled') AS schedule_mode,
    COALESCE(
        (SELECT is_active
         FROM llm_app.operation_schedules
         WHERE day_of_week = EXTRACT(DOW FROM NOW())
           AND CURRENT_TIME BETWEEN start_time AND end_time),
        false
    ) AS within_schedule,
    CASE
        -- 비상 정지가 우선
        WHEN (SELECT value FROM llm_app.system_settings WHERE key = 'llm_enabled') = 'false' THEN false
        -- 스케줄 모드 비활성화 시 항상 허용
        WHEN (SELECT value FROM llm_app.system_settings WHERE key = 'schedule_enabled') = 'false' THEN true
        -- 스케줄 모드 활성화 시 시간표 확인
        ELSE COALESCE(
            (SELECT is_active
             FROM llm_app.operation_schedules
             WHERE day_of_week = EXTRACT(DOW FROM NOW())
               AND CURRENT_TIME BETWEEN start_time AND end_time),
            false
        )
    END AS llm_available;

-- ==============================================================================
--  초기화 완료
-- ==============================================================================
