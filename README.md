# Ray Cluster Experiment

This repo runs Ray in two modes:

- Docker (`make docker ...`)
- Slurm cluster (`make slurm ...`)
- Static IP cluster via SSH (`make cluster ...`)

Run `make help` anytime to see commands.

## 1) Quick Start: Docker (fastest)

1. Create local config:

```bash
make env
```

2. (Optional) edit `.env`:

- `WORKER_REPLICAS=1`
- `RAY_DASHBOARD_PORT=8265`
- `RAY_PORT=6379`

3. Start cluster:

```bash
make docker up
```

4. Check it:

```bash
make docker status
make docker dashboard
```

5. Stop:

```bash
make docker down
```

## 2) Quick Start: Slurm

1. Update Slurm directives in `scripts/slurm/ray_cluster.sbatch`:
- `conf/cluster_hosts.conf` - IP/host list for static cluster mode
- `.env.example` - Example configuration values
- `.env` - Local configuration consumed by `make` targets
- `Makefile` - Unified interface for Slurm and static-IP workflows
- `scripts/slurm/ray_cluster.sbatch` - Slurm-based Ray head/worker launcher + job runner
- `scripts/cluster/ray_cluster_ips.sh` - IP-based Ray head/worker launcher + teardown
- `jobs/demo_job.py` - Example Ray job (`ray.init(address="auto")`)
- `jobs/pipeline_job.py` - Pipelined actor example job

## Static IP Workflow

Put node addresses in `conf/cluster_hosts.conf` (first line is head node), then run:

```bash
make cluster up
make cluster down
```

Configure in `.env`:

- `CLUSTER_HOSTS_FILE` (default `conf/cluster_hosts.conf`)
- `CLUSTER_STATE_FILE` (default `.ray-cluster-hosts`)
- `CLUSTER_SSH` (default `ssh`)
- `PROJECT_ROOT`, `VENV_ACTIVATE`, `RAY_PORT`, `RAY_CLIENT_PORT`, `RAY_DASHBOARD_PORT`

- `#SBATCH --account=...`
- `#SBATCH --nodes=...`
- `#SBATCH --gpus-per-node=...`
- `#SBATCH --time=...`

2. Set required values in `.env`:

- `PROJECT_ROOT=/abs/path/to/your/project/on-cluster`
- `VENV_ACTIVATE=.venv/bin/activate` (relative to `PROJECT_ROOT` or absolute)
- `ENTRYPOINT=abcrown.py` (or your script)
- `ENTRYPOINT_ARGS=--flag1 x --flag2 y`

Notes:
- Do not quote `ENTRYPOINT_ARGS`.
- If `ENTRYPOINT_CMD` is set, it overrides `ENTRYPOINT` + `ENTRYPOINT_ARGS`.
- Entrypoint is run with `uv run`.

3. Submit:

```bash
make slurm up
```

4. Stop:

```bash
make slurm down
```

## Slurm via SSH login node

Required SSH setup:

- OpenSSH client installed locally (`ssh` command available).
- A private key that can log in to your cluster account.
- A host entry in `~/.ssh/config` (recommended) so `SLURM_LOGIN` can use an alias.

Example `~/.ssh/config`:

```sshconfig
Host phoenix
  HostName login-p.pace.gatech.edu
  User <your-username>
  IdentityFile ~/.ssh/<your-private-key>
  IdentitiesOnly yes
```

Quick check:

```bash
ssh phoenix "hostname && which sbatch && which scancel"
```

If Slurm CLI is only available on a login node, set in `.env`:

- `SLURM_LOGIN=your_ssh_host_or_alias`
- `SLURM_REMOTE_DIR=/remote/path/for/this/repo`

Then run the same commands:

```bash
make slurm up
make slurm down
```

Behavior:
- Files in `SLURM_SYNC_FILES` are synced to `SLURM_REMOTE_DIR` via `tar` over `ssh`.
- Submitted job id is stored in `.slurm-ray-jobid`.
- Ray logs are archived under `logs/ray-slurm/<job_id>/...` by default.

## Command Reference

- `make env`
- `make docker up|down|status|logs|dashboard`
- `make slurm up|down`

## Where Logs Go

### Docker (`make docker ...`)

- Runtime logs (head + workers): stream with:

```bash
make docker logs
```

- Service status + container names:

```bash
make docker status
```
When `SLURM_LOGIN` is set, `make slurm ...` now auto-syncs required project files to `SLURM_REMOTE_DIR` via `tar` over `ssh` before running remote commands. The default sync list is:
`Makefile scripts/slurm/ray_cluster.sbatch .env`

- Ray internal logs inside containers:
  - Head: `/tmp/ray/session_latest/logs/`
  - Worker(s): `/tmp/ray/session_latest/logs/`
  - Example:

```bash
docker compose --env-file .env -f docker-compose.yaml exec ray-head ls -lah /tmp/ray/session_latest/logs
```

### Slurm (`make slurm ...`)

- Main Slurm job log (stdout/stderr) is written by:
  - `#SBATCH --output=ray-poc-%j.log`
  - So for job `6315510`, log is `ray-poc-6315510.log`.

- If running locally on login node:
  - Log path: `<repo>/ray-poc-<job_id>.log`

- If running through SSH (`SLURM_LOGIN` + `SLURM_REMOTE_DIR`):
  - Log path: `<SLURM_REMOTE_DIR>/ray-poc-<job_id>.log`

- Per-node Ray logs are archived at teardown:
  - Default: `logs/ray-slurm/<job_id>/<node>/...`
  - In SSH mode: `<SLURM_REMOTE_DIR>/logs/ray-slurm/<job_id>/<node>/...`
  - Override with `RAY_LOG_ARCHIVE_DIR` in `.env`.

- Useful commands:

```bash
# Current/last submitted job id (local mode)
cat .slurm-ray-jobid

# Tail main Slurm log
tail -f ray-poc-<job_id>.log

# Inspect archived per-node Ray logs
find logs/ray-slurm/<job_id> -maxdepth 3 -type f
```

```bash
# SSH mode equivalents (run from your laptop/workstation)
ssh "$SLURM_LOGIN" "cat $SLURM_REMOTE_DIR/.slurm-ray-jobid"
ssh "$SLURM_LOGIN" "tail -f $SLURM_REMOTE_DIR/ray-poc-<job_id>.log"
ssh "$SLURM_LOGIN" "find $SLURM_REMOTE_DIR/logs/ray-slurm/<job_id> -maxdepth 3 -type f"
```

## Common Errors

- `/bin/sh: export: ... not a valid identifier`:
  - `ENTRYPOINT_ARGS` was quoted or split incorrectly. Keep it unquoted.
- `Address already in use ... 6379`:
  - Another Ray head is already using that port. Stop old job or change `RAY_PORT`.
- `Failed to get cluster ID from GCS` / GCS timeout:
  - Usually downstream of head startup failure. Check `ray-poc-<jobid>.log` first.
