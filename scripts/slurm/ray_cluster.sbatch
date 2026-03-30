#!/bin/bash
#SBATCH --account=gts-jyoung9-csse
#SBATCH --nodes=3
#SBATCH --gpus-per-node=RTX_6000:1
#SBATCH --time=4:00:00
#SBATCH --job-name=ray-poc
#SBATCH --output=ray-poc-%j.log
#SBATCH --exclusive

set -euo pipefail

unset SLURM_MEM_PER_CPU SLURM_MEM_PER_GPU SLURM_MEM_PER_NODE
export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"
export SHELL=/bin/bash

# Runtime overrides:
#   VENV_ACTIVATE=/path/to/.venv/bin/activate
#   PROJECT_ROOT=/path/to/project/root
#   ENTRYPOINT=jobs/demo_job.py
#   ENTRYPOINT_ARGS="--count 20"
#   RAY_PORT=6379
#   RAY_DASHBOARD_PORT=8265
PROJECT_ROOT="${PROJECT_ROOT:-${SLURM_SUBMIT_DIR:-$PWD}}"
DEFAULT_VENV_ACTIVATE="$PROJECT_ROOT/.venv/bin/activate"
LEGACY_VENV_ACTIVATE="$HOME/src/Verifier_Development/complete_verifier/.venv/bin/activate"
if [[ -n "${VENV_ACTIVATE:-}" ]]; then
    VENV_ACTIVATE="$VENV_ACTIVATE"
elif [[ -f "$DEFAULT_VENV_ACTIVATE" ]]; then
    VENV_ACTIVATE="$DEFAULT_VENV_ACTIVATE"
else
    VENV_ACTIVATE="$LEGACY_VENV_ACTIVATE"
fi
ENTRYPOINT="${ENTRYPOINT:-jobs/demo_job.py}"
ENTRYPOINT_ARGS="${ENTRYPOINT_ARGS:-}"
RAY_PORT="${RAY_PORT:-6379}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
HEAD_STARTUP_WAIT_SECONDS="${HEAD_STARTUP_WAIT_SECONDS:-30}"
WORKER_STARTUP_WAIT_SECONDS="${WORKER_STARTUP_WAIT_SECONDS:-10}"
CLUSTER_STABILIZE_WAIT_SECONDS="${CLUSTER_STABILIZE_WAIT_SECONDS:-10}"

if [[ "$VENV_ACTIVATE" != /* ]]; then
    VENV_ACTIVATE="$PROJECT_ROOT/$VENV_ACTIVATE"
fi

if [[ ! -f "$VENV_ACTIVATE" ]]; then
    echo "VENV_ACTIVATE not found: $VENV_ACTIVATE"
    echo "Checked default project venv: $DEFAULT_VENV_ACTIVATE"
    echo "Set VENV_ACTIVATE=/path/to/.venv/bin/activate (or .venv/bin/activate relative to PROJECT_ROOT)."
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "PROJECT_ROOT not found: $PROJECT_ROOT"
    exit 1
fi

if [[ "$ENTRYPOINT" = /* ]]; then
    ENTRYPOINT_PATH="$ENTRYPOINT"
else
    ENTRYPOINT_PATH="$PROJECT_ROOT/$ENTRYPOINT"
fi

if [[ ! -f "$ENTRYPOINT_PATH" ]]; then
    echo "ENTRYPOINT not found: $ENTRYPOINT_PATH"
    exit 1
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

# Run requested script on the head node.
echo "Running entrypoint: $ENTRYPOINT_PATH $ENTRYPOINT_ARGS"
srun --nodes=1 --ntasks=1 -w "$head_node" \
    bash -lc "source \"$VENV_ACTIVATE\" && cd \"$PROJECT_ROOT\" && python \"$ENTRYPOINT_PATH\" $ENTRYPOINT_ARGS"
