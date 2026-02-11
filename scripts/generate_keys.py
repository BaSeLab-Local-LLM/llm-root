import asyncio
import os
import urllib.request
import json
import time
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

# Configuration
LITELLM_URL = os.environ.get("LITELLM_URL", "http://localhost:4000")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "sk-master-key")
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

async def seed_database(sql_statements):
    print(f" Connecting to DB to execute {len(sql_statements)} statements...")
    try:
        engine = create_async_engine(DATABASE_URL)
        async with engine.begin() as conn:
            for sql in sql_statements:
                if sql.strip():
                    await conn.execute(text(sql))
        await engine.dispose()
        print("Database seeding completed successfully.")
    except Exception as e:
        print(f"Database seeding failed: {e}")
        # Assuming DB connection issue, but let's exit 1?
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
    sql_statements = []
    
    # Truncate users table first
    sql_statements.append("TRUNCATE TABLE llm_app.users CASCADE;")

    # 2. Admin Key
    print("Generating Admin key...", end=" ")
    admin_key = generate_key("admin", role="admin", max_budget=1000.0, rpm=1000)
    if admin_key:
        print("Done.")
        sql = f"""
        INSERT INTO llm_app.users (api_key, username, password_hash, role, is_active, daily_token_limit)
        VALUES ('{admin_key}', 'admin', crypt('admin', gen_salt('bf', 8)), 'admin', true, 999999999);
        """
        sql_statements.append(sql.strip())
    else:
        print("Failed.")

    # 3. Student Keys
    print(f"Generating {STUDENT_COUNT} Student keys...")
    for i in range(1, STUDENT_COUNT + 1):
        student_id = str(i)
        # print(f"Student {student_id}...", end="\r")
        api_key = generate_key(student_id, role="student", max_budget=1.0, rpm=10)
        if api_key:
            sql = f"""
            INSERT INTO llm_app.users (api_key, username, password_hash, role, is_active, daily_token_limit)
            VALUES ('{api_key}', '{student_id}', crypt('1234', gen_salt('bf', 8)), 'student', true, 100000);
            """
            sql_statements.append(sql.strip())
    
    # 4. Insert into DB
    if sql_statements:
        asyncio.run(seed_database(sql_statements))
    else:
        print("No SQL statements to run.")

if __name__ == "__main__":
    main()
