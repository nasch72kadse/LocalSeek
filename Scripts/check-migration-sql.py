#!/usr/bin/env python3
"""Exercise the actual v6/v7 SQL against a minimal prior-schema fixture.

This supplements XCTest; it does not exercise Swift/GRDB migration registration.
Only the raw SQL literals are extracted, with the four trigger substitutions.
"""
from pathlib import Path
import json
import re
import sqlite3

source = (Path(__file__).resolve().parents[1] / "Shared/Persistence/IndexDatabase.swift").read_text()
v6 = source.split('registerMigration("v6-incremental-indexing")', 1)[1].split('registerMigration("v7-vector-change-log")', 1)[0]
v7 = source.split('registerMigration("v7-vector-change-log")', 1)[1].split("return migrator", 1)[0]
sql6 = re.findall(r'db.execute\(sql: """(.*?)"""\)', v6, re.S)
sql7 = re.findall(r'db.execute\(sql: """(.*?)"""\)', v7, re.S)
assert len(sql6) == 1 and len(sql7) == 2
db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")
db.executescript("""
CREATE TABLE sources(id TEXT PRIMARY KEY);
CREATE TABLE files(id INTEGER PRIMARY KEY, sourceId TEXT REFERENCES sources(id) ON DELETE CASCADE,
 filename TEXT, relativePath TEXT, size INTEGER, mtime REAL);
CREATE VIRTUAL TABLE filename_fts USING fts5(filename, relativePath, content='files', content_rowid='id');
CREATE TABLE chunk_vectors_v1(chunkId INTEGER PRIMARY KEY, modelId TEXT, embedding BLOB);
INSERT INTO sources VALUES('s');
INSERT INTO files VALUES(1,'s','old.txt','a/old.txt',10,1);
INSERT INTO filename_fts(rowid,filename,relativePath) VALUES(1,'old.txt','a/old.txt');
""")
db.executescript(sql6[0])
before = db.total_changes
db.execute("UPDATE files SET size=20 WHERE id=1")
assert db.total_changes - before == 1, "metadata must not rewrite FTS"
db.execute("UPDATE files SET filename='new.txt',relativePath='a/new.txt' WHERE id=1")
assert db.execute("SELECT rowid FROM filename_fts WHERE filename_fts MATCH 'new'").fetchall() == [(1,)]
assert not db.execute("SELECT rowid FROM filename_fts WHERE filename_fts MATCH 'old'").fetchall()
db.execute("INSERT INTO ocr_cache VALUES(1,'key',X'1234',2,1)")
db.execute("UPDATE ocr_cache SET byteCount=5 WHERE fileId=1")
assert db.execute("SELECT bytes FROM ocr_cache_budget").fetchone() == (5,)
db.execute("DELETE FROM sources WHERE id='s'")
assert db.execute("SELECT bytes FROM ocr_cache_budget").fetchone() == (0,)
db.executescript(sql7[0])
triggers = re.findall(r'\("([a-z_]+)", "([^"]+)", "([^"]*)", "(new|old)"\)', v7)
assert len(triggers) == 4
for name, operation, condition, row in triggers:
    sql = sql7[1]
    for key, value in dict(name=name, operation=operation, condition=condition, row=row).items():
        sql = sql.replace('\\(' + key + ')', value)
    db.executescript(sql)
db.execute("INSERT INTO chunk_vectors_v1 VALUES(1,'m',X'1234')")
assert db.execute("SELECT * FROM vector_state").fetchall() == [('m', 1)]
assert not db.execute("SELECT * FROM vector_changes").fetchall()
db.execute("INSERT INTO vector_tracking VALUES('m',1)")
db.execute("UPDATE chunk_vectors_v1 SET embedding=X'5678' WHERE chunkId=1")
assert db.execute("SELECT * FROM vector_changes").fetchall() == [('m', 2, 1)]
db.execute("UPDATE chunk_vectors_v1 SET modelId='other' WHERE chunkId=1")
assert dict(db.execute("SELECT * FROM vector_state")) == {'m': 3, 'other': 1}
assert db.execute("SELECT * FROM vector_changes ORDER BY sequence").fetchall() == [('m', 2, 1), ('m', 3, 1)]
db.execute("INSERT INTO vector_tracking VALUES('other',1)")
db.execute("DELETE FROM chunk_vectors_v1 WHERE chunkId=1")
assert db.execute("SELECT revision FROM vector_state WHERE modelId='other'").fetchone() == (2,)
assert db.execute("SELECT sequence FROM vector_changes WHERE modelId='other'").fetchone() == (2,)
# Overflow advances the authoritative revision while the journal stays bounded.
db.execute("UPDATE vector_state SET revision=100001 WHERE modelId='m'")
db.execute("INSERT INTO chunk_vectors_v1 VALUES(2,'m',X'1234')")
assert db.execute("SELECT revision FROM vector_state WHERE modelId='m'").fetchone() == (100002,)
assert db.execute("SELECT COUNT(*) FROM vector_changes WHERE modelId='m'").fetchone() == (2,)
print(json.dumps(dict(rawMigrationSQLPassed=True, triggers=len(triggers), sqlite=sqlite3.sqlite_version,
                     scope="v6/v7 raw SQL; minimal fixture; not Swift/GRDB integration")))
