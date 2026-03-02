SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# --- Project / Registry ---
DOCKER_REGISTRY ?= harbor.remystorage.ru
DOCKER_ORG      ?= remystorage
IMAGE_NAME      ?= stooge-router

DOCKER_IMAGE    := $(DOCKER_REGISTRY)/$(DOCKER_ORG)/$(IMAGE_NAME)

# Version/tagging
VERSION_FILE ?= VERSION
VERSION ?= $(shell test -f $(VERSION_FILE) && cat $(VERSION_FILE) || git rev-parse --short HEAD)
TAG ?= $(VERSION)

# Build options
DOCKER_BUILD_FLAGS ?=
DOCKER_BUILDKIT ?= 1
export DOCKER_BUILDKIT

# Dockerfile
DOCKERFILE ?= Dockerfile

# --- Python / tooling ---
PY ?= python
PIP ?= pip

# --- i18n / Babel ---
DOMAIN ?= bot
LOCALES_DIR ?= src/locales
POT_FILE ?= $(LOCALES_DIR)/$(DOMAIN).pot
LOCALES := ru en zh_Hans pt_BR fr es ar

# --- Alembic ---
ALEMBIC ?= alembic

# --- Kubernetes ---
K8S_NS  ?= stooge
KUBECTL ?= kubectl
K8S_DIR ?= k3s/stooge-router

.PHONY: help
help: ## Show help
	@echo "Usage: make <target>"
	@echo ""
	@awk -F ':|##' '/^[a-zA-Z0-9_.-]+:.*?##/ { printf "  %-24s %s\n", $$1, $$NF }' $(MAKEFILE_LIST)

# -------------------------
# Docker: build/push/clean
# -------------------------

.PHONY: build
build: ## Build single Docker image
	@echo "==> Building $(DOCKER_IMAGE):$(TAG)"
	docker build $(DOCKER_BUILD_FLAGS) \
		-f $(DOCKERFILE) \
		--build-arg VERSION=$(VERSION) \
		-t $(DOCKER_IMAGE):$(TAG) \
		-t $(DOCKER_IMAGE):latest \
		.

.PHONY: push
push: ## Push single Docker image
	@echo "==> Pushing $(DOCKER_IMAGE):$(TAG)"
	docker push $(DOCKER_IMAGE):$(TAG)
	docker push $(DOCKER_IMAGE):latest

.PHONY: all
all: build push ## Build and push

.PHONY: clean
clean: ## Remove local Docker images
	@echo "==> Removing local images $(DOCKER_IMAGE):$(TAG) and :latest"
	docker rmi $(DOCKER_IMAGE):$(TAG) || true
	docker rmi $(DOCKER_IMAGE):latest || true

.PHONY: docker-login
docker-login: ## Docker login (interactive)
	docker login $(DOCKER_REGISTRY)

.PHONY: run
run: build ## Build and run locally (override CMD if needed)
	docker run --rm -it $(DOCKER_IMAGE):$(TAG)

# -------------------------
# Dev: install/lint/test
# -------------------------

.PHONY: install
install: ## Install deps (pip)
	$(PIP) install -U pip
	$(PIP) install -r requirements.txt

.PHONY: test
test: ## Run tests
	pytest -q

.PHONY: lint
lint: ## Lint (ruff)
	ruff check .

.PHONY: fmt
fmt: ## Format (ruff format)
	ruff format .

# -------------------------
# i18n (pybabel)
# -------------------------

.PHONY: i18n-extract
i18n-extract: ## Extract messages -> .pot
	@mkdir -p $(LOCALES_DIR)
	pybabel extract -F babel.cfg -o $(POT_FILE) src
	@echo "==> POT updated: $(POT_FILE)"

.PHONY: i18n-update
i18n-update: i18n-extract ## Update all locales from .pot
	@for loc in $(LOCALES); do \
		echo "==> Updating locale $$loc"; \
		pybabel update -i $(POT_FILE) -d $(LOCALES_DIR) -D $(DOMAIN) -l $$loc || true; \
	done

.PHONY: i18n-init
i18n-init: i18n-extract ## Init locales if not exist
	@for loc in $(LOCALES); do \
		if [ ! -d "$(LOCALES_DIR)/$$loc" ]; then \
			echo "==> Initializing locale $$loc"; \
			pybabel init -i $(POT_FILE) -d $(LOCALES_DIR) -D $(DOMAIN) -l $$loc; \
		else \
			echo "==> Locale $$loc already exists"; \
		fi; \
	done

.PHONY: i18n-compile
i18n-compile: ## Compile .po -> .mo
	pybabel compile -d $(LOCALES_DIR) -D $(DOMAIN)
	@echo "==> Compiled locales in $(LOCALES_DIR)"

# -------------------------
# Alembic
# -------------------------

.PHONY: db-current
db-current: ## Show current alembic revision
	$(ALEMBIC) current

.PHONY: db-up
db-up: ## Upgrade to head
	$(ALEMBIC) upgrade head

.PHONY: db-down
db-down: ## Downgrade one revision (usage: make db-down REV=-1)
	$(ALEMBIC) downgrade $(REV)

.PHONY: db-rev
db-rev: ## Create new revision (usage: make db-rev MSG="my change")
	$(ALEMBIC) revision -m "$(MSG)" --autogenerate

# -------------------------
# Kubernetes helpers
# -------------------------

.PHONY: k-get
k-get: ## Get pods in namespace
	$(KUBECTL) get pods -n $(K8S_NS)

.PHONY: k-logs
k-logs: ## Tail logs (usage: make k-logs POD=schedbridge-worker-xxx)
	$(KUBECTL) logs -n $(K8S_NS) -f $(POD)

.PHONY: k-restart
k-restart: ## Restart deployment (usage: make k-restart DEP=schedbridge-worker)
	$(KUBECTL) rollout restart -n $(K8S_NS) deploy/$(DEP)

.PHONY: k-apply
k-apply: ## Apply manifests from K8S_DIR
	$(KUBECTL) apply -n $(K8S_NS) -f $(K8S_DIR)

# -------------------------
# Version management
# -------------------------

.PHONY: version
version: ## Print version
	@echo $(VERSION)

.PHONY: bump-version
bump-version: ## Bump version (usage: make bump-version NEW=1.0.2)
	@test -n "$(NEW)" || (echo "Set NEW=..."; exit 1)
	@echo "$(NEW)" > $(VERSION_FILE)
	@echo "==> Version bumped to $(NEW)"
