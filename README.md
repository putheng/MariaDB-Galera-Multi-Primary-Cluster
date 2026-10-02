# MariaDB + Galera Multi-Primary Cluster

A 3-node MariaDB Galera **multi-primary** cluster running with Docker Compose, with resource limits per node, plus JMeter load tests that insert 1,000,000 records.

- Image: `mariadb:latest` (verified **13.0.2**)
- Nodes: `galera-node1`, `galera-node2`, `galera-node3` (all read/write, synchronous replication)
- Resource limits: **2 CPU / 2 GiB RAM** each by default (currently set to **4 CPU / 4 GiB** in `docker-compose.yml`)
- SST: `mariabackup`
- Healthchecks: `healthcheck.sh --connect --galera_ready`

## Architecture

| Node | Container | Host port | Internal | Role |
|------|-----------|-----------|----------|------|
| 1 | `galera-node1` | `3306` | `3306` | designated bootstrap for first-ever start |
| 2 | `galera-node2` | `3307` | `3306` | joins cluster |
| 3 | `galera-node3` | `3308` | `3306` | joins cluster |

All nodes share the Docker network `galera` and talk over `gcomm://galera-node1,galera-node2,galera-node3` (ports 4567/4568/4444 + 3306).

```
              +-------------------+      +-------------------+      +-------------------+
  clients --> |   galera-node1    |<---->|   galera-node2    |<---->|   galera-node3    |
    :3306     |  :3306  (rw)      |      |  :3306  (rw)      |      |  :3306  (rw)      |
              +-------------------+      +-------------------+      +-------------------+
                          synchronous multi-primary replication (Galera)
```

## Repository layout

```
.
├── docker-compose.yml                 # 3-node cluster definition + limits
├── .env.example                       # credentials template (copy to .env)
├── config/
│   ├── galera.cnf                     # wsrep + InnoDB tuning
│   ├── galera-entrypoint.sh           # bootstrap decision + healthcheck creds
│   └── init/01-galera-users.sh        # creates SST + healthcheck users
└── loadtest/
    ├── mariadb-galera-load.jmx        # inserts 1M into a single node
    ├── mariadb-galera-load-allnodes.jmx # inserts 1M across all 3 nodes
    ├── load-test.properties           # single-node settings
    ├── load-test-allnodes.properties  # all-nodes settings
    ├── schema.sql                     # load_test table DDL
    └── run.sh                         # headless runner + HTML report
```

## Prerequisites

- Docker Engine + Docker Compose v2+ (verified Docker 29.8.0, Compose v5.5.1)
- For the load tests: Apache JMeter 5.6+, Java 17+ (verified JMeter 5.6.3, OpenJDK 21)

## Quick start

```bash
cp .env.example .env          # adjust credentials if you like
docker compose up -d
docker compose ps             # wait until all three are "healthy"
```

Verify the cluster:

```bash
docker exec galera-node1 mariadb -uroot -proot_password -e "
  SHOW STATUS WHERE Variable_name IN
  ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready');"
```

Expected: `wsrep_cluster_size=3`, `wsrep_cluster_status=Primary`, `wsrep_local_state_comment=Synced`, `wsrep_ready=ON` on every node.

## Credentials

Defined in `.env` (copy from `.env.example`); these are **development** defaults.

| Variable | Default | Purpose |
|----------|---------|---------|
| `MARIADB_ROOT_PASSWORD` | `root_password` | `root` user |
| `MARIADB_DATABASE` | `appdb` | application database |
| `MARIADB_USER` / `MARIADB_PASSWORD` | `appuser` / `app_password` | application user |
| `GALERA_SST_USER` / `GALERA_SST_PASSWORD` | `sst_user` / `sst_password` | state transfer auth |
| `GALERA_HC_USER` / `GALERA_HC_PASSWORD` | `hc_user` / `hc_password` | healthcheck user |

## Configuration

