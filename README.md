# Ray Cluster Experiment (Docker Compose)

This is a standalone Docker Compose Ray cluster under `experiment/ray-cluster/`.

## What you get

- `ray-head` with Dashboard + Ray Jobs API
- `ray-worker` nodes (scalable)
- `make ray up` / `make ray down` workflow
- Local Python file submission as a Ray job

## Files

- `docker-compose.yaml` - Ray head/worker stack
- `.env.example` - Tunable ports/resources
- `Makefile` - `make ray ...` interface
- `jobs/demo_job.py` - Example Ray job script

## Usage

Run from `experiment/ray-cluster`:

```bash
cd experiment/ray-cluster
make ray up
```

Scale workers:

```bash
make ray up N=3
```

Check cluster:

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

## Submit a local Python file as a Ray job

Submit the bundled example:

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

Notes:

- The script must be executable by Python in the Ray image.
- If your script uses Ray tasks/actors, initialize with `ray.init(address="auto")`.
