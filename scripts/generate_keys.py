import asyncio
import os
import urllib.request
import json
import time
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

# Configuration
LITELLM_URL = os.environ.get("LITELLM_URL", "http://localhost:4000")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY")
if not MASTER_KEY:
    print("LITELLM_MASTER_KEY environment variable is required.")
    exit(1)
# Ensure DATABASE_URL is set
if "DATABASE_URL" not in os.environ:
    print("DATABASE_URL environment variable is required.")
    exit(1)
DATABASE_URL = os.environ["DATABASE_URL"]

STUDENT_COUNT = 100

# Rate Limit / Budget 설정 (환경변수로 오버라이드 가능)
STUDENT_RPM = int(os.environ.get("DEFAULT_RATE_LIMIT_RPM", "10"))
STUDENT_TPM = int(os.environ.get("DEFAULT_RATE_LIMIT_TPM", "100000"))
STUDENT_MAX_BUDGET = float(os.environ.get("DEFAULT_STUDENT_MAX_BUDGET", "1.0"))
ADMIN_RPM = int(os.environ.get("ADMIN_RATE_LIMIT_RPM", "1000"))
ADMIN_TPM = int(os.environ.get("ADMIN_RATE_LIMIT_TPM", "1000000"))
ADMIN_MAX_BUDGET = float(os.environ.get("ADMIN_MAX_BUDGET", "1000.0"))

def wait_for_litellm():
    print(f"Waiting for LiteLLM at {LITELLM_URL}...")
    url = f"{LITELLM_URL}/health/readiness"
    # Wait up to 60 seconds
    retries = 30
    while retries > 0:
        try:
            with urllib.request.urlopen(url) as response:
                if response.status == 200:
                    print("LiteLLM is ready!")
                    return True
        except Exception:
            pass
        time.sleep(2)
        retries -= 1
        print("Waiting for LiteLLM...")
    print("LiteLLM is not ready after timeout.")
    return False

def list_keys():
    url = f"{LITELLM_URL}/key/list"
    headers = {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json"
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode('utf-8'))
            return data.get('keys', [])
    except Exception as e:
        print(f"Error listing keys: {e}")
        return []

def delete_keys(keys):
    if not keys:
        return
    
    url = f"{LITELLM_URL}/key/delete"
    headers = {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json"
    }
    data = {"keys": keys}
    try:
        req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers)
        with urllib.request.urlopen(req) as response:
            print(f"Deleted {len(keys)} keys.")
    except Exception as e:
        print(f"Error deleting keys: {e}")

def generate_key(user_id, role="student", max_budget=None, rpm=None, tpm=None):
    url = f"{LITELLM_URL}/key/generate"
    headers = {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json"
    }
    
    data = {
        "models": ["Local LLM"],
        "aliases": {"user_email": f"{user_id}@example.com"},
        "duration": None,
        "max_budget": max_budget if max_budget is not None else STUDENT_MAX_BUDGET,
        "tpm_limit": tpm if tpm is not None else STUDENT_TPM,
        "rpm_limit": rpm if rpm is not None else STUDENT_RPM,
        "metadata": {
            "user_id": user_id,
            "role": role,
            "track_usage": True
        },
        "key_alias": f"key-{user_id}"
    }
    
    try:
        req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers)
        with urllib.request.urlopen(req) as response:
            result = json.loads(response.read().decode('utf-8'))
            return result['key']
    except Exception as e:
        print(f"Error generating key for {user_id}: {e}")
        return None

async def check_already_seeded() -> bool:
    """student 유저가 이미 존재하면 True를 반환합니다.
    init.sql이 admin만 생성한 경우에는 False → 시드 실행."""
    try:
        engine = create_async_engine(DATABASE_URL)
        async with engine.connect() as conn:
            result = await conn.execute(
                text("SELECT COUNT(*) FROM llm_app.users WHERE role = 'student';")
            )
            count = result.scalar()
        await engine.dispose()
        return count is not None and count > 0
    except Exception:
        # 테이블이 아직 없는 경우 (최초 배포) → seeding 필요
        return False


async def seed_database(parameterized_statements):
    """
    파라미터화된 쿼리를 실행합니다.
    각 항목은 (sql_text, params_dict) 튜플 또는 (sql_text, None) 형태입니다.
    """
    print(f" Connecting to DB to execute {len(parameterized_statements)} statements...")
    try:
        engine = create_async_engine(DATABASE_URL)
        async with engine.begin() as conn:
            for sql, params in parameterized_statements:
                if sql.strip():
                    if params:
                        await conn.execute(text(sql), params)
                    else:
                        await conn.execute(text(sql))
        await engine.dispose()
        print("Database seeding completed successfully.")
    except Exception as e:
        print(f"Database seeding failed: {e}")
        exit(1)

