ENV_FILE := .env
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Load local defaults from .env when present.
-include $(ENV_FILE)

SLURM_SCRIPT ?= scripts/slurm/ray_cluster.sbatch
SLURM_JOB_FILE ?= .slurm-ray-jobid
COMPOSE_FILE ?= docker-compose.yaml

DOCKER ?= docker
SBATCH ?= sbatch
SCANCEL ?= scancel
SLURM_SSH ?= ssh

SLURM_LOGIN ?=
SLURM_REMOTE_DIR ?= $(CURDIR)
SLURM_JOB_NAME ?=
SLURM_SYNC ?= 1
SLURM_SYNC_FILES ?= Makefile scripts/slurm/ray_cluster.sbatch .env
SLURM_REMOTE_BYPASS ?=

SUBCMD := $(word 2,$(MAKECMDGOALS))

# All configuration must come from .env, not command-line VAR=value overrides.
ifneq ($(strip $(MAKEOVERRIDES)),)
$(error Command-line variable overrides are not supported. Set values in $(ENV_FILE))
endif

# If running through SSH and SLURM_REMOTE_DIR is empty, use a repo-name path
# relative to remote $HOME. Otherwise, keep local-repo fallback.
ifneq ($(strip $(SLURM_LOGIN)),)
ifeq ($(strip $(SLURM_REMOTE_DIR)),)
SLURM_REMOTE_DIR := $(notdir $(CURDIR))
endif
else
ifeq ($(strip $(SLURM_REMOTE_DIR)),)
SLURM_REMOTE_DIR := $(CURDIR)
endif
endif

.PHONY: help
help:
	@echo "Cluster Workflows"
	@echo ""
	@echo "make docker up                             Start Docker Ray cluster"
	@echo "make docker down                           Stop Docker Ray cluster"
	@echo "make docker status                         Show Docker Ray services"
	@echo "make docker logs                           Tail Docker Ray logs"
	@echo "make docker dashboard                      Print dashboard URL"
	@echo ""
	@echo "make slurm up                              Submit Slurm Ray cluster job"
	@echo "make slurm down                            Cancel tracked Slurm job"
	@echo ""
	@echo "All configuration must be set in .env."

.PHONY: env
env:
	@if [ ! -f "$(ENV_FILE)" ]; then \
		cp .env.example $(ENV_FILE); \
		echo "Created $(ENV_FILE) from .env.example"; \
	else \
		echo "$(ENV_FILE) already exists"; \
	fi

.PHONY: docker
docker:
	@set -e; \
	CMD="$(SUBCMD)"; \
	if [ -z "$$CMD" ]; then \
		echo "Usage: make docker up|down|status|logs|dashboard"; \
		exit 1; \
	fi; \
	if ! ( [ -x "$(DOCKER)" ] || command -v "$(DOCKER)" >/dev/null 2>&1 ); then \
		echo "Error: docker not found (DOCKER=$(DOCKER))."; \
		exit 127; \
	fi; \
	if [ ! -f "$(COMPOSE_FILE)" ]; then \
		echo "Docker compose file not found: $(COMPOSE_FILE)"; \
		exit 1; \
	fi; \
	case "$$CMD" in \
		up) \
			REPLICAS="$(WORKER_REPLICAS)"; \
			if [ -z "$$REPLICAS" ]; then REPLICAS="1"; fi; \
			echo "Starting Docker Ray cluster with $$REPLICAS worker(s)"; \
			$(DOCKER) compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" up -d --scale ray-worker="$$REPLICAS"; \
			echo "Ray dashboard: http://localhost:$(RAY_DASHBOARD_PORT)"; \
			;; \
		down) \
			echo "Stopping Docker Ray cluster"; \
			$(DOCKER) compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" down --remove-orphans; \
			;; \
		status) \
			$(DOCKER) compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" ps; \
			;; \
		logs) \
			$(DOCKER) compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" logs -f; \
			;; \
		dashboard) \
			echo "Ray dashboard: http://localhost:$(RAY_DASHBOARD_PORT)"; \
			;; \
		*) \
			echo "Unknown subcommand: $$CMD"; \
			echo "Usage: make docker up|down|status|logs|dashboard"; \
			exit 1; \
			;; \
	esac

