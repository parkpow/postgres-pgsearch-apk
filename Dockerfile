# syntax=docker/dockerfile:1

ARG PG_MAJOR=18.6
ARG PARADEDB_VERSION=0.27.0

# Stage 1: Compile ParadeDB pg_search against official PostgreSQL Alpine and package as signed .apk
FROM postgres:${PG_MAJOR}-alpine AS builder

ARG PG_MAJOR
ARG PARADEDB_VERSION

RUN apk add --no-cache \
    abuild \
    bash \
    build-base \
    ca-certificates \
    clang \
    clang-dev \
    cmake \
    curl \
    git \
    icu-dev \
    libxml2-dev \
    lld \
    llvm-dev \
    openblas-dev \
    openssl \
    openssl-dev \
    perl \
    pkgconf \
    readline-dev \
    zlib-dev

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}" \
    LIBCLANG_PATH="/usr/lib" \
    RUSTFLAGS="-C target-feature=-crt-static"

RUN git clone --depth 1 --branch "v${PARADEDB_VERSION}" https://github.com/paradedb/paradedb.git /usr/src/paradedb

WORKDIR /usr/src/paradedb

RUN PG_MAJOR_NUM="${PG_MAJOR%%.*}" \
    && PGRX_VERSION=$(sed -nE 's/^pgrx[[:space:]]*=[^"]*"=?([0-9]+\.[0-9]+\.[0-9]+[^"]*)".*/\1/p' Cargo.toml | head -n 1) \
    && test -n "${PGRX_VERSION}" \
    && cargo install --locked cargo-pgrx --version "${PGRX_VERSION}" \
    && cargo pgrx init "--pg${PG_MAJOR_NUM}" "$(which pg_config)"

WORKDIR /usr/src/paradedb/pg_search

RUN PG_MAJOR_NUM="${PG_MAJOR%%.*}" \
    && cargo pgrx package \
        --pg-config "$(which pg_config)" \
        --no-default-features \
        --features "pg${PG_MAJOR_NUM}" \
        --out-dir /usr/src/pkg-stage

# ParadeDB pg_search requires the pgvector ("vector") extension; build latest release from GitHub source
ARG PGVECTOR_VERSION=0.8.7
RUN mkdir -p /usr/src/pgvector \
    && curl -fsSL "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/src/pgvector \
    && make -C /usr/src/pgvector OPTFLAGS="" with_llvm=no \
    && make -C /usr/src/pgvector install DESTDIR=/usr/src/pkg-stage with_llvm=no

RUN ARCH="$(apk --print-arch)" \
    && mkdir -p /root/.abuild \
    && openssl genrsa -out "/root/.abuild/postgres-pgsearch-${ARCH}.rsa" 4096 \
    && openssl rsa -in "/root/.abuild/postgres-pgsearch-${ARCH}.rsa" -pubout -out "/root/.abuild/postgres-pgsearch-${ARCH}.rsa.pub" \
    && chmod 600 "/root/.abuild/postgres-pgsearch-${ARCH}.rsa" \
    && cp "/root/.abuild/postgres-pgsearch-${ARCH}.rsa.pub" "/etc/apk/keys/postgres-pgsearch-${ARCH}.rsa.pub" \
    && printf 'PACKAGER="Plate Recognizer <support@platerecognizer.com>"\nPACKAGER_PRIVKEY="/root/.abuild/postgres-pgsearch-%s.rsa"\n' "${ARCH}" > /root/.abuild/abuild.conf

COPY scripts/APKBUILD.sh /build/main/postgres-pgsearch/APKBUILD

WORKDIR /build/main/postgres-pgsearch

ENV PGSEARCH_STAGE_DIR=/usr/src/pkg-stage \
    PARADEDB_VERSION=${PARADEDB_VERSION} \
    PG_MAJOR=${PG_MAJOR}

RUN abuild -F -d -P /packages

RUN ARCH="$(apk --print-arch)" \
    && APK_PATH="/packages/main/${ARCH}/postgres-pgsearch-${PARADEDB_VERSION}-r0.apk" \
    && INDEX_PATH="/packages/main/${ARCH}/APKINDEX.tar.gz" \
    && PUBKEY="/root/.abuild/postgres-pgsearch-${ARCH}.rsa.pub" \
    && test -f "${APK_PATH}" \
    && test -f "${INDEX_PATH}" \
    && test -f "${PUBKEY}" \
    && mkdir -p /out/packages /out/etc/apk/keys /out/dist \
    && cp -a /packages/main /out/packages/ \
    && cp "${APK_PATH}" /out/postgres-pgsearch.apk \
    && cp "${PUBKEY}" "/out/etc/apk/keys/postgres-pgsearch-${ARCH}.rsa.pub" \
    && cp "${APK_PATH}" "/out/dist/postgres-pgsearch-${PARADEDB_VERSION}-r0-pg${PG_MAJOR}-${ARCH}.apk" \
    && cp "${INDEX_PATH}" "/out/dist/APKINDEX-${ARCH}.tar.gz" \
    && cp "${PUBKEY}" "/out/dist/postgres-pgsearch-${ARCH}.rsa.pub" \
    && (cd /out/dist && sha256sum "postgres-pgsearch-${PARADEDB_VERSION}-r0-pg${PG_MAJOR}-${ARCH}.apk" "APKINDEX-${ARCH}.tar.gz" "postgres-pgsearch-${ARCH}.rsa.pub" > "SHA256SUMS-${ARCH}")

# Stage 2: Install signed APK into clean pgautoupgrade Alpine image and verify BM25 queries
FROM pgautoupgrade/pgautoupgrade:${PG_MAJOR}-alpine AS test

COPY --from=builder /out/etc/apk/keys/ /etc/apk/keys/
COPY --from=builder /out/packages/ /tmp/packages/

RUN apk add --no-cache --repository /tmp/packages/main postgres-pgsearch \
    && rm -rf /tmp/packages

COPY scripts/test-extension.sh /usr/local/bin/test-extension.sh
RUN chmod +x /usr/local/bin/test-extension.sh \
    && /usr/local/bin/test-extension.sh

# Stage 3: Minimal scratch image containing GitHub Release artifacts (extract via buildx --output)
FROM scratch AS artifacts
COPY --from=builder /out/dist/ /

# Stage 4: Default minimal scratch image containing the APK, signed Alpine repo, and public key
FROM scratch AS package
COPY --from=builder /out/postgres-pgsearch.apk /postgres-pgsearch.apk
COPY --from=builder /out/packages/ /packages/
COPY --from=builder /out/etc/apk/keys/ /etc/apk/keys/
