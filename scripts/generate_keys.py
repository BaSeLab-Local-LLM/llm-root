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

def generate_key(user_id, role="student", max_budget=1.0, rpm=10):
    url = f"{LITELLM_URL}/key/generate"
    headers = {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json"
    }
    
    # Model name updated to "Local LLM" as per user request
    data = {
        "models": ["Local LLM"],
        "aliases": {"user_email": f"{user_id}@example.com"},
        "duration": None,
        "max_budget": max_budget,
        "tpm_limit": 100000,
        "rpm_limit": rpm,
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
    admin_key = generate_key("admin", role="admin", max_budget=1000.0, rpm=1000)
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
        api_key = generate_key(student_id, role="student", max_budget=1.0, rpm=10)
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
    
    # 4. Insert into DB
    if statements:
        asyncio.run(seed_database(statements))
    else:
        print("No SQL statements to run.")

if __name__ == "__main__":
    main()
