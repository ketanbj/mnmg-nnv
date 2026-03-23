COMPOSE_FILE := docker-compose.yaml
ENV_FILE := .env
DOCKER_COMPOSE := docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)
SLURM_SCRIPT ?= scripts/slurm/ray_cluster.sbatch
SLURM_JOB_FILE ?= .slurm-ray-jobid
SBATCH ?= sbatch
SQUEUE ?= squeue
SCANCEL ?= scancel
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
	@echo ""
	@echo "make slurm up                              Allocate/start Slurm Ray cluster job"
	@echo "make slurm up ENTRYPOINT=jobs/pipeline_job.py Run a different script"
	@echo "make slurm down [JOBID=123456]             Deallocate/cancel Slurm Ray cluster job"
	@echo "make slurm queue                           Show your Slurm queue"
	@echo "make slurm up SBATCH=/path/to/sbatch       Override Slurm CLI paths if PATH differs"
	@echo "make slurm submit / make slurm cancel      Backward-compatible aliases"

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

.PHONY: slurm
slurm:
	@set -e; \
	case "$(SUBCMD)" in \
		up|submit) \
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
			echo "Submitting Slurm job: $$SCRIPT"; \
			SUBMIT_OUTPUT=$$($(SBATCH) --export=ALL,\
				VENV_ACTIVATE="$(VENV_ACTIVATE)",\
				PROJECT_ROOT="$(PROJECT_ROOT)",\
				ENTRYPOINT="$(ENTRYPOINT)",\
				ENTRYPOINT_ARGS="$(ENTRYPOINT_ARGS)",\
				RAY_PORT="$(RAY_PORT)",\
				RAY_DASHBOARD_PORT="$(RAY_DASHBOARD_PORT)",\
				HEAD_STARTUP_WAIT_SECONDS="$(HEAD_STARTUP_WAIT_SECONDS)",\
				WORKER_STARTUP_WAIT_SECONDS="$(WORKER_STARTUP_WAIT_SECONDS)",\
				CLUSTER_STABILIZE_WAIT_SECONDS="$(CLUSTER_STABILIZE_WAIT_SECONDS)" \
				"$$SCRIPT"); \
			echo "$$SUBMIT_OUTPUT"; \
			JOB_ID=$$(printf "%s\n" "$$SUBMIT_OUTPUT" | awk '/Submitted batch job/ {print $$4}'); \
			if [ -n "$$JOB_ID" ]; then \
				printf "%s\n" "$$JOB_ID" > "$(SLURM_JOB_FILE)"; \
				echo "Tracked Slurm job id in $(SLURM_JOB_FILE)"; \
			else \
				echo "Warning: could not parse submitted job id"; \
			fi; \
			;; \
		queue) \
			if ! ( [ -x "$(SQUEUE)" ] || command -v "$(SQUEUE)" >/dev/null 2>&1 ); then \
				echo "Error: squeue not found (SQUEUE=$(SQUEUE))."; \
				echo "Run this command on a Slurm login node, load your Slurm module, or pass SQUEUE=/absolute/path/to/squeue."; \
				exit 127; \
			fi; \
			SHOW_USER="$(USER)"; \
			if [ -z "$$SHOW_USER" ]; then SHOW_USER=$$(id -un); fi; \
			$(SQUEUE) -u "$$SHOW_USER"; \
			;; \
		down|cancel) \
			if ! ( [ -x "$(SCANCEL)" ] || command -v "$(SCANCEL)" >/dev/null 2>&1 ); then \
				echo "Error: scancel not found (SCANCEL=$(SCANCEL))."; \
				echo "Run this command on a Slurm login node, load your Slurm module, or pass SCANCEL=/absolute/path/to/scancel."; \
				exit 127; \
			fi; \
			JOB_ID="$(JOBID)"; \
			if [ -z "$$JOB_ID" ] && [ -f "$(SLURM_JOB_FILE)" ]; then JOB_ID=$$(cat "$(SLURM_JOB_FILE)"); fi; \
			if [ -z "$$JOB_ID" ]; then \
				echo "Usage: make slurm down JOBID=<job_id>"; \
				echo "Or run make slurm up first (stores id in $(SLURM_JOB_FILE))."; \
				exit 1; \
			fi; \
			echo "Cancelling Slurm job: $$JOB_ID"; \
			$(SCANCEL) "$$JOB_ID"; \
			if [ -f "$(SLURM_JOB_FILE)" ] && [ "$$(cat "$(SLURM_JOB_FILE)" 2>/dev/null)" = "$$JOB_ID" ]; then \
				rm -f "$(SLURM_JOB_FILE)"; \
			fi; \
			;; \
		""|help) \
			$(MAKE) help; \
			;; \
		*) \
			echo "Unknown subcommand: $(SUBCMD)"; \
			echo "Run: make slurm help"; \
			exit 1; \
			;; \
	esac

# Dummy targets so `make ray up`/`make ray down` style works cleanly.
.PHONY: up down status logs dashboard job submit queue cancel
up down status logs dashboard job submit queue cancel:
	@:
