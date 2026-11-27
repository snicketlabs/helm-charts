# Scaling

How the platform's workers scale, how to size them, and how to tell when the
database rather than the workers is the limit. For installing the chart, see
[the chart README](README.md).

## KEDA autoscaling

Platform uses [KEDA (Kubernetes Event Driven Autoscaling)](https://keda.sh/) to scale GoodJob workers on queue depth in Postgres, creating pods on demand when work is available and scaling to zero when queues are empty. All job processing runs this way. Without KEDA installed the install fails: the chart creates ScaledObject and ScaledJob resources, and the API server rejects them when the CRDs are absent.

### Installing KEDA

Install KEDA (v2.x) before you deploy Platform. The install command is in the
chart's [prerequisites](README.md#prerequisites); this section explains the
options it sets. For other ways to install KEDA, see the
[KEDA installation documentation](https://keda.sh/docs/latest/deploy/).

#### Why the command enables KEDA's metrics

KEDA's operator exposes `keda_scaler_metrics_value` on port 8080, one series per
trigger. Because every worker here scales on a Postgres query counting rows in
`good_jobs`, that value *is* the queue depth for each queue — for ScaledJobs and
ScaledObjects alike.

This is the only queue-depth source the chart has, so if it is not scraped the
pipeline dashboards have nothing to draw.

**Both flags are needed.** `prometheus.operator.enabled` is what exposes the
metrics; `serviceMonitor.enabled` only creates the object that scrapes them.
Setting the second alone renders no ServiceMonitor at all, silently.

Already running KEDA? The prerequisites also give the `helm upgrade` command
that adds the same two values.

With `monitoring.enabled`, the bundled Prometheus picks that up: this chart sets
`serviceMonitorSelectorNilUsesHelmValues: false`, so Prometheus selects
ServiceMonitors in any namespace rather than only ones carrying its own release
label — which KEDA's, created by a different chart, does not.

Running your own Prometheus instead? Make sure its ServiceMonitor selector
reaches KEDA's namespace, or scrape the `keda-operator` Deployment directly on
port 8080.

One thing to know when writing your own queries against these series: KEDA's own
namespace lands on the `namespace` label. The application's namespace arrives as
`exported_namespace`.

### Postgres connection configuration

`kedaAutoScaling.postgres.host` must be set whenever the chart cannot work out
the database host itself (for example, with `postgres.dbPrimaryHostSecret`).
Rendering fails with a message if it is not.

KEDA polls the `good_jobs` table directly (via a `postgresql`-type trigger). This needs a dedicated, read-only Postgres role — not your application's own DB user — so KEDA's blast radius is limited to counting rows in `good_jobs` and `good_job_processes`.

#### Automatic setup

This is the default (`kedaAutoScaling.postgres.autoCreateRole: true`).

The database preparation Job, on install and on every upgrade, also creates (or converges) a `db_keda_ro` role and grants it `SELECT` on `good_jobs` and `good_job_processes` only — never broader access like `pg_read_all_data`. The role's password is generated once and stored in a Secret that's stable across upgrades.

Permission problems never fail your install or upgrade: if your Postgres user doesn't have `CREATEROLE` (common if you supply your own Postgres — see below), the Job logs a warning and exits successfully. It does fail if `good_jobs` or `good_job_processes` doesn't exist after the schema is loaded, which usually means the application image doesn't include GoodJob. Check the database preparation Job's logs (`app.kubernetes.io/component: db-prepare-initial` on install, `db-prepare` on upgrades) if KEDA scaling doesn't come up — if it couldn't create the role automatically, use the manual setup below.

#### Manual setup

If you're supplying your own Postgres (BYOP) and prefer to manage this yourself, set `autoCreateRole: false` and run:

```sql
CREATE ROLE db_keda_ro LOGIN PASSWORD 'choose-a-strong-password';
GRANT CONNECT ON DATABASE your_database_name TO db_keda_ro;
GRANT USAGE ON SCHEMA public TO db_keda_ro;
GRANT SELECT ON good_jobs TO db_keda_ro;
GRANT SELECT ON good_job_processes TO db_keda_ro;
```

Then create the Secret and point the chart at it:

```bash
kubectl create secret generic my-keda-postgres-secret \
  --namespace snicketlabs \
  --from-literal=password=choose-a-strong-password
```

```yaml
kedaAutoScaling:
  postgres:
    autoCreateRole: false
    dbUser: db_keda_ro    # or your own role name
    authenticationRef:
      secretName: my-keda-postgres-secret
```

If your Postgres host isn't resolvable from `postgres.primaryHost` (for example, you use `postgres.dbPrimaryHostSecret`), also set `kedaAutoScaling.postgres.host` explicitly — KEDA needs a literal host string at render time and can't read one from a Secret the way application env vars can.

### Configuring KEDA

There is nothing to switch on. Two values blocks describe every worker the
chart runs:

- **`scaledObjects`** — long-running multi-queue workers, scaled like an HPA.
- **`scaledJobs`** — one pod per task, for CPU-heavy or long-running work.

Tune polling under `kedaAutoScaling`:

```yaml
kedaAutoScaling:
  postgres:
    pollingInterval: 30  # Check queue depth every 30 seconds
```

The chart ships a single set of autoscaling defaults in `values.yaml`. Pods scale to demand, bounded by each worker's `maxReplicaCount`, by `materialProcessingCount`, and by what your cluster can schedule. Raise a ceiling in `your-custom-values.yaml` if a workload needs it — see [Sizing the workloads](#sizing-the-workloads).

### Initial deployment

Expect brief node consolidation churn during the initial deployment: nodes may be added and removed for a while before the cluster settles. No action is needed.

### GoodJob workers and shutdown

Workers run `good_job start` and scaledJobs run
`good_job:perform_inline_task[<queue>]`. Each worker's `concurrency` and
`shutdownTimeout` set its GoodJob thread count and shutdown timeout. See the
`goodJob` values for polling, probe and grace-period settings.

GoodJob has no queue weights. When a worker's queues have different `priority`
values they are claimed in strict order, highest first. When they are all equal,
GoodJob takes jobs from any of them by priority and creation time.

**Set `goodJob.shutdownTimeout` to cover your longest tasks.** After a
termination signal, scaledJob task pods drain for `goodJob.shutdownTimeout`
seconds (600 by default), and get a `terminationGracePeriodSeconds` of that plus
`goodJob.shutdownGraceSeconds` (60). A task still running after the drain is
interrupted and retried, and the retry counts towards its retry limit.

### Upgrades and field conflicts

If an upgrade fails with an error like this, the cause is KEDA, not your values:

```text
Upgrade "platform" failed: conflict occurred while applying object
<name> keda.sh/v1alpha1, Kind=ScaledJob: Apply failed with 4 conflicts:
conflict with "keda" using keda.sh/v1alpha1:
  .spec.jobTargetRef.template.spec.containers[name="good-job"].resources.limits.cpu
```

Helm 4 applies releases with server-side apply, which tracks which component
owns each field. KEDA's operator writes ScaledJobs back with a full-object
update, and where its serialisation of a field differs from what Helm sent, it
takes ownership of that field. Helm's next upgrade then finds it no longer owns
what it is trying to set, and stops.

A first install is never affected, because KEDA has not yet reconciled the
object. The failure appears on the second and later upgrades, which makes it
look intermittent.

**To recover, re-run the upgrade with `--force-conflicts`:**

```bash
helm upgrade platform ... --force-conflicts
```

This returns ownership of the contested fields to Helm and the upgrade
proceeds. It is safe here: it asserts the values from your chart and values
files, which is what you intended to deploy.

If you deploy through Distr, there is no flag to pass: tick **Force Conflicts** on
the deployment before selecting **Update**.

The owner named in the error is not always `keda`. Deploying through Distr, it is
usually `controller`, the agent's own field manager, and the fields are whichever
ones your values change — a `maxReplicaCount` you raised, a secret mount you
repointed. The cause and the fix are the same either way.

The most common trigger is a resource quantity written in a form the Kubernetes
API server rewrites when it stores the object, such as `4096Mi` (stored as
`4Gi`). The chart's own values avoid these forms, and `values.schema.json`
rejects the ones it can detect, but `4096Mi` is indistinguishable from a valid
`4095Mi` by pattern alone. If you set your own `resources` values, prefer the
largest binary suffix that divides exactly — `4Gi` rather than `4096Mi`, `750m`
rather than `0.75`.

This is a known upstream issue in KEDA
([kedacore/keda#7306](https://github.com/kedacore/keda/issues/7306)) and is not
specific to this chart.

## Sizing the workloads

Node pools autoscale and the application scales its workers to demand. The two values
that bound throughput are:

- **`materialProcessingCount`** (default `"default=5"`) — how many materials the application
  admits for processing at once.
- **`maxReplicaCount`** on each scaledJob and scaledObject — how far that worker may scale.

They ship aligned, at five materials in and five slots at most stages, so no
single stage is the bottleneck by default. A few workers differ
(`j2k-uhd-matchcore` scales to one, for example); `maxReplicaCount` in
`values.yaml` has each one. Raise both together in `your-custom-values.yaml` if
you want more throughput and have the cluster capacity for it; raising one alone
will not help.

**Large fingerprinting jobs need large nodes.** A pod is scheduled by its CPU
*request*. The largest, `j2k-uhd-matchcore` (4K JPEG 2000), requests 12 CPU and
6Gi: it never fits an 8 vCPU node, and fits a 16 vCPU node only when little else
is running on it. If you will ingest 4K JPEG 2000, provide nodes that can hold it.

How much either costs you depends on your content, library size, comparison types and which
features you use, which is why the chart does not guess on your behalf.

Contact Snicket Labs technical services for sizing recommendations.

### Recognising a database that cannot keep up

The database is usually what runs out first, and it rarely announces itself. The
symptom is **material processing getting slower while the workers themselves are
not busy**: jobs wait on the database, so wall times stretch while worker CPU
stays low. Processing that has gradually slowed without the workers working
harder is the signal to give the database more room.

Judge it on throughput, not CPU alone. A database that is too small for the work
*starves* the pipeline, and starvation reads as low CPU everywhere with long wall
times — which looks much like an idle system until you notice how little is
finishing.

Two things that are **not** saturation on their own:

- **A deep queue that is draining.** Depth tells you work arrived, not that
  anything is stuck. Watch whether it clears.
- **Brief CPU spikes.** Sustained pressure matters; momentary peaks do not.

**If you have provider metrics** (CloudWatch for RDS, Cloud Monitoring for Cloud
SQL), the things worth watching are sustained CPU, connection count against your
connection limit, and read and write latency. Rising latency alongside flat
throughput is the clearest version of the symptom above.

**If you run your own Postgres**, you do not need provider metrics to see this.
Postgres will tell you itself:

```sql
-- Sessions waiting rather than working. Growing and staying grown is the signal.
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY 1, 2 ORDER BY 3 DESC;

-- Headroom on connections.
SELECT count(*) AS in_use,
       current_setting('max_connections')::int AS connection_limit
FROM pg_stat_activity;
```

Climbing `wait_event_type = 'IO'` or `'LWLock'` under steady load points at the
database rather than the application. Connections sitting near the limit cause
the same slowdown for a different reason, and more CPU will not fix that one —
raise `max_connections`, or reduce `materialProcessingCount` so less work is
admitted at once.

**You do not need this chart's dashboards to spot it.** They make it easier to
see, but the symptom above (processing slowing while the workers stay idle) shows
up in any monitoring you already run. Either way, `materialProcessingCount` and
`maxReplicaCount` are still the two values that bound throughput.
