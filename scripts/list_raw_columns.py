"""Print raw schema table and column names."""

import os

import psycopg2
from dotenv import load_dotenv

load_dotenv()

conn = psycopg2.connect(
    host=os.getenv("PG_HOST", "localhost"),
    port=os.getenv("PG_PORT", "5432"),
    dbname=os.getenv("PG_DB", "banking_delta"),
    user=os.getenv("PG_USER", "postgres"),
    password=os.getenv("PG_PASS", "admin"),
)

with conn, conn.cursor() as cur:
    cur.execute("""
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'raw'
        ORDER BY table_name, ordinal_position
    """)
    rows = cur.fetchall()

current = None
for table, column in rows:
    if table != current:
        current = table
        print(f"\n{table}")
    print(f"  - {column}")