.PHONY: slurm
slurm:
	@set -e; \
	CMD="$(SUBCMD)"; \
	if [ -z "$$CMD" ]; then \
		echo "Usage: make slurm up|down"; \
		exit 1; \
	fi; \
	case "$$CMD" in \
		up|down) ;; \
		*) \
			echo "Unknown subcommand: $$CMD"; \
			echo "Usage: make slurm up|down"; \
			exit 1; \
			;; \
	esac; \
	if [ -n "$(SLURM_LOGIN)" ] && [ -z "$(SLURM_REMOTE_BYPASS)" ]; then \
		case "$(SLURM_LOGIN)" in \
			http://*|https://*) \
				echo "Error: SLURM_LOGIN must be an SSH host (e.g. user@login.cluster.edu), not a URL."; \
				echo "Current value: $(SLURM_LOGIN)"; \
				exit 2; \
				;; \
			*@*@*) \
				echo "Error: SLURM_LOGIN looks malformed (too many '@')."; \
				echo "Use user@host, for example: kbhardwaj6@login-phoenix-slurm.pace.gatech.edu"; \
				echo "Current value: $(SLURM_LOGIN)"; \
				exit 2; \
				;; \
		esac; \
			if [ "$(SLURM_SYNC)" = "1" ]; then \
				if ! command -v tar >/dev/null 2>&1; then \
					echo "Error: tar not found locally."; \
					exit 127; \
				fi; \
				echo "Syncing files to login node: $(SLURM_LOGIN):$(SLURM_REMOTE_DIR)"; \
				$(SLURM_SSH) "$(SLURM_LOGIN)" "mkdir -p \"$(SLURM_REMOTE_DIR)\""; \
				if ! $(SLURM_SSH) "$(SLURM_LOGIN)" "command -v tar >/dev/null 2>&1"; then \
					echo "Error: tar not found on login node."; \
					exit 127; \
				fi; \
				SYNC_LIST=""; \
				for path in $(SLURM_SYNC_FILES); do \
					if [ ! -e "$(REPO_ROOT)/$$path" ]; then \
						echo "Warning: sync path not found locally, skipping: $$path"; \
						continue; \
					fi; \
					SYNC_LIST="$$SYNC_LIST $$path"; \
				done; \
				if [ -z "$$SYNC_LIST" ]; then \
					echo "Warning: no sync paths found; skipping sync."; \
				else \
					echo "Sync list:$$SYNC_LIST"; \
					( cd "$(REPO_ROOT)" && tar -cf - $$SYNC_LIST ) | \
						$(SLURM_SSH) "$(SLURM_LOGIN)" "cd \"$(SLURM_REMOTE_DIR)\" && tar -xf -"; \
				fi; \
			fi; \
		JOB_NAME="$(SLURM_JOB_NAME)"; \
		if [ -z "$$JOB_NAME" ]; then JOB_NAME="ray-$$(date +%Y%m%d-%H%M%S)-$$(printf "%06d" $$RANDOM)"; fi; \
		echo "Using Slurm job name: $$JOB_NAME"; \
		echo "Running Slurm command on login node: $(SLURM_LOGIN)"; \
		$(SLURM_SSH) "$(SLURM_LOGIN)" \
			"cd \"$(SLURM_REMOTE_DIR)\" && env \
SLURM_REMOTE_BYPASS=1 \
SBATCH='$(SBATCH)' \
SCANCEL='$(SCANCEL)' \
SLURM_SCRIPT='$(SLURM_SCRIPT)' \
SLURM_JOB_FILE='$(SLURM_JOB_FILE)' \
SLURM_JOB_NAME='$$JOB_NAME' \
VENV_ACTIVATE='$(VENV_ACTIVATE)' \
PROJECT_ROOT='$(PROJECT_ROOT)' \
UV_BIN='$(UV_BIN)' \
ENTRYPOINT='$(ENTRYPOINT)' \
ENTRYPOINT_ARGS='$(ENTRYPOINT_ARGS)' \
ENTRYPOINT_CMD='$(ENTRYPOINT_CMD)' \
RAY_PORT='$(RAY_PORT)' \
RAY_CLIENT_PORT='$(RAY_CLIENT_PORT)' \
RAY_DASHBOARD_PORT='$(RAY_DASHBOARD_PORT)' \
RAY_LOG_ARCHIVE_DIR='$(RAY_LOG_ARCHIVE_DIR)' \
HEAD_STARTUP_WAIT_SECONDS='$(HEAD_STARTUP_WAIT_SECONDS)' \
WORKER_STARTUP_WAIT_SECONDS='$(WORKER_STARTUP_WAIT_SECONDS)' \
CLUSTER_STABILIZE_WAIT_SECONDS='$(CLUSTER_STABILIZE_WAIT_SECONDS)' \
	make --no-print-directory slurm $$CMD"; \
		exit $$?; \
	fi; \
	case "$$CMD" in \
		up) \
			if ! ( [ -x "$(SBATCH)" ] || command -v "$(SBATCH)" >/dev/null 2>&1 ); then \
				echo "Error: sbatch not found (SBATCH=$(SBATCH))."; \
				echo "Run this command on a Slurm login node, load your Slurm module, or pass SBATCH=/absolute/path/to/sbatch."; \
				exit 127; \
			fi; \
			SCRIPT="$(SLURM_SCRIPT)"; \
			if [ ! -f "$$SCRIPT" ]; then \
				echo "Slurm script not found: $$SCRIPT"; \
				exit 1; \
			fi; \
			JOB_NAME="$(SLURM_JOB_NAME)"; \
			if [ -z "$$JOB_NAME" ]; then JOB_NAME="ray-$$(date +%Y%m%d-%H%M%S)-$$(printf "%06d" $$RANDOM)"; fi; \
			echo "Using Slurm job name: $$JOB_NAME"; \
			echo "Submitting Slurm job: $$SCRIPT"; \
			export VENV_ACTIVATE="$(VENV_ACTIVATE)"; \
			export PROJECT_ROOT="$(PROJECT_ROOT)"; \
			export UV_BIN="$(UV_BIN)"; \
			export ENTRYPOINT="$(ENTRYPOINT)"; \
			export ENTRYPOINT_ARGS="$(ENTRYPOINT_ARGS)"; \
			export ENTRYPOINT_CMD="$(ENTRYPOINT_CMD)"; \
			export RAY_PORT="$(RAY_PORT)"; \
			export RAY_CLIENT_PORT="$(RAY_CLIENT_PORT)"; \
			export RAY_DASHBOARD_PORT="$(RAY_DASHBOARD_PORT)"; \
			export RAY_LOG_ARCHIVE_DIR="$(RAY_LOG_ARCHIVE_DIR)"; \
			export HEAD_STARTUP_WAIT_SECONDS="$(HEAD_STARTUP_WAIT_SECONDS)"; \
			export WORKER_STARTUP_WAIT_SECONDS="$(WORKER_STARTUP_WAIT_SECONDS)"; \
			export CLUSTER_STABILIZE_WAIT_SECONDS="$(CLUSTER_STABILIZE_WAIT_SECONDS)"; \
			SUBMIT_OUTPUT=$$($(SBATCH) --export=ALL --job-name="$$JOB_NAME" "$$SCRIPT"); \
			echo "$$SUBMIT_OUTPUT"; \
			JOB_ID=$$(printf "%s\n" "$$SUBMIT_OUTPUT" | awk '/Submitted batch job/ {print $$4}'); \
			if [ -n "$$JOB_ID" ]; then \
				printf "%s\n" "$$JOB_ID" > "$(SLURM_JOB_FILE)"; \
				echo "Tracked Slurm job id in $(SLURM_JOB_FILE)"; \
			else \
				echo "Warning: could not parse submitted job id"; \
			fi; \
			;; \
		down) \
			if ! ( [ -x "$(SCANCEL)" ] || command -v "$(SCANCEL)" >/dev/null 2>&1 ); then \
				echo "Error: scancel not found (SCANCEL=$(SCANCEL))."; \
				echo "Run this command on a Slurm login node, load your Slurm module, or pass SCANCEL=/absolute/path/to/scancel."; \
				exit 127; \
			fi; \
			JOB_ID=""; \
			if [ -f "$(SLURM_JOB_FILE)" ]; then JOB_ID=$$(cat "$(SLURM_JOB_FILE)"); fi; \
			if [ -z "$$JOB_ID" ]; then \
				echo "No tracked job id found in $(SLURM_JOB_FILE)."; \
				echo "Run make slurm up first or cancel manually with scancel <job_id>."; \
				exit 1; \
			fi; \
			echo "Cancelling Slurm job: $$JOB_ID"; \
			$(SCANCEL) "$$JOB_ID"; \
			if [ -f "$(SLURM_JOB_FILE)" ] && [ "$$(cat "$(SLURM_JOB_FILE)" 2>/dev/null)" = "$$JOB_ID" ]; then \
				rm -f "$(SLURM_JOB_FILE)"; \
			fi; \
			;; \
	esac

# Dummy targets so `make slurm up` style works.
.PHONY: up down status logs dashboard
up down status logs dashboard:
	@:
