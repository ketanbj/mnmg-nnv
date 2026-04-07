#!/bin/bash
#SBATCH --account=gts-jyoung9-csse
#SBATCH --nodes=3
#SBATCH --gpus-per-node=RTX_6000:1
#SBATCH --time=00:15:00
#SBATCH --job-name=ray-poc
#SBATCH --output=ray-poc-%j.log

set -euo pipefail

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_GPU SLURM_MEM_PER_NODE
export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"
export SHELL=/bin/bash

# Runtime overrides:
#   VENV_ACTIVATE=/path/to/.venv/bin/activate
#   PROJECT_ROOT=/path/to/project/root
#   UV_BIN=uv
#   ENTRYPOINT=abcrown.py
#   ENTRYPOINT_ARGS="--disable_hugetensor_allocator --batch_size 256 --no_auto_enlarge_batch_size --config /storage/project/r-jyoung9-1/shared/nnv/exp_configs/alpha-beta-CROWN-performance-study/cifar_100.yaml --select_instance 66"
#   ENTRYPOINT_CMD=abcrown.py --disable_hugetensor_allocator --batch_size 256 --no_auto_enlarge_batch_size --config /storage/project/r-jyoung9-1/shared/nnv/exp_configs/alpha-beta-CROWN-performance-study/cifar_100.yaml --select_instance 66
#   RAY_PORT=6379
#   RAY_DASHBOARD_PORT=8265
#   RAY_LOG_ARCHIVE_DIR=logs/ray-slurm
PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$PWD}}"
SLURM_LOG_BASE_DIR="${SLURM_SUBMIT_DIR:-$PROJECT_ROOT}"
DEFAULT_VENV_ACTIVATE="$PROJECT_ROOT/.venv/bin/activate"
LEGACY_VENV_ACTIVATE="$HOME/src/Verifier_Development/complete_verifier/.venv/bin/activate"
UV_BIN="${UV_BIN:-uv}"
if [[ -n "${VENV_ACTIVATE:-}" ]]; then
    VENV_ACTIVATE="$VENV_ACTIVATE"
elif [[ -f "$DEFAULT_VENV_ACTIVATE" ]]; then
    VENV_ACTIVATE="$DEFAULT_VENV_ACTIVATE"
else
    VENV_ACTIVATE="$LEGACY_VENV_ACTIVATE"
fi
ENTRYPOINT="${ENTRYPOINT:-jobs/demo_job.py}"
ENTRYPOINT_ARGS="${ENTRYPOINT_ARGS:-}"
ENTRYPOINT_CMD="${ENTRYPOINT_CMD:-}"
RAY_PORT="${RAY_PORT:-6379}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
RAY_LOG_ARCHIVE_DIR="${RAY_LOG_ARCHIVE_DIR:-$SLURM_LOG_BASE_DIR/logs/ray-slurm/$SLURM_JOB_ID}"
HEAD_STARTUP_WAIT_SECONDS="${HEAD_STARTUP_WAIT_SECONDS:-30}"
WORKER_STARTUP_WAIT_SECONDS="${WORKER_STARTUP_WAIT_SECONDS:-10}"
CLUSTER_STABILIZE_WAIT_SECONDS="${CLUSTER_STABILIZE_WAIT_SECONDS:-10}"

if [[ "$VENV_ACTIVATE" != /* ]]; then
    VENV_ACTIVATE="$PROJECT_ROOT/$VENV_ACTIVATE"
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "PROJECT_ROOT not found: $PROJECT_ROOT"
    exit 1
fi

if ! command -v "$UV_BIN" >/dev/null 2>&1; then
    echo "uv not found (UV_BIN=$UV_BIN)."
    echo "Install uv on compute nodes or set UV_BIN to the uv binary path."
    exit 127
fi

if [[ ! -f "$VENV_ACTIVATE" ]]; then
    if [[ ! -f "$PROJECT_ROOT/pyproject.toml" ]]; then
        echo "pyproject.toml not found in PROJECT_ROOT: $PROJECT_ROOT"
        echo "Make sure pyproject.toml is synced to the remote project directory."
        exit 1
    fi
    if [[ "$VENV_ACTIVATE" != */bin/activate ]]; then
        echo "VENV_ACTIVATE must end with /bin/activate: $VENV_ACTIVATE"
        exit 1
    fi

    VENV_DIR="${VENV_ACTIVATE%/bin/activate}"
    echo "Creating virtualenv with uv at: $VENV_DIR"
    "$UV_BIN" venv "$VENV_DIR"

    if [[ -f "$PROJECT_ROOT/uv.lock" ]]; then
        echo "Syncing dependencies with uv (frozen lockfile)"
        (cd "$PROJECT_ROOT" && UV_PROJECT_ENVIRONMENT="$VENV_DIR" "$UV_BIN" sync --frozen)
    else
        echo "Syncing dependencies with uv (no lockfile)"
        (cd "$PROJECT_ROOT" && UV_PROJECT_ENVIRONMENT="$VENV_DIR" "$UV_BIN" sync)
    fi
fi

if [[ ! -f "$VENV_ACTIVATE" ]]; then
    echo "VENV_ACTIVATE not found after bootstrap: $VENV_ACTIVATE"
    exit 1
