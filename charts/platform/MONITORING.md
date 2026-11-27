# Monitoring
## Customer responsibilities checklist

Before enabling monitoring, ensure you provide:
- Persistent storage (minimum 10Gi) for Prometheus, Grafana, and Loki (if enabled)
- Backup configuration for all persistent monitoring data (PVCs)
- Ingress and DNS configuration for accessing dashboards
- IAM roles and secrets for AWS integrations (CloudWatch, RDS, S3, etc.)
- Secret management for sensitive credentials (e.g., database, SMTP)

## Using the Kube Prometheus Stack this chart installs

Set `monitoring.enabled: true` and you are done. It installs Prometheus,
Grafana and the Operator CRDs, and our dashboards, alerts and data sources to monitor the platform:

| | |
|---|---|
| Pipeline overview | queues, pod CPU and memory, OOM kills, throttling |
| MatchCore tiers | per-tier wall time, CPU, throttling and memory against each envelope |
| GoodJob tables | via a Postgres datasource, wired for you |

The Postgres datasource uses the
chart's own read-only role, `db_grafana_ro`, and the chart mounts that role's
password into Grafana itself. There is no second flag and no secret to mount.

To turn an individual dashboard off, set it to `false`:

```yaml
monitoring:
  enabled: true
  matchDashboards:
    enabled: false
```

`monitoring.aws` is the exception and is always explicit — it assumes an IAM
role, and there is no value worth guessing.

## Logs

`monitoring.logging.enabled: true` adds Loki 3 and Alloy, which ships every
pod's logs to it, plus a Loki datasource in Grafana. Explore and Logs Drilldown
both work. Logs are kept for 31 days on a 10Gi volume on the cluster's default
StorageClass:

```yaml
loki:
  singleBinary:
    persistence:
      storageClass: gp3
      size: 50Gi
  loki:
    limits_config:
      retention_period: 744h
```

## Where Grafana is served

With `ingress` or `httpRoute` enabled, Grafana is served at
`https://<domain>/grafana` through the platform's own Ingress or HTTPRoute.
Setting `kube-prometheus-stack.grafana.ingress` turns this off and leaves
Grafana's address to you.

## Is the database holding the pipeline up?

`monitoring.aws` adds **Platform — database and throughput**, which
puts RDS load next to the pipeline on one screen. Either half alone is
ambiguous; together they separate a busy database from one that is the
constraint:

| What you see | What it means |
|---|---|
| Queue depth up, worker CPU up, database calm | Working as intended |
| Queue depth up, worker CPU **low**, database CPU or latency up | The database is the constraint — step it up |
| Queue depth up, worker CPU low, database also calm | Not the database. Look at `materialProcessingCount` and the scaledJob ceilings, or whether pods can be scheduled |
| Connections flat at a ceiling | Raise `max_connections` or admit less work — more CPU will not help |

The dashboard carries that table too, so it is there when you are looking at it
rather than here.

