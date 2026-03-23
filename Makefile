COMPOSE_FILE := docker-compose.yaml
ENV_FILE := .env
DOCKER_COMPOSE := docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)
WORKER_REPLICAS ?= 1
N ?= $(WORKER_REPLICAS)
SUBCMD := $(word 2,$(MAKECMDGOALS))

.PHONY: help
help:
	@echo "Ray Cluster Experiment"
	@echo ""
	@echo "make ray up [N=2]                          Start cluster and scale workers"
	@echo "make ray down                              Stop and remove cluster"
	@echo "make ray status                            Show Ray cluster status"
	@echo "make ray logs                              Tail head + worker logs"
	@echo "make ray dashboard                         Print dashboard URL"
	@echo "make ray job FILE=jobs/demo_job.py         Submit local Python file as Ray job"
	@echo "make ray job FILE=jobs/demo_job.py ARGS='--x 1'   Submit with script args"

.PHONY: env
env:
	@if [ ! -f "$(ENV_FILE)" ]; then \
		cp .env.example $(ENV_FILE); \
		echo "Created $(ENV_FILE) from .env.example"; \
	else \
		echo "$(ENV_FILE) already exists"; \
	fi

.PHONY: ray
ray: env
	@set -e; \
	case "$(SUBCMD)" in \
		up) \
			SCALE="$(N)"; \
			echo "Starting Ray cluster (workers=$$SCALE)..."; \
			$(DOCKER_COMPOSE) up -d --scale ray-worker=$$SCALE ray-head ray-worker; \
			;; \
		down) \
			echo "Stopping Ray cluster..."; \
			$(DOCKER_COMPOSE) down; \
			;; \
		status) \
			$(DOCKER_COMPOSE) exec ray-head ray status; \
			;; \
		logs) \
			$(DOCKER_COMPOSE) logs -f ray-head ray-worker; \
			;; \
		dashboard) \
			DASH_PORT=$$(grep -E '^RAY_DASHBOARD_PORT=' $(ENV_FILE) | cut -d'=' -f2); \
			if [ -z "$$DASH_PORT" ]; then DASH_PORT=8265; fi; \
			echo "Ray Dashboard: http://localhost:$$DASH_PORT"; \
			;; \
		job) \
			if [ -z "$(FILE)" ]; then \
				echo "Usage: make ray job FILE=/absolute/or/relative/path.py [ARGS='...']"; \
				exit 1; \
			fi; \
			if [ ! -f "$(FILE)" ]; then \
				echo "File not found: $(FILE)"; \
				exit 1; \
			fi; \
			BASENAME=$$(basename "$(FILE)"); \
			REMOTE_DIR=/tmp/ray_jobs; \
			REMOTE_PATH=$$REMOTE_DIR/$$BASENAME; \
			echo "Submitting job from: $(FILE)"; \
			$(DOCKER_COMPOSE) exec ray-head mkdir -p $$REMOTE_DIR; \
			$(DOCKER_COMPOSE) cp "$(FILE)" ray-head:$$REMOTE_PATH; \
			$(DOCKER_COMPOSE) exec ray-head ray job submit \
				--address=http://127.0.0.1:8265 \
				-- python $$REMOTE_PATH $(ARGS); \
			;; \
		""|help) \
			$(MAKE) help; \
			;; \
		*) \
			echo "Unknown subcommand: $(SUBCMD)"; \
			echo "Run: make ray help"; \
			exit 1; \
			;; \
	esac

# Dummy targets so `make ray up`/`make ray down` style works cleanly.
.PHONY: up down status logs dashboard job
up down status logs dashboard job:
	@:
