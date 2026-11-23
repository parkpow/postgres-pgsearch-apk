# postgres-pgsearch-apk

Signed Alpine `.apk` package for ParadeDB's [`pg_search`](https://github.com/paradedb/paradedb) extension, built for official PostgreSQL Alpine images (`postgres:18-alpine` and `pgautoupgrade/pgautoupgrade:18-alpine`, which install PostgreSQL under `/usr/local`).

## Usage

### From GHCR (Recommended)

```dockerfile
# syntax=docker/dockerfile:1

FROM ghcr.io/parkpow/postgres-pgsearch-apk:pg18-latest AS pgsearch_apk
FROM pgautoupgrade/pgautoupgrade:18-alpine

RUN --mount=type=bind,from=pgsearch_apk,target=/tmp/pgsearch \
    cp /tmp/pgsearch/etc/apk/keys/*.rsa.pub /etc/apk/keys/ \
    && apk add --no-cache --repository /tmp/pgsearch/packages/main postgres-pgsearch

CMD ["postgres", "-c", "shared_preload_libraries=pg_search"]
```

### From GitHub Releases

Download `postgres-pgsearch.rsa.pub` and `postgres-pgsearch-<version>-r0-pg<pg_major>-<arch>.apk` from a `v*` release:

```dockerfile
FROM postgres:18-alpine

ARG PARADEDB_VERSION=0.27.0
ARG PG_MAJOR=18.6

RUN apk add --no-cache --virtual .fetch-deps curl \
    && ARCH="$(apk --print-arch)" \
    && curl -fsSL "https://github.com/parkpow/postgres-pgsearch-apk/releases/download/v${PARADEDB_VERSION}/postgres-pgsearch.rsa.pub" \
        -o /etc/apk/keys/postgres-pgsearch.rsa.pub \
    && curl -fsSL "https://github.com/parkpow/postgres-pgsearch-apk/releases/download/v${PARADEDB_VERSION}/postgres-pgsearch-${PARADEDB_VERSION}-r0-pg${PG_MAJOR}-${ARCH}.apk" \
        -o /tmp/postgres-pgsearch.apk \
    && apk add --no-cache /tmp/postgres-pgsearch.apk \
    && rm -f /tmp/postgres-pgsearch.apk \
    && apk del .fetch-deps
```

## Enable in PostgreSQL

Ensure `shared_preload_libraries = 'pg_search'` is set, then run:

```sql
CREATE EXTENSION IF NOT EXISTS pg_search CASCADE;
```

## Local Development

Requires Docker Buildx. Defaults: `PG_MAJOR=18.6`, `PARADEDB_VERSION=0.27.0`.

```sh
make test   # Build APK, install into pgautoupgrade:18.6-alpine, and run BM25 tests
make build  # Build the scratch package image
make dist   # Extract release files (.apk, APKINDEX.tar.gz, .rsa.pub, SHA256SUMS) into ./dist/
make clean  # Remove ./dist/
```

Override defaults with `make test PARADEDB_VERSION=0.27.0 PG_MAJOR=18.6`.

## Releases

Pushing a `v<version>` tag (for example `v0.27.0`) builds and tests the extension, pushes the package image to GHCR, and publishes the `.apk` assets to GitHub Releases.