fi

if [[ "$RAY_LOG_ARCHIVE_DIR" != /* ]]; then
    RAY_LOG_ARCHIVE_DIR="$SLURM_LOG_BASE_DIR/$RAY_LOG_ARCHIVE_DIR"
fi

if [[ -z "$ENTRYPOINT_CMD" ]]; then
    if [[ "$ENTRYPOINT" = /* ]]; then
        ENTRYPOINT_PATH="$ENTRYPOINT"
    else
        ENTRYPOINT_PATH="$PROJECT_ROOT/$ENTRYPOINT"
    fi

    if [[ ! -f "$ENTRYPOINT_PATH" ]]; then
        echo "ENTRYPOINT not found: $ENTRYPOINT_PATH"
        exit 1
    fi
fi

nodes=$(scontrol show hostnames "$SLURM_JOB_NODELIST")
readarray -t nodes_array <<<"$nodes"
head_node="${nodes_array[0]}"

# Resolve head node IP address and prefer the first address returned.
head_ip=$(srun --nodes=1 --ntasks=1 -w "$head_node" hostname --ip-address | awk '{print $1}' | cut -d',' -f1)
if [[ -z "$head_ip" ]]; then
    echo "Failed to resolve head node IP"
    exit 1
fi

echo "Head node: $head_node"
echo "Head IP: $head_ip"

declare -a worker_srun_pids=()

cleanup() {
    if mkdir -p "$RAY_LOG_ARCHIVE_DIR" >/dev/null 2>&1; then
        echo "Collecting Ray worker logs into: $RAY_LOG_ARCHIVE_DIR"
        for node in "${nodes_array[@]}"; do
            node_log_dir="$RAY_LOG_ARCHIVE_DIR/$node"
            srun --nodes=1 --ntasks=1 -w "$node" env NODE_LOG_DIR="$node_log_dir" \
                bash -lc 'mkdir -p "$NODE_LOG_DIR"; if [[ -d /tmp/ray/session_latest/logs ]]; then cp -a /tmp/ray/session_latest/logs/. "$NODE_LOG_DIR"/; else echo "Ray logs not found on node." > "$NODE_LOG_DIR"/NO_LOGS.txt; fi' \
                >/dev/null 2>&1 || true
        done
    else
        echo "Warning: could not create log archive dir: $RAY_LOG_ARCHIVE_DIR"
        echo "Skipping Ray worker log collection."
    fi

    echo "Stopping Ray processes"
    for node in "${nodes_array[@]}"; do
        srun --nodes=1 --ntasks=1 -w "$node" \
            bash -lc "source \"$VENV_ACTIVATE\" && ray stop -f" >/dev/null 2>&1 || true
    done

    if [[ -n "${head_srun_pid:-}" ]]; then
        kill "$head_srun_pid" >/dev/null 2>&1 || true
    fi

    for pid in "${worker_srun_pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# Start head with dashboard so Ray Jobs API is available.
srun --nodes=1 --ntasks=1 -w "$head_node" \
    bash -lc "source \"$VENV_ACTIVATE\" && ray start --head --node-ip-address=\"$head_ip\" --port=\"$RAY_PORT\" --dashboard-host=0.0.0.0 --dashboard-port=\"$RAY_DASHBOARD_PORT\" --block" &
head_srun_pid=$!
sleep "$HEAD_STARTUP_WAIT_SECONDS"

# Start workers.
worker_num=$((SLURM_JOB_NUM_NODES - 1))
for ((i = 1; i <= worker_num; i++)); do
    node_i="${nodes_array[$i]}"
    echo "Starting worker $i on $node_i"
    srun --nodes=1 --ntasks=1 -w "$node_i" \
        bash -lc "source \"$VENV_ACTIVATE\" && ray start --address=\"$head_ip:$RAY_PORT\" --block" &
    worker_srun_pids+=("$!")
    sleep "$WORKER_STARTUP_WAIT_SECONDS"
done

sleep "$CLUSTER_STABILIZE_WAIT_SECONDS"

# Run requested entrypoint on the head node.
if [[ -n "$ENTRYPOINT_CMD" ]]; then
    echo "Running entrypoint command with uv run: $ENTRYPOINT_CMD"
    srun --nodes=1 --ntasks=1 -w "$head_node" \
        env VENV_ACTIVATE="$VENV_ACTIVATE" PROJECT_ROOT="$PROJECT_ROOT" UV_BIN="$UV_BIN" ENTRYPOINT_CMD="$ENTRYPOINT_CMD" \
        bash -lc 'source "$VENV_ACTIVATE" && cd "$PROJECT_ROOT" && "$UV_BIN" run bash -lc "$ENTRYPOINT_CMD"'
else
    echo "Running entrypoint with uv run: $ENTRYPOINT_PATH $ENTRYPOINT_ARGS"
    srun --nodes=1 --ntasks=1 -w "$head_node" \
        bash -lc "source \"$VENV_ACTIVATE\" && cd \"$PROJECT_ROOT\" && \"$UV_BIN\" run \"$ENTRYPOINT_PATH\" $ENTRYPOINT_ARGS"
fi
