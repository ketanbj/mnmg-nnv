# Ray Cluster Experiment

This repository supports Ray cluster runs in two modes:

- Docker Compose cluster (`make ray ...`)
- Slurm cluster (`make slurm ...`)

## Repository Layout

- `docker-compose.yaml` - Docker Ray head/worker stack
- `.env.example` - Docker defaults for ports/resources
- `.env` - Local Docker overrides used by `docker compose --env-file`
- `Makefile` - Unified interface for Docker and Slurm workflows
- `scripts/slurm/ray_cluster.sbatch` - Slurm-based Ray head/worker launcher + job runner
- `jobs/demo_job.py` - Example Ray job (`ray.init(address="auto")`)
- `jobs/pipeline_job.py` - Pipelined actor example job

## Docker Workflow

Start cluster:

```bash
make ray up
```

Scale workers:

```bash
make ray up N=3
```

Cluster checks:

```bash
make ray status
make ray dashboard
```

Tail logs:

```bash
make ray logs
```

Stop cluster:

```bash
make ray down
```

Submit local file as Ray job:

```bash
make ray job FILE=jobs/demo_job.py
make ray job FILE=jobs/demo_job.py ARGS="--count 20"
```

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

When `SLURM_LOGIN` is set, `make slurm ...` now auto-syncs required project files to `SLURM_REMOTE_DIR` via `scp` before running remote commands. The default sync list is:
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
