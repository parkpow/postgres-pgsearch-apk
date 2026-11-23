#!/bin/sh
set -eu

PKG_NAME="postgres-pgsearch"
SO_PATH="/usr/local/lib/postgresql/pg_search.so"
CONTROL_PATH="/usr/local/share/postgresql/extension/pg_search.control"
PGDATA_TEST="/tmp/pgtest-data"
PGRUN_TEST="/tmp/pgtest-run"
PGLOG_TEST="/tmp/pgtest.log"

run_as_postgres() {
	if command -v su-exec >/dev/null 2>&1; then
		su-exec postgres sh -c "$1"
	else
		su -s /bin/sh postgres -c "$1"
	fi
}

cleanup() {
	if [ -d "$PGDATA_TEST" ] && [ -f "$PGDATA_TEST/postmaster.pid" ]; then
		run_as_postgres "pg_ctl -D '$PGDATA_TEST' -m fast stop" >/dev/null 2>&1 || true
	fi
	rm -rf "$PGDATA_TEST" "$PGRUN_TEST" "$PGLOG_TEST"
}
trap cleanup EXIT

echo "=== 1. Verify apk package ownership and installed files ==="
apk info -e "$PKG_NAME"
PKG_FILES="$(apk info -L "$PKG_NAME")"
echo "$PKG_FILES"

test -f "$SO_PATH"
test -f "$CONTROL_PATH"
echo "$PKG_FILES" | grep -q "usr/local/lib/postgresql/pg_search.so"
echo "$PKG_FILES" | grep -q "usr/local/share/postgresql/extension/pg_search.control"

echo "=== 2. Verify shared library dependencies via ldd ==="
# Note: musl ldd prints relocation errors for postgres backend symbols when
# inspecting a loadable .so outside the postgres process, so check specifically
# for missing shared libraries rather than raw exit code.
LDD_OUT="$(ldd "$SO_PATH" 2>&1 || true)"
echo "$LDD_OUT" | grep -v "^Error relocating .*: symbol not found$" || true
if echo "$LDD_OUT" | grep -Eq "=> not found|Error loading shared library"; then
	echo "ERROR: Unresolved shared library dependency detected for $SO_PATH" >&2
	exit 1
fi

echo "=== 3. Initialize temporary PostgreSQL cluster and test pg_search ==="
rm -rf "$PGDATA_TEST" "$PGRUN_TEST" "$PGLOG_TEST"
mkdir -p "$PGDATA_TEST" "$PGRUN_TEST"
chown -R postgres:postgres "$PGDATA_TEST" "$PGRUN_TEST"

run_as_postgres "initdb -D '$PGDATA_TEST' --username=postgres --auth=trust >/dev/null"

if ! run_as_postgres "pg_ctl -D '$PGDATA_TEST' -l '$PGLOG_TEST' -w -o \"-h '' -k '$PGRUN_TEST' -c shared_preload_libraries=pg_search\" start"; then
	echo "ERROR: PostgreSQL failed to start with shared_preload_libraries=pg_search" >&2
	cat "$PGLOG_TEST" >&2 || true
	exit 1
fi

EXT_VERSION="$(run_as_postgres "psql -h '$PGRUN_TEST' -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <<'SQL'
CREATE EXTENSION pg_search CASCADE;
SELECT extversion FROM pg_extension WHERE extname = 'pg_search';
SQL
")"
echo "Loaded pg_search extension version: $EXT_VERSION"
test -n "$EXT_VERSION"

SEARCH_RESULT="$(run_as_postgres "psql -h '$PGRUN_TEST' -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt <<'SQL'
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL
);

INSERT INTO documents (title, body) VALUES
    ('Intro', 'PostgreSQL relational database engine'),
    ('Search', 'ParadeDB provides fast BM25 full-text search inside Postgres'),
    ('Alpine', 'Lightweight musl container runtime');

CREATE INDEX documents_search_idx ON documents
USING bm25 (id, title, body);

SELECT id || '|' || title
FROM documents
WHERE body @@@ 'paradedb'
ORDER BY id;
SQL
")"

echo "BM25 query result: $SEARCH_RESULT"
if [ "$SEARCH_RESULT" != "2|Search" ]; then
	echo "ERROR: Expected '2|Search', got '$SEARCH_RESULT'" >&2
	cat "$PGLOG_TEST" >&2 || true
	exit 1
fi

echo "=== 4. Stop temporary cluster ==="
run_as_postgres "pg_ctl -D '$PGDATA_TEST' -m fast stop"

echo "All pg_search APK verification checks passed!"
