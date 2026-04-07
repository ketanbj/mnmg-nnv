# Ray Cluster Experiment

This repository supports Ray cluster runs in two modes:

- Slurm cluster (`make slurm ...`)
- Static IP cluster via SSH (`make cluster ...`)

## Repository Layout

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

## Slurm Workflow

Update `scripts/slurm/ray_cluster.sbatch` SBATCH directives for your cluster (`--account`, `--nodes`, GPU type, walltime, output).

Allocate/start Slurm job:

```bash
make slurm up
```

Configure Slurm runtime in `.env` (for example `PROJECT_ROOT`, `ENTRYPOINT`, `ENTRYPOINT_ARGS`, `ENTRYPOINT_CMD`, `SLURM_JOB_NAME`) and submit:

```bash
make slurm up
```

`VENV_ACTIVATE` may be absolute or relative to `PROJECT_ROOT` (for SSH sync flow, `.venv/bin/activate` is usually easiest).
`make slurm ...` no longer accepts command-line variable overrides; set all values in `.env`.

Stop job:

```bash
make slurm down
```

`scripts/slurm/ray_cluster.sbatch` starts Ray head on the first allocated node, starts workers on remaining nodes, runs either `uv run <ENTRYPOINT_CMD>` (if set) or `uv run ENTRYPOINT ENTRYPOINT_ARGS` on the head node, and stops Ray processes on exit.

`make slurm up` stores the submitted job id in `.slurm-ray-jobid`; `make slurm down` uses that file by default.

If Slurm CLI is only available on a login node, run through SSH:

```bash
make slurm up
make slurm down
```

Set `SLURM_LOGIN` and `SLURM_REMOTE_DIR` in `.env` for SSH mode.

If you use an SSH alias, add a host entry in `~/.ssh/config`:

```sshconfig
Host phoenix
  HostName login-p.pace.gatech.edu
  IdentityFile ~/.ssh/<your-ssh-key>
  User <username>
```

Then set `SLURM_LOGIN=phoenix` in `.env`.

When `SLURM_LOGIN` is set, `make slurm ...` now auto-syncs required project files to `SLURM_REMOTE_DIR` via `tar` over `ssh` before running remote commands. The default sync list is:
`Makefile scripts/slurm/ray_cluster.sbatch .env`

You can disable syncing or customize the file list by updating `.env`:

```bash
SLURM_SYNC=0
SLURM_SYNC_FILES=Makefile scripts/slurm/ray_cluster.sbatch jobs/pipeline_job.py .env
```

If `VENV_ACTIVATE` does not exist on the compute nodes, `scripts/slurm/ray_cluster.sbatch` now bootstraps it with `uv` from `pyproject.toml` (using `uv.lock` when present) before sourcing the venv.

At teardown, worker Ray logs are collected into one job folder on shared storage:
`<SLURM_REMOTE_DIR>/logs/ray-slurm/<slurm_job_id>/<node>/...` by default
(override with `RAY_LOG_ARCHIVE_DIR`).

If `SLURM_LOGIN` is set and `SLURM_REMOTE_DIR` is left empty, it defaults to the repo folder name under your remote home directory (for example `mnmg-nnv`).

## Notes

- For cluster-connected scripts, use `ray.init(address="auto")`.
- `make slurm ...` commands require Slurm CLI tools (`sbatch`, `scancel`) in `PATH` and should be run on your HPC Slurm login node.