### `config/galera.cnf`

| Setting | Value | Notes |
|---------|-------|-------|
| `wsrep_on` | `ON` | enable Galera |
| `wsrep_cluster_name` | `galera_cluster` | must match on all nodes |
| `wsrep_cluster_address` | `gcomm://galera-node1,galera-node2,galera-node3` | cluster members |
| `wsrep_sst_method` | `mariabackup` | full state transfer |
| `wsrep_slave_threads` | `2` | apply threads per node |
| `wsrep_provider_options` | `gcache.size=256M` | write-set cache |
| `innodb_buffer_pool_size` | `512M` | raise if you raise the container memory limit |
| `innodb_flush_log_at_trx_commit` | `0` | faster commits (durability trade-off) |
| `bind-address` | `0.0.0.0` | accept remote connections |

### Resource limits (`docker-compose.yml`)

```yaml
deploy:
  resources:
    limits:
      cpus: "4.0"
      memory: 4g
```

Change these and apply with `docker compose up -d` (containers are recreated, data volumes persist).

## How it works

### Bootstrap / recovery

`config/galera-entrypoint.sh` decides whether to start with `--wsrep-new-cluster`:

1. **Fresh data dir** → only the designated bootstrap node (`GALERA_BOOTSTRAP_NODE=1`, i.e. node1) creates the cluster.
2. **Existing data** → a node bootstraps only if its own `grastate.dat` contains `safe_to_bootstrap: 1` (the node that left the cluster last, written by Galera on graceful shutdown). All other nodes start normally and join.

This follows Galera's own safety rule. Because of that, `depends_on` health gating between nodes is intentionally **not** used — a non-safe node waits/joins instead of blocking the safe node from bootstrapping.

- Normal restart of one node while the cluster runs → node rejoins (no bootstrap).
- Graceful full-cluster restart (`docker compose down && docker compose up -d`) → the last node to leave bootstraps, the rest join.
- **Unclean full-cluster shutdown**: no node may have `safe_to_bootstrap: 1`. Recovery requires manually setting it to `1` on the most advanced node (`grastate.dat`, `seqno` highest) and starting that node first.

### Healthcheck

The entrypoint writes `/etc/mysql/healthcheck.cnf` from `GALERA_HC_*`, and the compose healthcheck runs:

```
healthcheck.sh --defaults-extra-file=/etc/mysql/healthcheck.cnf --connect --galera_ready
```

The dedicated user (created in `config/init/01-galera-users.sh`) is replicated to all nodes, so joiners pass healthchecks too.

## Operations

```bash
docker compose logs -f galera-node1      # follow logs
docker compose ps                        # status + health
docker compose stop                      # stop all, keep containers/volumes
docker compose down                      # remove containers, keep data volumes
docker compose down -v                   # remove containers AND data (full reset)
docker stats --no-stream                 # CPU / memory usage
```

## Load tests

Both plans insert records into the `appdb.load_test` table (auto-created and truncated by a `setUp` thread group). Each run's `setUp` does `CREATE TABLE IF NOT EXISTS` + `TRUNCATE`, so a run always starts from an empty table. Disable the `TRUNCATE` sampler in the JMX if you want cumulative runs.

### Plans

| Plan | Target | Default records |
|------|--------|-----------------|
| `mariadb-galera-load.jmx` | node1 only (`127.0.0.1:3306`) | `threads(20) × loops(50000)` = 1,000,000 |
| `mariadb-galera-load-allnodes.jmx` | all 3 nodes concurrently | `10 × (33333+33333+33334)` = 1,000,000 |

`run.sh` auto-downloads MariaDB Connector/J 3.5.10 into `loadtest/lib/` if missing and runs JMeter headless with an HTML dashboard.

### Run

