PG_MAJOR ?= 18
PARADEDB_VERSION ?= 0.27.0
IMAGE_NAME ?= platerecognizer/postgres-pgsearch-apk
BUILDX_FLAGS ?=

BUILD_ARGS = \
	--build-arg PG_MAJOR=$(PG_MAJOR) \
	--build-arg PARADEDB_VERSION=$(PARADEDB_VERSION)

IMAGE_TAGS = \
	-t $(IMAGE_NAME):pg$(PG_MAJOR)-$(PARADEDB_VERSION) \
	-t $(IMAGE_NAME):pg$(PG_MAJOR)-latest \
	-t $(IMAGE_NAME):latest

.PHONY: build push test test-dist dist clean

build:
	docker buildx build \
		$(BUILD_ARGS) \
		$(BUILDX_FLAGS) \
		--target package \
		--load \
		$(IMAGE_TAGS) \
		.

push:
	docker buildx build \
		$(BUILD_ARGS) \
		$(BUILDX_FLAGS) \
		--target package \
		--push \
		--provenance=false \
		$(IMAGE_TAGS) \
		.

dist:
	rm -rf ./dist
	mkdir -p ./dist
	docker buildx build \
		$(BUILD_ARGS) \
		$(BUILDX_FLAGS) \
		--target artifacts \
		--output type=local,dest=./dist \
		.

test-dist:
	docker run --rm \
		-v "$(CURDIR)/dist:/dist:ro" \
		-v "$(CURDIR)/scripts/test-extension.sh:/usr/local/bin/test-extension.sh:ro" \
		"pgautoupgrade/pgautoupgrade:$(PG_MAJOR)-alpine" \
		sh -eu -c 'cp /dist/postgres-pgsearch.rsa.pub /etc/apk/keys/ && apk add --no-cache /dist/postgres-pgsearch-*.apk && sh /usr/local/bin/test-extension.sh'

test:
	docker buildx build \
		$(BUILD_ARGS) \
		$(BUILDX_FLAGS) \
		--target test \
		--progress=plain \
		.

clean:
	rm -rf ./dist
