#!/usr/bin/env bash

set -euo pipefail

CMD="${1:-}"
if [[ "$CMD" != "up" && "$CMD" != "down" ]]; then
    echo "Usage: ray_cluster_ips.sh up|down"
    exit 1
fi

CLUSTER_HOSTS_FILE="${CLUSTER_HOSTS_FILE:-conf/cluster_hosts.conf}"
CLUSTER_STATE_FILE="${CLUSTER_STATE_FILE:-.ray-cluster-hosts}"
CLUSTER_SSH="${CLUSTER_SSH:-ssh}"
PROJECT_ROOT="${PROJECT_ROOT:-}"
VENV_ACTIVATE="${VENV_ACTIVATE:-}"
RAY_PORT="${RAY_PORT:-6379}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
RAY_CLIENT_PORT="${RAY_CLIENT_PORT:-10001}"
HOSTS=()

read_hosts_from_file() {
    local file="$1"
    awk '
        {
            sub(/#.*/, "");
            if (NF > 0) {
                print $1;
            }
        }
    ' "$file"
}

load_hosts() {
    local source_file="$1"
    if [[ ! -f "$source_file" ]]; then
        return 1
    fi
    HOSTS=()
    while IFS= read -r host; do
        HOSTS+=("$host")
    done < <(read_hosts_from_file "$source_file")
    [[ "${#HOSTS[@]}" -gt 0 ]]
}

build_activation_prefix() {
    local venv_path="$VENV_ACTIVATE"
    if [[ -z "$venv_path" ]]; then
        printf ''
        return 0
    fi
    if [[ "$venv_path" != /* && -n "$PROJECT_ROOT" ]]; then
        venv_path="$PROJECT_ROOT/$venv_path"
    fi
    printf 'if [ ! -f %q ]; then echo "VENV_ACTIVATE not found: %s" >&2; exit 1; fi; source %q; ' "$venv_path" "$venv_path" "$venv_path"
}

run_remote() {
    local host="$1"
    local remote_cmd="$2"
    "$CLUSTER_SSH" "$host" "bash -lc $(printf '%q' "$remote_cmd")"
}

stop_ray_on_hosts() {
    local host
    local activate_prefix
    activate_prefix="$(build_activation_prefix)"
    for host in "${HOSTS[@]}"; do
        echo "Stopping Ray on $host"
        run_remote "$host" "${activate_prefix}ray stop -f >/dev/null 2>&1 || true"
    done
}

case "$CMD" in
    up)
        if ! load_hosts "$CLUSTER_HOSTS_FILE"; then
            echo "No hosts found in CLUSTER_HOSTS_FILE: $CLUSTER_HOSTS_FILE"
            exit 1
        fi

        head_host="${HOSTS[0]}"
        activate_prefix="$(build_activation_prefix)"

        echo "Head host: $head_host"
        echo "Ray address: $head_host:$RAY_PORT"

        run_remote "$head_host" "${activate_prefix}ray start --head --node-ip-address=$head_host --port=$RAY_PORT --ray-client-server-port=$RAY_CLIENT_PORT --dashboard-host=0.0.0.0 --dashboard-port=$RAY_DASHBOARD_PORT"

        if [[ "${#HOSTS[@]}" -gt 1 ]]; then
            for worker_host in "${HOSTS[@]:1}"; do
                echo "Starting worker on $worker_host"
                run_remote "$worker_host" "${activate_prefix}ray start --address=$head_host:$RAY_PORT"
            done
        fi

        printf "%s\n" "${HOSTS[@]}" > "$CLUSTER_STATE_FILE"
        echo "Tracked cluster hosts in $CLUSTER_STATE_FILE"
        echo "Cluster is up."
        ;;
    down)
        if ! load_hosts "$CLUSTER_HOSTS_FILE"; then
            if ! load_hosts "$CLUSTER_STATE_FILE"; then
                echo "No hosts found in CLUSTER_HOSTS_FILE or CLUSTER_STATE_FILE."
                exit 1
            fi
            echo "Using tracked hosts from $CLUSTER_STATE_FILE"
        fi

        stop_ray_on_hosts
        rm -f "$CLUSTER_STATE_FILE"
        echo "Cluster is down."
        ;;
esac
