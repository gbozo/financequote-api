#!/usr/bin/env python3
"""
FinanceDatabase to SQLite importer.
Creates/updates an SQLite database with data from the FinanceDatabase package.
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
DB_PATH = os.environ.get('FINANCE_DB_PATH', '/tmp/finance_database.db')
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


def acquire_lock(lock_file, timeout=30):
    """Acquire an exclusive lock with timeout."""
    start_time = time.time()
    while True:
        try:
            fd = open(lock_file, 'w')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except (IOError, OSError):
            if time.time() - start_time > timeout:
                raise TimeoutError(f"Could not acquire lock after {timeout}s")
            time.sleep(0.5)


def release_lock(lock_file):
    """Release the lock."""
    try:
        fcntl.flock(lock_file, fcntl.LOCK_UN)
        lock_file.close()
    except Exception as e:
        logger.warning(f"Error releasing lock: {e}")


def init_database(conn):
    """Initialize database with proper settings for concurrent access."""
    cursor = conn.cursor()
    
    # Enable WAL mode for better concurrent read/write handling
    cursor.execute("PRAGMA journal_mode=WAL")
    
    # Set busy timeout (30 seconds) to handle concurrent access
    cursor.execute("PRAGMA busy_timeout=30000")
    
    # Synchronous mode - NORMAL is a good balance of safety and speed
    cursor.execute("PRAGMA synchronous=NORMAL")
    
    # Create tables for each asset class
    for table_name in ASSET_CLASSES.keys():
        cursor.execute(f"""
            CREATE TABLE IF NOT EXISTS {table_name} (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                symbol TEXT,
                name TEXT,
                summary TEXT,
                currency TEXT,
                sector TEXT,
                industry_group TEXT,
                industry TEXT,
                exchange TEXT,
                market TEXT,
                country TEXT,
                state TEXT,
                city TEXT,
                zipcode TEXT,
                website TEXT,
                market_cap TEXT,
                isin TEXT,
                cusip TEXT,
                figi TEXT,
                composite_figi TEXT,
                shareclass_figi TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        
        # Create indexes for common queries
        cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_symbol ON {table_name}(symbol)")
        cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_name ON {table_name}(name)")
        cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_country ON {table_name}(country)")
        cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_sector ON {table_name}(sector)")
        cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_{table_name}_exchange ON {table_name}(exchange)")
    
    # Create metadata table to track updates
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    conn.commit()
    logger.info("Database initialized with WAL mode and proper indexes")


def import_asset_class(conn, class_name, asset_class_factory):
    """Import data from a single asset class."""
    cursor = conn.cursor()
    table_name = class_name
    
    logger.info(f"Importing {class_name}...")
    
    try:
        # Instantiate the asset class and get data
        asset_instance = asset_class_factory()
        df = asset_instance.select()
        
        # Clear existing data and reset autoincrement
        cursor.execute(f"DELETE FROM {table_name}")
        cursor.execute(f"DELETE FROM sqlite_sequence WHERE name='{table_name}'")
        
        # Insert data in batches for efficiency
        batch_size = 1000
        total_rows = len(df)
        
        # Get column names that exist in the DataFrame
        df_columns = set(df.columns)
        db_columns = ['symbol', 'name', 'summary', 'currency', 'sector', 'industry_group',
                      'industry', 'exchange', 'market', 'country', 'state', 'city',
                      'zipcode', 'website', 'market_cap', 'isin', 'cusip', 'figi',
                      'composite_figi', 'shareclass_figi']
        
        # Use DataFrame index as symbol (FinanceDatabase uses index for symbols)
        df = df.reset_index()
        if 'index' in df.columns:
            df = df.rename(columns={'index': 'symbol'})
        elif df.index.name:
            df.insert(0, 'symbol', df.index)
        
        # Only include columns that exist in the data
        insert_columns = [col for col in db_columns if col in df_columns or col == 'symbol']
        placeholders = ','.join(['?' for _ in insert_columns])
        columns_str = ','.join(insert_columns)
        
        for i in range(0, total_rows, batch_size):
            batch = df.iloc[i:min(i+batch_size, total_rows)]
            rows = []
            for _, row in batch.iterrows():
                row_data = [row.get(col) for col in insert_columns]
                # Convert any non-serializable types to strings
                row_data = [str(v) if v is not None and not isinstance(v, (str, int, float)) else v for v in row_data]
                rows.append(row_data)
            
            cursor.executemany(
                f"INSERT INTO {table_name} ({columns_str}) VALUES ({placeholders})",
                rows
            )
            
            if (i + batch_size) % 10000 == 0 or i + batch_size >= total_rows:
                conn.commit()
                logger.info(f"  {class_name}: {min(i+batch_size, total_rows)}/{total_rows} rows inserted")
        
        logger.info(f"Successfully imported {total_rows} {class_name}")
        return total_rows
        
    except Exception as e:
        logger.error(f"Error importing {class_name}: {e}")
        conn.rollback()
        return 0


def update_metadata(conn):
    """Update metadata with import timestamp and counts."""
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