**This is AWS only**, because the database half is CloudWatch. On Cloud SQL or
your own Postgres the dashboard does not render and the pairing has to be
inferred from the pipeline side: the "Oldest waiting job by queue" panel on the
Postgres dashboard, and the symptoms described under
[Recognising a database that cannot keep up](SCALING.md#recognising-a-database-that-cannot-keep-up).

The existing **AWS RDS** dashboard stays as the raw CloudWatch reference — every
metric RDS emits. This one answers a single question.

## Grafana admin password

Generated on install and kept across upgrades:
`kubectl get secret <release>-grafana -n <ns> -o jsonpath='{.data.admin-password}' | base64 -d`.
`helm template` generates a new one on every render; point
`kube-prometheus-stack.grafana.admin.existingSecret` at your own Secret instead.

## Bringing your own Prometheus and Grafana

The dashboards are plain ConfigMaps and Secrets labelled `grafana_dashboard` and
`grafana_datasource`, so any Grafana running the standard sidecar picks them up.
Nothing requires our Prometheus stack.

If you bring your own grafana and prometheus stack you need to explicitly turn on dashboards:
**nothing switches itself on**, because this chart cannot wire a Grafana it did
not install.

```yaml
monitoring:
  enabled: false
  dashboards:
    enabled: true        # pipeline overview
  postgresDashboards:
    enabled: true        # Postgres datasource + GoodJob tables
                         # MatchCore tiers follow this one
```

> **The Postgres datasource is read-only SQL access to your database.** Queue
> depth and job tables come from querying the application's database directly,
> so anyone who can use Explore in your Grafana can run arbitrary `SELECT`
> statements against the tables listed in
> [Database roles this chart creates](README.md#database-roles-this-chart-creates). It is
> read-only and scoped to five tables, but it is still direct database access —
> treat Grafana access accordingly.

`matchDashboards` reads its job tables through the Postgres datasource, so it
follows `postgresDashboards` and you do not need to name it. Setting
`matchDashboards: true` **without** `postgresDashboards` renders the dashboard
anyway — its Prometheus panels work and its two SQL panels stay empty.

Then two things are yours to do:

**1. Give your Grafana the Grafana role's password as an environment variable.**
The datasource reads it with `$__env{PLATFORM_GRAFANA_PG_PASSWORD}`:

```yaml
envValueFrom:
  PLATFORM_GRAFANA_PG_PASSWORD:
    secretKeyRef:
      name: platform-grafana-postgres-ro
      key: password
      optional: true
```

Grafana reads the variable at pod start. If it is unset the datasource has no
password and its panels fail with an authentication error, so set it before
enabling `postgresDashboards`.

If you run with `monitoring.postgresDashboards.autoCreateRole: false`,
the role and its Secret are yours to create too — see
[The Grafana database role](#the-grafana-database-role).

**2. Make sure your Prometheus selects them.** Your `ServiceMonitor` and
`PodMonitor` selectors have to reach this namespace, and KEDA's, for queue depth.
The bundled stack sets `serviceMonitorSelectorNilUsesHelmValues: false` for
exactly this reason.

## The Grafana database role

Grafana's Postgres datasource uses its own read-only role, `db_grafana_ro`, with
`SELECT` on the five tables the dashboards read: `good_jobs`,
`good_job_processes`, `jobs`, `ingest_masters` and `materials`. The datasource
runs whatever SQL someone types into Explore, which is why it never uses the
application's database user. How the chart creates this role, and why it is
separate from KEDA's, is in
[Database roles this chart creates](README.md#database-roles-this-chart-creates).

Configure it with `monitoring.postgresDashboards.roleName` and
`monitoring.postgresDashboards.autoCreateRole`. With `autoCreateRole: false`,
create the role yourself:

```sql
CREATE ROLE db_grafana_ro LOGIN PASSWORD 'choose-a-strong-password';
GRANT CONNECT ON DATABASE your_database_name TO db_grafana_ro;
GRANT USAGE ON SCHEMA public TO db_grafana_ro;
GRANT SELECT ON good_jobs, good_job_processes, jobs, ingest_masters, materials TO db_grafana_ro;
```

Then store its password in the Secret your Grafana mounts (see step 1 of
[Bringing your own Prometheus and Grafana](#bringing-your-own-prometheus-and-grafana)).
If a grant is missing, the panels that read that table show a permissions error.

## PodMonitor and ServiceMonitor

The chart uses Prometheus PodMonitor and ServiceMonitor resources to automatically discover and scrape metrics from pods and services. This ensures metrics collection adapts as pods are created, scaled, or replaced, providing reliable observability for all workloads.

If your cluster does not include support for `PodMonitor` or `ServiceMonitor` objects or you have not set `monitoring.enabled = true` you may disable them by setting `metrics.enabled = false`

## Backup guidance

If you enable persistence for Prometheus or Grafana, ensure you back up the associated PVCs regularly. For more information, see [Kubernetes Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/) or your cloud provider's backup tools.

## Uninstalling with persistence enabled

`helm uninstall` keeps the Prometheus and Loki volumes, so metrics and log history survive an uninstall, and reinstalling into the same namespace picks them up again. Grafana's volume is deleted with the release.

To remove the monitoring data as well, delete the PVCs after uninstalling:

```sh
kubectl get pvc -n <namespace>
kubectl delete pvc -n <namespace> <prometheus-pvc> <loki-pvc>
```

## Troubleshooting

- **No metrics in dashboards:** Check that PodMonitors/ServiceMonitors are deployed and Prometheus is scraping the correct endpoints.
- **Dashboards not loading:** Ensure Grafana is running and accessible via ingress.
- **Storage full:** Increase PVC size or clean up old data.
- **No logs:** Verify your log aggregation solution is running and pods are configured to emit logs to the correct location.

### Postgres panels fail behind a WAF

If the Postgres panels error while everything else on the same dashboard loads,
and the error text is an HTML block page rather than a database message, a web
application firewall is eating the request.

Grafana's Postgres datasource posts the literal SQL in the body of a request to
`/api/ds/query`:

```text
SELECT queue_name, ... FROM good_jobs WHERE finished_at IS NULL ...
```

Managed WAF rulesets match that as an SQL injection attempt and block it.
Cloudflare returns its "Attention Required" page, with wording about *"submitting
a certain word or phrase, a SQL command or malformed data"*. Grafana shows the
whole page as the query error.

Prometheus and CloudWatch panels are unaffected — their request bodies do not
look like SQL — so the failure is selective in a way that points at the
dashboards rather than at the proxy.

**There is nothing to change in this chart.** Posting SQL is how the datasource
works. Your options are:

- Add a WAF bypass or exception for Grafana's `/api/ds/query` path.
- Do not front Grafana with the WAF.
- Reach Grafana without going through it, which is enough for a quick check:

```bash
kubectl port-forward -n <ns> svc/<release>-grafana 3000:80
```

Then browse `http://localhost:3000`. If you set `grafana.ini` `serve_from_sub_path`
with a `root_url` ending in a path, append that path too.

Checking from inside the cluster hides this entirely — a `kubectl exec ... curl
localhost:3000` test passes while the browser fails, because only the browser
goes through the proxy.

### A datasource change that does not take effect

Dashboards and datasources reload differently, and the difference is invisible
until it bites:

- **Dashboards poll.** The sidecar writes the file, Grafana's dashboard
  provisioner rescans the directory on a timer and picks it up.
- **Datasources do not.** Grafana reads them at startup, or when something calls
  its admin provisioning API. The sidecar makes that call.

So if the sidecar cannot authenticate to Grafana, dashboards keep updating while
datasources silently stay as they were. New panels appear, pointed at an old
datasource — which looks exactly like a chart that shipped a broken dashboard.

The tell is in the Grafana pod logs:

```text
POST /api/admin/provisioning/datasources/reload → 401
error="[password-auth.failed] too many consecutive incorrect login attempts"
```

The usual cause is a Grafana admin password that no longer matches its database:
Grafana applies the Secret's password only when it first creates its database.
Reset it and restart:

```bash
PW=$(kubectl get secret <release>-grafana -n <ns> -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl exec -n <ns> deploy/<release>-grafana -c grafana -- grafana cli admin reset-admin-password "$PW"
kubectl rollout restart -n <ns> deploy/<release>-grafana
```


## Version compatibility

The monitoring subcharts need nothing beyond the chart's own [prerequisites](README.md#prerequisites) (Kubernetes 1.32+, Helm 3.16+ or Helm 4).

The chart comes with dependencies that can install Grafana, Prometheus and Loki to the cluster to provide access to log, metrics and dashboards.
These may require further configuration for your cluster's storage capabilities. You can bring your own monitoring and logging if you prefer.

On EKS:

```yaml
monitoring:
  enabled: true
  logging:
    enabled: true
  aws:
    enabled: true
    grafanaRoleArn: arn:aws:iam::<account>:role/<cluster>-grafana
    cloudwatchRoleArn: arn:aws:iam::<account>:role/<cluster>-grafana-cloudwatch
    region: <region>

## Only if the cluster has no default StorageClass, or the sizes do not suit.
kube-prometheus-stack:
  grafana:
    persistence:
      storageClassName: gp3
  prometheus:
    prometheusSpec:
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: gp3
loki:
  singleBinary:
    persistence:
      storageClass: gp3
```

The IAM roles come from the [reference architecture
terraform](https://github.com/ad-signalio/terraform-utils/blob/main/aws/tf-hosted-modules/tf-dt-iam-roles).
Volumes are not backed up; see [Backup Guidance](#backup-guidance).

## Getting the most out of your metrics

We provide these dashboards:

1. Platform Processing Pipeline Overview

This dashboard provides an overview of the Platform processing pipeline in Kubernetes. It visualizes OOM kills, CPU and memory usage, and throttling for different workload types (pods) in the "snicketlabs" namespace. The dashboard uses Prometheus metrics and supports filtering by workload type. It helps operators monitor resource usage, queue health, and pod stability for Platform workloads.

When `metrics` is enabled, Helm creates a Prometheus PodMonitor for each defined worker type. Prometheus then scrapes metrics from the worker pods in the defined namespace (default is "snicketlabs" namespace).

Use this dashboard as a jumping point to discover any lags in processing.

Enable this with:
```yaml
monitoring:
  dashboards:
    enabled: true
```

2.  AWS RDS Dashboard

This is the [Grafana provided](https://grafana.com/grafana/dashboards/707-aws-rds/) AWS RDS dashboard. Here you can visualise key performance and health metrics for your Amazon RDS database.

Use this dashboard to quickly identify performance bottlenecks and resource saturation.

Enable this with:
```yaml
monitoring:
  aws:
    enabled: true
    cloudwatchRoleArn: arn:aws:iam::$YOUR_AWS_ACCOUNT_NUMBER_HERE$:role/$YOUR_CLUSTER_NAME_HERE-grafana-cloudwatch
    region: $YOUR_REGION
```

3. Postgres Dashboard

The Postgres dashboard provides real-time visibility into your PostgreSQL database performance, including metrics like query throughput, cache hit rates, replication lag, and resource usage. It helps monitor database health, detect slow queries, and identify bottlenecks or abnormal behavior.

Use this dashboard to troubleshoot database issues, optimise performance, and ensure reliable operation of your Postgres instance.

Enable this with:
```yaml
monitoring:
  postgresDashboards:
    enabled: true
```

4. MatchCore Tiers Dashboard

A per-tier view of the MatchCore fingerprinting jobs: what is running now and against which material, wall time per minute of source, and the CPU, throttling and memory each tier uses against its envelope. Use it to tell whether a tier needs resizing.

It reads the job tables through the Postgres datasource, so it needs the Postgres dashboards enabled as well. Its CPU, throttling and memory panels come from Prometheus, so they also need `monitoring.enabled: true` or your own Prometheus scraping the cluster; without that, only the Postgres panels show data.

```yaml
monitoring:
  postgresDashboards:
    enabled: true
  matchDashboards:
    enabled: true
```

## Alerts

The chart can install Prometheus alert rules as a `PrometheusRule`. They need the Prometheus Operator CRDs, which `monitoring.enabled: true` installs, or your own Prometheus Operator.

| Alert | Severity | Fires when |
|---|---|---|
| `PlatformTaskPodOOMKilled` | warning | A one-and-done (`scaledJobs`) task pod is killed for exceeding its memory limit |

**Why `PlatformTaskPodOOMKilled` matters.** When a task pod runs out of memory, the application only sees an interruption and retries the job as normal. A source that always runs out of memory therefore uses every retry before it fails, and the job error does not mention memory. The alert names the pod and tier. The usual fix is to raise `scaledJobs.<tier>.resources.limits.memory`. The [MatchCore Tiers Dashboard](#getting-the-most-out-of-your-metrics) shows how close each tier runs to its limit.

The alert reads `kube_pod_container_status_terminated_reason` from kube-state-metrics. On autoscaled clusters a killed pod can be deleted within a minute, so the alert stays firing for `oomKilledWindow` (15m by default) after the kill. A pod deleted before it is scraped is never seen, so the alert catches most OOM kills, not every one.

```yaml
monitoring:
  alerts:
    enabled: true
    # Only if your own Prometheus selects rules by label:
    # ruleLabels:
    #   prometheus: main
    # Added to every alert, e.g. for Alertmanager routing:
    # alertLabels:
    #   team: platform
```

This chart does not configure Alertmanager. The bundled kube-prometheus-stack example above disables it, so alerts show in Grafana (**Alerting → Alert rules**) and in the Prometheus UI. To get notified, enable and configure Alertmanager in `kube-prometheus-stack`, or point your own Alertmanager at Prometheus.

> Please consult with Snicket Labs technical services for monitoring configuration.
