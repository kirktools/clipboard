.DEFAULT_GOAL := help
CONFIG ?= debug
BUMP ?= patch
export CONFIG BUMP

.PHONY: help dev test check build package release-dry-run release signing-prepare signing-ci clean

help:
	@printf '%s\n' \
		'make dev                                 构建并重启当前工作区的开发版 Clipboard Dev.app' \
		'make test                                运行单元测试与集成测试' \
		'make check                               运行脚本语法、Info.plist、diff 与编译检查' \
		'make build [CONFIG=debug|release]        仅构建应用包（默认 debug）' \
		'make package                             生成本地 Release 安装包（DMG/ZIP/清单，不发布）' \
		'make release-dry-run [BUMP=patch|minor|major]  仅预览版本递增与本地发布条件' \
		'make release [BUMP=patch|minor|major]    执行正式版本提交、打标签与推送' \
		'make signing-prepare                     在本机生成项目专用固定发布证书（不上传）' \
		'make signing-ci                          将固定发布证书上传到 GitHub Actions Secrets' \
		'make clean                               清理构建产物与本地缓存'

dev:
	@./scripts/run.sh

test:
	@./scripts/test.sh

check:
	@./scripts/check.sh

build:
	@./scripts/build.sh "$(CONFIG)"

package:
	@./scripts/package.sh

release-dry-run:
	@python3 scripts/release.py --dry-run

release:
	@python3 scripts/release.py

signing-prepare:
	@python3 scripts/release-signing.py prepare

signing-ci:
	@python3 scripts/release-signing.py upload

clean:
	@rm -rf .build dist