def main():
    # 이미 시딩된 DB인지 확인 (volume이 유지된 경우 스킵)
    if asyncio.run(check_already_seeded()):
        print("✅ Users already exist in DB — skipping seed. (To re-seed, remove the postgres volume and redeploy.)")
        return

    if not wait_for_litellm():
        exit(1)
        
    # 1. Cleanup existing keys
    print("Cleaning up existing keys...")
    while True:
        keys = list_keys()
        if not keys:
            break
        delete_keys(keys)
        
    print("Generating new keys...")
    statements = []  # list of (sql, params) tuples
    
    # Truncate users table first
    statements.append(("TRUNCATE TABLE llm_app.users CASCADE;", None))

    # 초기 비밀번호: 모든 계정 "1234" (첫 로그인 후 변경 권장)
    INITIAL_PASSWORD = "1234"

    # 2. Admin Key — 파라미터화 쿼리로 SQL Injection 방지
    print("Generating Admin key...", end=" ")
    admin_key = generate_key("admin", role="admin", max_budget=ADMIN_MAX_BUDGET, rpm=ADMIN_RPM, tpm=ADMIN_TPM)
    if admin_key:
        print("Done.")
        statements.append((
            """INSERT INTO llm_app.users (api_key, username, password_hash, role, is_active, daily_token_limit, display_name, class_name)
               VALUES (:api_key, :username, crypt(:password, gen_salt('bf', 12)), :role, true, :daily_limit, :display_name, :class_name);""",
            {
                "api_key": admin_key,
                "username": "admin",
                "password": INITIAL_PASSWORD,
                "role": "admin",
                "daily_limit": 999999999,
                "display_name": "admin",
                "class_name": "admin",
            }
        ))
    else:
        print("Failed.")

    # 3. Student Keys — 파라미터화 쿼리로 SQL Injection 방지
    print(f"Generating {STUDENT_COUNT} Student keys...")
    for i in range(1, STUDENT_COUNT + 1):
        student_id = str(i)
        api_key = generate_key(student_id, role="student")
        if api_key:
            statements.append((
                """INSERT INTO llm_app.users (api_key, username, password_hash, role, is_active, daily_token_limit, display_name, class_name)
                   VALUES (:api_key, :username, crypt(:password, gen_salt('bf', 12)), :role, true, :daily_limit, :display_name, :class_name);""",
                {
                    "api_key": api_key,
                    "username": student_id,
                    "password": INITIAL_PASSWORD,
                    "role": "student",
                    "daily_limit": 100000,
                    "display_name": "test",
                    "class_name": "test",
                }
            ))

    print(f"  초기 비밀번호: {INITIAL_PASSWORD} (모든 계정 동일)")
    print(f"  ⚠  첫 로그인 후 반드시 비밀번호를 변경하세요!")

    # 4. 시스템 설정 및 운영 스케줄 복원 (TRUNCATE CASCADE로 삭제되므로 재삽입 필요)
    statements.append((
        """INSERT INTO llm_app.system_settings (key, value, description, updated_by)
           VALUES
               ('llm_enabled',        'true',   'LLM 추론 활성화 여부 (false = 비상 정지, GPU 미사용)',
                   (SELECT id FROM llm_app.users WHERE username = 'admin')),
               ('schedule_enabled',   'false',  '운영 시간 스케줄 활성화 (false = 24시간 운영, true = 스케줄 기반)',
                   (SELECT id FROM llm_app.users WHERE username = 'admin')),
               ('max_context_tokens', '4096',   'LLM 프롬프트에 포함할 최대 컨텍스트 토큰 수',
                   (SELECT id FROM llm_app.users WHERE username = 'admin')),
               ('default_daily_limit','100000', '신규 사용자 기본 일일 토큰 한도',
                   (SELECT id FROM llm_app.users WHERE username = 'admin'))
           ON CONFLICT (key) DO NOTHING;""",
        None
    ))
    statements.append((
        """INSERT INTO llm_app.operation_schedules (day_of_week, start_time, end_time, is_active)
           VALUES
               (0, '00:00', '23:59', true),
               (1, '00:00', '23:59', true),
               (2, '00:00', '23:59', true),
               (3, '00:00', '23:59', true),
               (4, '00:00', '23:59', true),
               (5, '00:00', '23:59', true),
               (6, '00:00', '23:59', true)
           ON CONFLICT (day_of_week) DO NOTHING;""",
        None
    ))

    # 5. Insert into DB
    if statements:
        asyncio.run(seed_database(statements))
    else:
        print("No SQL statements to run.")

if __name__ == "__main__":
    main()
