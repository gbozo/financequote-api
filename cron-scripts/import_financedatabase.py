#!/usr/bin/env python3
"""
FinanceDatabase to SQLite importer.
Creates/updates an SQLite database with data from the FinanceDatabase package.
Each asset type gets its own table with type-specific columns matching upstream schemas.
Designed to run in tmpfs for performance, with proper locking for concurrent access.
"""

import os
import sys
import sqlite3
import logging
import fcntl
import time
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Database path - use tmpfs if available, else /tmp
DB_PATH = os.environ.get('FQ_DB_PATH', '/data/finance_database.db')
LOCK_PATH = DB_PATH + '.lock'

# Import FinanceDatabase
try:
    import financedatabase as fd
except ImportError as e:
    logger.error(f"Failed to import financedatabase: {e}")
    sys.exit(1)

# Asset classes to import (classes need to be instantiated)
ASSET_CLASSES = {
    'equities': lambda: fd.Equities(),
    'etfs': lambda: fd.ETFs(),
    'funds': lambda: fd.Funds(),
    'indices': lambda: fd.Indices(),
    'currencies': lambda: fd.Currencies(),
    'cryptos': lambda: fd.Cryptos(),
    'moneymarkets': lambda: fd.Moneymarkets(),
}

# Per-type table schemas: columns that actually exist in each asset type's DataFrame
# Derived from upstream FinanceDatabase source code (select() and show_options() methods)
TABLE_SCHEMAS = {
    'equities': [
        'symbol', 'name', 'currency', 'sector', 'industry_group', 'industry',
        'exchange', 'market', 'country', 'state', 'city', 'zipcode', 'website',
        'market_cap', 'isin', 'cusip', 'figi', 'composite_figi', 'shareclass_figi', 'summary',
    ],
    'etfs': [
        'symbol', 'name', 'currency', 'summary', 'category_group', 'category',
        'family', 'exchange', 'market',
    ],
    'funds': [
        'symbol', 'name', 'currency', 'summary', 'category_group', 'category',
        'family', 'exchange', 'market',
    ],
    'indices': [
        'symbol', 'name', 'currency', 'summary', 'category_group', 'category',
        'exchange', 'market',
    ],
    'currencies': [
        'symbol', 'name', 'summary', 'exchange', 'base_currency', 'quote_currency',
    ],
    'cryptos': [
        'symbol', 'name', 'currency', 'summary', 'exchange', 'cryptocurrency',
    ],
    'moneymarkets': [
        'symbol', 'name', 'currency', 'summary', 'family',
    ],
}

# Indexes per type: columns to create indexes on (filterable/searchable columns)
TABLE_INDEXES = {
    'equities': ['symbol', 'name', 'country', 'sector', 'industry', 'exchange', 'market_cap', 'isin'],
    'etfs': ['symbol', 'name', 'category_group', 'category', 'family', 'exchange'],
    'funds': ['symbol', 'name', 'category_group', 'category', 'family', 'exchange'],
    'indices': ['symbol', 'name', 'category_group', 'category', 'exchange'],
    'currencies': ['symbol', 'name', 'base_currency', 'quote_currency', 'exchange'],
    'cryptos': ['symbol', 'name', 'cryptocurrency', 'currency', 'exchange'],
    'moneymarkets': ['symbol', 'name', 'currency', 'family'],
}


def acquire_lock(lock_file, timeout=30):
    """Acquire an exclusive lock with timeout."""
    start_time = time.time()
    while True:
        try:
            lock_fh = open(lock_file, 'w')
            fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock_fh
        except (IOError, OSError):
            if time.time() - start_time > timeout:
                raise TimeoutError(f"Could not acquire lock after {timeout}s")
            time.sleep(0.5)


def release_lock(lock_fh):
    """Release the lock."""
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_UN)
        lock_fh.close()
    except Exception as e:
        logger.warning(f"Error releasing lock: {e}")


def init_database(conn):
    """Initialize database with per-type table schemas."""
    cursor = conn.cursor()

    # Enable WAL mode for better concurrent read/write handling
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA busy_timeout=30000")
    cursor.execute("PRAGMA synchronous=NORMAL")

    # Create tables for each asset class with type-specific columns
    for table_name, columns in TABLE_SCHEMAS.items():
        # Build column definitions (all TEXT except id and created_at)
        col_defs = ['id INTEGER PRIMARY KEY AUTOINCREMENT']
        for col in columns:
            col_defs.append(f'{col} TEXT')
        col_defs.append('created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP')

        create_sql = f"CREATE TABLE IF NOT EXISTS {table_name} ({', '.join(col_defs)})"
        cursor.execute(create_sql)

        # Create indexes for this type's filterable/searchable columns
        for col in TABLE_INDEXES.get(table_name, []):
            cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_{col} ON {table_name}({col})")

    # Create metadata table to track updates
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    conn.commit()
    logger.info("Database initialized with per-type schemas and indexes")


