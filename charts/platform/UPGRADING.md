# Upgrade notes

`platform` 1.0.0 was the first public release.

## 3.0.0 — Loki 3 replaces loki-stack

`monitoring.logging.enabled` now installs Loki 3 and Alloy instead of
loki-stack (Loki 2.6 and promtail). Logs Drilldown and the datasource health
check work. kube-prometheus-stack goes from 78.4.0 to 93.4.1 (Grafana 13).

Change your values before upgrading; the chart refuses to render otherwise:

- Delete the `loki-stack:` block.
- Replace `monitoring.awsDashboards` with `monitoring.aws`:

  ```yaml
  monitoring:
    aws:
      enabled: true
      grafanaRoleArn: <was kube-prometheus-stack.grafana.serviceAccount.annotations>
      cloudwatchRoleArn: <was awsDashboards.cloudwatch.assumeRoleArn>
      region: <was awsDashboards.cloudwatch.defaultRegion>
  ```

- Optionally delete `kube-prometheus-stack.grafana.ingress` and its
  `grafana.ini` `root_url`: Grafana is now served at `/grafana` on the
  platform's own host.

Now pinned by the chart, so they can come out of your values:
`crds.upgradeJob`, `alertmanager.enabled: false`, Grafana persistence and
`Recreate` strategy, and the Grafana service account.

Alertmanager is now off. Set `kube-prometheus-stack.alertmanager.enabled: true`
to keep it.

Old logs are not migrated. Loki 2.6's volume (`storage-<loki name>-0`) is left
in place and no longer read. Delete it once you no longer need those logs:

```sh
kubectl delete pvc -n <namespace> storage-<loki name>-0
```

## 2.3.1 — Grafana generates its admin password

The chart never set `kube-prometheus-stack.grafana.adminPassword`, so every
install inherited kube-prometheus-stack's published default, `prom-operator`,
and every upgrade wrote it back into the `<release>-grafana` Secret. The chart
now sets it to `""`, so the grafana subchart generates a random password on
first install and keeps it across upgrades.

**New installs** need nothing.

**Existing installs keep the password their Secret holds today**, usually
`prom-operator`, because the chart reuses an existing Secret. Expect one Grafana
restart on the upgrade. To replace `prom-operator`, delete the Secret, upgrade,
then reset Grafana's database to the new value. The steps are under "A datasource
change that does not take effect" in the chart README. Wait five minutes before
logging in: the reset does not clear a login lockout that is already in place.

If your values set `adminPassword` or `admin.existingSecret` yourself, nothing
changes. If you render with `helm template` or deploy with Argo CD, set one of
the two: those tools cannot read the existing Secret back, so a generated
password would change on every render.

## 2.3.0

Two changes: web and the generic worker now run two pods behind a
PodDisruptionBudget, and Grafana's RBAC is namespaced.

### Web and the generic worker run two pods behind a PodDisruptionBudget

Web and `scaledObjects.generic` used to run a single pod with no
PodDisruptionBudget. A node drain or Karpenter consolidation evicted that pod,
so web was unreachable, and generic jobs stopped being picked up, until the
replacement pod was Ready.

| Value | Was | Now |
|---|---|---|
| `webServers.replicas` | `1`, but the template ignored it, so web was always 1 pod | `2`, now honoured |
| `scaledObjects.generic.minReplicaCount` | `1` | `2` |
| `webServers.pdb` / `scaledObjects.generic.pdb` | none | `enabled: true` (renders `maxUnavailable: 1`) |

Expect one more web pod (1 CPU / 1Gi requested) and one more generic worker
(300m / 300Mi). Expect up to 15 more Postgres connections from the extra web
pod (`railsMaxThreads`). Check that your database's `max_connections` has the
headroom.

To keep one pod, set `webServers.replicas: 1` and/or
`scaledObjects.generic.minReplicaCount: 1`. With one pod, choose deliberately
between `pdb.enabled: false` (evictions cause a short outage) and
`pdb.minAvailable: 1` (no outage, but node drains wait for the node's
termination grace period). Set at most one of `minAvailable` and
`maxUnavailable`. Any other scaledObject can opt in with its own `pdb` block.

