# Ray Cluster Experiment (Docker Compose)

This repository is a standalone Docker Compose Ray cluster project.

## What You Get

- `ray-head` with dashboard + Ray Jobs API
- `ray-worker` nodes (scalable with `N=...`)
- `make ray ...` workflow for cluster lifecycle and job submission
- Local Python file submission as a Ray job

## Repository Layout

- `docker-compose.yaml` - Ray head/worker stack
- `.env.example` - Default ports and resource settings
- `.env` - Local overrides used by `docker compose --env-file`
- `Makefile` - `make ray ...` interface
- `jobs/demo_job.py` - Example Ray job (`ray.init(address="auto")`)
- `jobs/pipeline_job.py` - Pipelined actor example job

## Usage

Run from the repository root:

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

## Submit a Local Python File as a Ray Job

Submit the bundled demo:

```bash
make ray job FILE=jobs/demo_job.py
```

Pass script args:

```bash
make ray job FILE=jobs/demo_job.py ARGS="--count 20"
```

Submit any local file path:

```bash
make ray job FILE=/absolute/path/to/your_job.py
```

## Notes

- The script must be executable by Python in the Ray image.
- For cluster-connected scripts, use `ray.init(address="auto")`.
