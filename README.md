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

Submit a different script:

```bash
make slurm up ENTRYPOINT=jobs/pipeline_job.py
```

Override environment/script settings at submission time:

```bash
make slurm up \
  VENV_ACTIVATE=.venv/bin/activate \
  PROJECT_ROOT=$PWD \
  ENTRYPOINT=jobs/demo_job.py \
  ENTRYPOINT_ARGS="--count 20"
```

`VENV_ACTIVATE` may be absolute or relative to `PROJECT_ROOT` (for SSH sync flow, `.venv/bin/activate` is usually easiest).

Queue and cancellation:

```bash
make slurm queue
make slurm down
make slurm down JOBID=123456
```

`scripts/slurm/ray_cluster.sbatch` starts Ray head on the first allocated node, starts workers on remaining nodes, runs the requested Python entrypoint on the head node, and stops Ray processes on exit.

`make slurm up` stores the submitted job id in `.slurm-ray-jobid`; `make slurm down` uses that file by default.

If Slurm CLI is only available on a login node, run through SSH:

```bash
make slurm up SLURM_LOGIN=user@login.cluster.edu SLURM_REMOTE_DIR=/path/to/repo
make slurm queue SLURM_LOGIN=user@login.cluster.edu SLURM_REMOTE_DIR=/path/to/repo
make slurm down SLURM_LOGIN=user@login.cluster.edu SLURM_REMOTE_DIR=/path/to/repo
```

You can also set `SLURM_LOGIN` and `SLURM_REMOTE_DIR` in `.env` and run `make slurm up/down/queue` without repeating them.

If you use an SSH alias, add a host entry in `~/.ssh/config`:

```sshconfig
Host phoenix
  HostName login-p.pace.gatech.edu
  IdentityFile ~/.ssh/<your-ssh-key>
  User <username>
```

Then set `SLURM_LOGIN=phoenix` in `.env`.

When `SLURM_LOGIN` is set, `make slurm ...` now auto-syncs required project files to `SLURM_REMOTE_DIR` via `scp` before running remote commands. The default sync list is:
`Makefile README.md pyproject.toml uv.lock jobs scripts .env .env.example`

You can disable syncing or customize the file list:

```bash
make slurm up SLURM_SYNC=0
make slurm up SLURM_SYNC_FILES="Makefile scripts jobs"
```

If `SLURM_LOGIN` is set and `SLURM_REMOTE_DIR` is left empty, it defaults to the repo folder name under your remote home directory (for example `mnmg-nnv`).

## Notes

- For cluster-connected scripts, use `ray.init(address="auto")`.
- For Docker mode, the script must be executable by Python in the Ray image.
- `make slurm ...` commands require Slurm CLI tools (`sbatch`, `squeue`, `scancel`) in `PATH` and should be run on your HPC Slurm login node.
