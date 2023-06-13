default_target: local

COMMIT_HASH := $(shell git log -1 --pretty=format:"%h"|tail -1)
VERSION = 0.13.0
IMAGE_REPO ?= ghcr.io/blakeblackshear/frigate
CURRENT_UID := $(shell id -u)
CURRENT_GID := $(shell id -g)

JETPACK4_BASE ?= timongentzsch/l4t-ubuntu20-opencv:latest
JETPACK5_BASE ?= nvcr.io/nvidia/l4t-tensorrt:r8.4.1-runtime
JETPACK4_ARGS := --build-arg BASE_IMAGE=$(JETPACK4_BASE) --build-arg SLIM_BASE=$(JETPACK4_BASE)
JETPACK5_ARGS := --build-arg BASE_IMAGE=$(JETPACK5_BASE) --build-arg SLIM_BASE=$(JETPACK5_BASE)

version:
	echo 'VERSION = "$(VERSION)-$(COMMIT_HASH)"' > frigate/version.py

local: version
	docker buildx build --target=frigate --tag frigate:latest --load .

local-trt: version
	docker buildx build --target=frigate-tensorrt --tag frigate:latest-tensorrt --load .

amd64:
	docker buildx build --platform linux/amd64 --target=frigate --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH) .
	docker buildx build --platform linux/amd64 --target=frigate-tensorrt --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH)-tensorrt .

arm64:
	docker buildx build --platform linux/arm64 --target=frigate --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH) .

jetson-jetpack4: version
	docker buildx build --platform linux/arm64 --target=frigate-jetson --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH)-jetson-jetpack4 $(JETPACK4_ARGS) .

jetson-jetpack4-models:
	docker buildx build --platform linux/arm64 --target=jetson-trt-models --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH)-jetson-jetpack4-models $(JETPACK4_ARGS) .

jetson-jetpack5: version
	docker buildx build --platform linux/arm64 --target=frigate-jetson --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH)-jetson-jetpack5 $(JETPACK5_ARGS) .

jetson-jetpack5-models:
	docker buildx build --platform linux/arm64 --target=jetson-trt-models --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH)-jetson-jetpack5-models $(JETPACK5_ARGS) .

build: version amd64 arm64 jetson-jetpack4 jetson-jetpack5
	docker buildx build --platform linux/arm64/v8,linux/amd64 --target=frigate --tag $(IMAGE_REPO):$(VERSION)-$(COMMIT_HASH) .

push: build
	docker buildx build --push --platform linux/arm64/v8,linux/amd64 --target=frigate --tag $(IMAGE_REPO):${GITHUB_REF_NAME}-$(COMMIT_HASH) .
	docker buildx build --push --platform linux/amd64 --target=frigate-tensorrt --tag $(IMAGE_REPO):${GITHUB_REF_NAME}-$(COMMIT_HASH)-tensorrt .
	docker buildx build --push --platform linux/arm64 --target=frigate-jetson --tag $(IMAGE_REPO):$(GITHUB_REF_NAME)-$(COMMIT_HASH)-jetson-jetpack4 $(JETPACK4_ARGS) .
	docker buildx build --push --platform linux/arm64 --target=frigate-jetson --tag $(IMAGE_REPO):$(GITHUB_REF_NAME)-$(COMMIT_HASH)-jetson-jetpack5 $(JETPACK5_ARGS) .

run: local
	docker run --rm --publish=5000:5000 --volume=${PWD}/config:/config frigate:latest

run_tests: local
	docker run --rm --workdir=/opt/frigate --entrypoint= frigate:latest python3 -u -m unittest
	docker run --rm --workdir=/opt/frigate --entrypoint= frigate:latest python3 -u -m mypy --config-file frigate/mypy.ini frigate

.PHONY: run_tests