### Grafana's RBAC is namespaced

Grafana's sidecars read ConfigMaps and Secrets in Grafana's own namespace, via
a Role. They previously did it via a ClusterRole granting `get/watch/list` on
configmaps and secrets in **every** namespace.

Nothing changes in what Grafana can do, because the sidecars only ever read
their own namespace: `sidecar.*.searchNamespace` is unset and they default to
it. The cluster-wide grant was never used.

**If you set any `sidecar.*.searchNamespace` to another namespace**, set
`kube-prometheus-stack.grafana.rbac.namespaced: false` or that sidecar stops
finding what it reads. A namespaced Role cannot read another namespace.

## 2.2.0 — Grafana runs under its own service account

Grafana now gets a dedicated service account, `grafana`. This guide previously
told you to point it at the application's, which gave Grafana the application's
cloud identity; on EKS that identity denies `sts:AssumeRole` account-wide, so
the CloudWatch datasource could never authenticate.

If your values file sets `kube-prometheus-stack.grafana.serviceAccount`, drop
it. Grafana restarts on upgrade.

**On EKS, before upgrading**, if you use `monitoring.awsDashboards`: create an
IAM role trusting `system:serviceaccount:<namespace>:grafana` that may assume
the role in `monitoring.awsDashboards.cloudwatch.assumeRoleArn`, then annotate
the service account with it.

```yaml
kube-prometheus-stack:
  grafana:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<cluster>-grafana
```

Without the annotation the CloudWatch datasource fails to authenticate. Nothing
else is affected; on-prem and GKE need no action.

## 2.1.0 — six unused scaledJobs have been removed

These scaledJobs consumed queues that the application no longer enqueues to, so
their pods never ran:

| scaledJob | queue |
|---|---|
| `ingest-attach-image` | `video_match_frames_attach_image_tasks` |
| `process-compare-results` | `compare_materials_results` |
| `process-extract` | `video_match_frames_extract_tasks` |
| `process-video-fingerprint` | `video_match_frames_fingerprint_tasks` |
| `process-frames` | `process_frames` |
| `process-ingest-frames` | `ingest_frames` |

Nothing changes at runtime. If your values file sets any of these keys, delete
them; Helm now rejects them with `Must not validate the schema (not)` so a
stale override fails loudly rather than being silently ignored.

`process-extract-frames` is a different scaledJob and is unaffected.

## 2.1.0 — dashboards now follow `monitoring.enabled`

`monitoring.dashboards`, `monitoring.matchDashboards` and
`monitoring.postgresDashboards` used to default to `false`. They now default to
unset, and unset means "follow `monitoring.enabled`".

**If you run the stack this chart installs** (`monitoring.enabled: true`), you
will get dashboards you did not have before — the MatchCore tier view, the
GoodJob tables, and a Postgres datasource to serve them. The chart mounts the
datasource's password into Grafana for you, so there is nothing to wire.

Nothing is removed, and the extra resources are a datasource Secret and two
ConfigMaps. If you would rather not have them, name them:

```yaml
monitoring:
  enabled: true
  matchDashboards:
    enabled: false
  postgresDashboards:
    enabled: false
```

**If you bring your own Prometheus and Grafana**, nothing changes. These flags
only switch themselves on when this chart installs Grafana, because it cannot
mount a password into a Grafana it does not own. Carry on setting them
explicitly — see "Bringing your own Prometheus and Grafana" in the docs.

**One behaviour worth knowing either way:** Grafana will not start with a
datasource it cannot provision. Enabling `postgresDashboards` against your own
Grafana without mounting the KEDA role's password takes Grafana down rather than
leaving a dashboard blank.

