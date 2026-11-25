.DEFAULT_GOAL := help
CONFIG ?= debug
export CONFIG

.PHONY: help dev test build clean

help:
	@printf '%s\n' \
		'make build [CONFIG=debug|release]  构建 Clipboard.app（开发版或发布版）' \
		'make dev                           构建并运行开发版 Clipboard Dev.app' \
		'make test                          运行单元测试与集成测试' \
		'make clean                         清理构建产物与本地缓存'

build:
	@./scripts/build.sh "$(CONFIG)"

dev:
	@./scripts/run.sh

test:
	@./scripts/test.sh

clean:
	@rm -rf .build dist