```bash
cd loadtest

# all nodes (default plan selection via JMX env var)
JMX=mariadb-galera-load-allnodes.jmx ./run.sh load-test-allnodes.properties

# single node
./run.sh load-test.properties

# override any setting
JMX=mariadb-galera-load-allnodes.jmx ./run.sh load-test-allnodes.properties \
  -Jthreads.per.node=20 -Jloops.node1=50000 -Jloops.node2=50000 -Jloops.node3=50000
```

Results are written to `loadtest/results/<timestamp>/`:
- `result.jtl` – raw samples
- `html/index.html` – JMeter dashboard
- `jmeter.log` – run log

### Tunable properties

| Property | Single-node | All-nodes | Meaning |
|----------|-------------|-----------|---------|
| `threads` | 20 | – | concurrent threads |
| `threads.per.node` | – | 10 | threads per node group |
| `loops` | 50000 | – | iterations per thread |
| `loops.node1/2/3` | – | 33333/33333/33334 | iterations per node group |
| `rampup` | 20 | 10 | seconds to ramp up |
| `db.host` / `db.port` / `db.port1..3` | `127.0.0.1` / `3306` / … | | JDBC target |
| `db.name` / `db.user` / `db.password` | `appdb` / `appuser` / `app_password` | | JDBC credentials |
| `db.pool.max` | 40 | 40 | connection pool size |

## Load test report

### Environment

| Item | Value |
|------|-------|
| Host | Apple M1 Max, 10 CPU, 32 GiB RAM, macOS (Docker Desktop / arm64) |
| Docker / Compose | 29.8.0 / v5.5.1 |
| MariaDB | 13.0.2 (Galera) |
| JMeter / JDBC | 5.6.3 / MariaDB Connector-J 3.5.10 |
| Java | OpenJDK 21 |
| Dataset | `appdb.load_test`, 1,000,000 rows, unique `token`, ~230 bytes/row |
| Per-node limits | varies per scenario (see below) |

### Results

All runs inserted **1,000,002 samples** (1,000,000 inserts + 2 `setUp` statements), **0 errors**, and resulted in exactly **1,000,000 unique rows replicated to all 3 nodes** (`wsrep_cluster_size=3`, `Synced`).

| Scenario | Nodes written | Node limits | Throughput | Duration | Avg | p95 | p99 | Max |
|----------|:-------------:|:-----------:|-----------:|:--------:|----:|----:|----:|----:|
| Single node | 1 | 2 CPU / 2 GiB | 8,354 /s | 2:00 | 2.00 ms | 3 ms | 14 ms | 219 ms |
| All nodes | 3 | 2 CPU / 2 GiB | 9,865 /s | 1:41 | 2.73 ms | 5 ms | 8 ms | 210 ms |
| All nodes | 3 | 4 CPU / 4 GiB | 10,087 /s | 1:39 | 2.65 ms | 5 ms | 7 ms | 198 ms |

Distribution for the all-nodes runs: `node1 = 333,330`, `node2 = 333,330`, `node3 = 333,340` inserts.

### Observations

- **Writing to all nodes is ~18% faster** than a single node at the same resources (9,865/s vs 8,354/s), because client connections and apply work spread across the cluster.
- **Doubling CPU and RAM gave only ~2%** (9,865/s → 10,087/s). Galera's synchronous certification is the bottleneck, not CPU or memory; extra resources mostly idle.
- Latency stayed low throughout (p99 single-digit to low-teens ms) with zero replication conflicts or errors.
- To scale further, increase JMeter concurrency first (`-Jthreads.per.node`), then consider raising `innodb_buffer_pool_size` alongside container memory.

## Security notes

This is a **development** setup. Before any non-local use:

- Replace all `.env` passwords and do not commit `.env` (it is git-ignored).
- `GALERA_SST_PASSWORD` is passed as a command-line argument and is visible in the process list; move to Docker secrets.
- Passwords live in plaintext in `.env` and mounted config; no TLS is configured.
- `innodb_flush_log_at_trx_commit=0` trades durability for speed.
