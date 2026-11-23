# Maintainer: Plate Recognizer <support@platerecognizer.com>
# Alpine APKBUILD for ParadeDB pg_search compiled against official PostgreSQL Alpine (/usr/local)

_pg_ver="${PG_MAJOR:-18.6}"
_pg_major="${_pg_ver%%.*}"

pkgname="postgres-pgsearch"
pkgver="${PARADEDB_VERSION:-0.27.0}"
pkgrel=0
pkgdesc="ParadeDB pg_search: BM25 full-text search extension for PostgreSQL ${_pg_ver}"
url="https://github.com/paradedb/paradedb"
arch="x86_64 aarch64"
license="AGPL-3.0-only"
depends="libgcc"
provides="postgresql-pgsearch=$pkgver-r$pkgrel postgresql${_pg_major}-pgsearch=$pkgver-r$pkgrel"
# !fhs is required because official postgres/pgautoupgrade Alpine images install
# PostgreSQL under /usr/local/lib/postgresql and /usr/local/share/postgresql.
options="!fhs !check"
source=""

build() {
	local pg_major="${_pg_major}"
	local pg_config_bin

	if [ -n "${PGSEARCH_STAGE_DIR:-}" ] && [ -d "$PGSEARCH_STAGE_DIR/usr" ]; then
		msg "Using pre-staged pg_search artifacts from $PGSEARCH_STAGE_DIR"
		return 0
	fi

	pg_config_bin="$(command -v pg_config)"
	if [ -z "$pg_config_bin" ]; then
		error "pg_config not found in PATH"
		return 1
	fi

	mkdir -p "$builddir"
	rm -rf "$builddir/paradedb" "$builddir/pkg-stage"

	git clone --depth 1 --branch "v$pkgver" \
		https://github.com/paradedb/paradedb.git "$builddir/paradedb"

	cd "$builddir/paradedb"

	local pgrx_version
	pgrx_version="$(sed -nE 's/^pgrx[[:space:]]*=[^"]*"=?([0-9]+\.[0-9]+\.[0-9]+[^"]*)".*/\1/p' Cargo.toml | head -n 1)"
	if [ -z "$pgrx_version" ]; then
		error "Could not determine pgrx version from Cargo.toml"
		return 1
	fi

	if ! cargo pgrx --version 2>/dev/null | grep -q "cargo-pgrx $pgrx_version"; then
		cargo install --locked cargo-pgrx --version "$pgrx_version"
	fi

	cargo pgrx init "--pg${pg_major}" "$pg_config_bin"

	cd "$builddir/paradedb/pg_search"
	RUSTFLAGS="${RUSTFLAGS:--C target-feature=-crt-static}" \
	LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib}" \
	cargo pgrx package \
		--pg-config "$pg_config_bin" \
		--no-default-features \
		--features "pg${pg_major}" \
		--out-dir "$builddir/pkg-stage"
}

package() {
	local stage_dir="${PGSEARCH_STAGE_DIR:-$builddir/pkg-stage}"

	if [ ! -d "$stage_dir/usr" ]; then
		error "Staged pg_search directory not found: $stage_dir/usr"
		return 1
	fi

	mkdir -p "$pkgdir"
	cp -a "$stage_dir/usr" "$pkgdir/"

	test -f "$pkgdir/usr/local/lib/postgresql/pg_search.so"
	test -f "$pkgdir/usr/local/share/postgresql/extension/pg_search.control"
	test -f "$pkgdir/usr/local/lib/postgresql/vector.so"
	test -f "$pkgdir/usr/local/share/postgresql/extension/vector.control"
}
