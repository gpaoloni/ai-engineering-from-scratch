# Shortcuts for the Docker learning environment. See DOCKER.md.
.DEFAULT_GOAL := help
.PHONY: help build rebuild run jupyter

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image (reuses cached layers)
	docker compose build

rebuild: ## Rebuild from scratch to pick up the latest Python and Node
	docker compose build --no-cache

run: ## Open a shell in a throwaway container
	docker compose run --rm aiefs

jupyter: ## Start JupyterLab on 127.0.0.1:8888 (uses JUPYTER_TOKEN or generates one)
	@token="$${JUPYTER_TOKEN:-$$(openssl rand -hex 24)}"; \
	echo "JupyterLab: http://127.0.0.1:8888/lab?token=$$token"; \
	JUPYTER_TOKEN="$$token" docker compose --profile jupyter up jupyter