def import_asset_class(conn, class_name, asset_class_factory):
    """Import data from a single asset class using its type-specific schema."""
    cursor = conn.cursor()
    table_name = class_name
    schema_columns = TABLE_SCHEMAS.get(class_name, [])

    logger.info(f"Importing {class_name} (schema: {len(schema_columns)} columns)...")

    try:
        # Instantiate the asset class and get data
        asset_instance = asset_class_factory()
        df = asset_instance.select()

        # Use DataFrame index as symbol (FinanceDatabase uses index for symbols)
        df = df.reset_index()
        if 'index' in df.columns:
            df = df.rename(columns={'index': 'symbol'})

        # Drop old table and recreate with correct schema
        cursor.execute(f"DROP TABLE IF EXISTS {table_name}")

        col_defs = ['id INTEGER PRIMARY KEY AUTOINCREMENT']
        for col in schema_columns:
            col_defs.append(f'{col} TEXT')
        col_defs.append('created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP')
        cursor.execute(f"CREATE TABLE {table_name} ({', '.join(col_defs)})")

        # Recreate indexes
        for col in TABLE_INDEXES.get(table_name, []):
            cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_{col} ON {table_name}({col})")

        # Determine which schema columns actually exist in the DataFrame
        df_columns = set(df.columns)
        insert_columns = [col for col in schema_columns if col in df_columns]

        # Log any schema columns missing from the DataFrame
        missing = set(schema_columns) - df_columns
        if missing:
            logger.warning(f"  {class_name}: columns in schema but not in data: {missing}")

        # Log any DataFrame columns not in our schema (for future reference)
        extra = df_columns - set(schema_columns) - {'index', 'level_0'}
        if extra:
            logger.info(f"  {class_name}: columns in data but not in schema: {extra}")

        placeholders = ','.join(['?' for _ in insert_columns])
        columns_str = ','.join(insert_columns)

        # Insert data in batches for efficiency
        batch_size = 1000
        total_rows = len(df)

        for i in range(0, total_rows, batch_size):
            batch = df.iloc[i:min(i + batch_size, total_rows)]
            rows = []
            for _, row in batch.iterrows():
                row_data = []
                for col in insert_columns:
                    val = row.get(col)
                    # Convert NaN/None to None, everything else to string
                    if val is None or (isinstance(val, float) and val != val):
                        row_data.append(None)
                    elif not isinstance(val, (str, int, float)):
                        row_data.append(str(val))
                    else:
                        row_data.append(val)
                rows.append(row_data)

            cursor.executemany(
                f"INSERT INTO {table_name} ({columns_str}) VALUES ({placeholders})",
                rows
            )

            if (i + batch_size) % 10000 == 0 or i + batch_size >= total_rows:
                conn.commit()
                logger.info(f"  {class_name}: {min(i + batch_size, total_rows)}/{total_rows} rows inserted")

        logger.info(f"Successfully imported {total_rows} {class_name} ({len(insert_columns)} columns)")
        return total_rows

    except Exception as e:
        logger.error(f"Error importing {class_name}: {e}")
        conn.rollback()
        return 0


def update_metadata(conn):
    """Update metadata with import timestamp, counts, and schema version."""
    cursor = conn.cursor()

    # Get row counts for each table
    counts = {}
    for table_name in ASSET_CLASSES.keys():
        cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
        counts[table_name] = cursor.fetchone()[0]

    # Update metadata
    cursor.execute("""
        INSERT OR REPLACE INTO metadata (key, value, updated_at)
        VALUES (?, ?, ?)
    """, ('last_import', datetime.now().isoformat(), datetime.now()))

    cursor.execute("""
        INSERT OR REPLACE INTO metadata (key, value, updated_at)
        VALUES (?, ?, ?)
    """, ('schema_version', '2', datetime.now()))

    for table_name, count in counts.items():
        cursor.execute("""
            INSERT OR REPLACE INTO metadata (key, value, updated_at)
            VALUES (?, ?, ?)
        """, (f'count_{table_name}', str(count), datetime.now()))

    conn.commit()
    logger.info(f"Metadata updated: {counts}")


def main():
    """Main function to run the import."""
    logger.info(f"Starting FinanceDatabase import to {DB_PATH}")

    # Ensure directory exists
    db_dir = os.path.dirname(DB_PATH)
    if not os.path.exists(db_dir):
        logger.error(f"Database directory does not exist: {db_dir}")
        sys.exit(1)

    # Acquire lock
    try:
        lock_file = acquire_lock(LOCK_PATH)
    except TimeoutError as e:
        logger.error(f"Could not acquire lock: {e}")
        sys.exit(1)

    try:
        # Connect to database
        conn = sqlite3.connect(DB_PATH, timeout=30)

        # Initialize database
        init_database(conn)

        # Import each asset class
        total_imported = 0
        for class_name, asset_class_factory in ASSET_CLASSES.items():
            count = import_asset_class(conn, class_name, asset_class_factory)
            total_imported += count

        # Update metadata
        update_metadata(conn)

        conn.close()
        logger.info(f"Import complete! Total rows imported: {total_imported}")

    except Exception as e:
        logger.error(f"Import failed: {e}")
        sys.exit(1)
    finally:
        release_lock(lock_file)


if __name__ == '__main__':
    main()