**If the datasource still shows the old user after upgrading**, the sidecar could
not tell Grafana to reload it. Dashboards poll and refresh themselves;
datasources only load at startup or via Grafana's admin API. A Grafana admin
password that no longer matches its persisted database breaks that call, so the
new dashboards appear against the old datasource. See [A datasource change that
does not take effect](MONITORING.md#a-datasource-change-that-does-not-take-effect).

**Upgrading through Distr may need Force Conflicts.** Helm 4 applies with
server-side apply and will not take fields another manager owns — here the
ScaledJob `maxReplicaCount`s and the Grafana secret mount, both of which this
release changes. Tick it on the deployment and re-run.

### The Grafana Postgres datasource no longer uses your application credentials

It previously read username, password, host, port and database from whatever you
mounted at `/etc/secrets` — which the docs told you to point at the reference
architecture's `*-rds-pg` Secret, the application's own database credentials.
Grafana's Postgres datasource runs arbitrary SQL from Explore, so that made a
dashboard a route to writing to your production database.

It now uses `db_keda_ro`, which holds `SELECT` on `good_jobs` and
`good_job_processes` and nothing else, and only the password is mounted.

If you had `postgresDashboards` enabled with the old mount, replace it:

```yaml
extraSecretMounts:
  - name: pg-secrets
    secretName: platform-keda-postgres-ro
    mountPath: /etc/secrets
    readOnly: true
    optional: true
    items:
      - key: password
        path: password
```

Users of the bundled stack need not do anything — this is now the default.

### The Grafana role password is an environment variable, not a file

The Postgres datasource used to read the Grafana role's password with
`$__file{/etc/secrets/password}`, from a file mounted through `extraSecretMounts`.
It now reads `$__env{PLATFORM_GRAFANA_PG_PASSWORD}`, set through `envValueFrom`.
Every upgrade recreates the Secret, and the file briefly disappearing made Grafana
re-provision its datasource with no password.

If you mounted the file yourself, delete that `extraSecretMounts` entry and set
`envValueFrom` as shown in [MONITORING.md](MONITORING.md). The bundled stack needs
no change.

## 2.0.0 — the `environment-sizes` presets have been removed

`environment-sizes/small`, `/medium` and `/large` no longer ship with the chart.
If you deploy with `-f environment-sizes/<size>/<size>.yaml`, remove that flag or
Helm will fail on the missing path.

The presets predated autoscaling. They fixed a static number of workers against a
fixed database size, and the numbers were as much guesswork as measurement. The
chart scales pods to demand, so `values.yaml` now carries one set of defaults.

**What changes for you depends on which preset you were using:**

| You were on | Effect |
|---|---|
| `small` | No change. It was the 1x baseline and matched the `values.yaml` defaults already. |
| `medium` | **Scaling ceilings drop.** It applied 2x the baseline. |
| `large` | **Scaling ceilings drop.** It applied 3x the baseline. |

On `medium` or `large`, your workers could previously scale to 2x or 3x the new
defaults. Nothing breaks — KEDA only ever scaled to demand, and the ceiling was a
cap, not a reservation — but under sustained load you will see less parallelism
than before.

If you were running at those ceilings deliberately, keep them. Put the values you
need in your own values file and pass it with `-f`, exactly as the preset did:

```yaml
# your-scaling-overrides.yaml
scaledObjects:
  generic:
    maxReplicaCount: 6
scaledJobs:
  ingest-proxy-generate:
    maxReplicaCount: 10
  # ...
```

The previous preset files are in this repository's git history if you want to
start from exactly what you had.

**Separately, the MatchCore fingerprinting tiers now default to a higher ceiling.**
The `*-matchcore` scaledJobs were never listed in the presets, so they ran at the
same ceiling on every size. They now default to 5, matching
`materialProcessingCount`, so no stage caps throughput below what the application
admits. `j2k-uhd-matchcore` stays at 1; the reason is recorded against it in
`values.yaml`.

If your cluster cannot schedule the extra pods, they stay pending and KEDA keeps
working through the queue — but check your node capacity and quotas before
upgrading under load.

## Coming from the `adsignal-match` chart?

There is no upgrade path, and this is deliberate. `platform` is a fork of
`adsignal-match`, not a rename of it: the chart name, the registry, the
namespace and most in-cluster resource names all changed, so Helm has no way to
reconcile one against the other.

Deploy `platform` into a fresh namespace. The `adsignal-match` chart continues
to be published from `ad-signalio/helm-match` for environments already running
it.
