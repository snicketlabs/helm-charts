<!---
title: Platform Self Hosted Helm Chart
folder: "Technical Documentation"
status: 2
-->
<!-- AUTO-GENERATED — do not edit. Source: docs/README.md + README-generated.md.gotmpl. Regenerate with: make docs -->

![Version: 3.0.0](https://img.shields.io/badge/Version-3.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.0.0](https://img.shields.io/badge/AppVersion-4.0.0-informational?style=flat-square)

Snicket Labs Platform Self Hosted

**Homepage:** <https://snicketlabs.io>

# Platform Self Hosted Helm Chart

## Upgrading

See [UPGRADING.md](UPGRADING.md) for version-specific upgrade instructions.

## Overview

This chart will install a self hosted Platform service.

It is strongly suggested that you run this chart on a Kubernetes cluster dedicated to the platform. We provide a reference implementation suitable
for AWS [here](https://github.com/snicketlabs/reference-architecture)

## Prerequisites

A Kubernetes cluster (1.32+) with [KEDA](https://keda.sh/) installed, Helm 3.16+ or Helm 4 (both are tested), and the following facilities:

KEDA is a hard requirement, not an option. Every worker in this chart is a KEDA
ScaledObject or ScaledJob; there is no static Deployment fallback. Install it
before the first deploy — see [KEDA Autoscaling](#keda-autoscaling) below, which
also covers scraping KEDA's metrics, the chart's only source of queue depth.

### Scratch Storage (/tmp)

Source media is not copied to local disk, so scratch space does **not** need to
scale with the size of your content. MatchCore fingerprinting reads video files
in place from a presigned URL. Image sequences (TIFF) are the one source the
application downloads itself, and it streams the frames into MatchCore through a
pipe rather than staging the sequence on disk.

Pods run with a read-only root filesystem, and the only writable path is `/tmp`,
a disk-backed `emptyDir` on the node. The application works in a directory under
it, `storage.tmpStorage.path` (default `/tmp/app_tmp`), which must stay inside
`/tmp`. MatchCore jobs use it to encode the browse proxy, which at the default
settings (640x360, 20 fps) takes up to about 1GB per 2.5 hours of content. Each
MatchCore scaledJob requests `ephemeral-storage: 1Gi`, so the scheduler reserves
node disk for it, and is capped at `4Gi`, so a job that overruns is evicted
rather than filling the node.

The 4Gi cap is enough for sources up to about 10 hours long. If you ingest longer
content, raise the tier's `ephemeral-storage` limit, or long ingests will be
evicted part-way through.

When sizing node root volumes, allow up to 4Gi for each MatchCore job that can run
on the node at once, plus images and logs. Other workers also use `/tmp`, but
they carry no `ephemeral-storage` request, so leave headroom above that figure.
You do not need hundreds of gigabytes of scratch.

The `/tmp` volume has no size limit by default. You can set one, but the per-job
`ephemeral-storage` limits are the better control:

```yaml
storage:
  tmpStorage:
    enabled: true
    path: /tmp/app_tmp   # must be under /tmp
    # sizeLimit: 20Gi
```

Do not set `tmpStorage.enabled: false` or mount your own volume over `/tmp`. The
chart still installs, but every pod then fails at runtime because the
application has nowhere to write.

> Please consult with Snicket Labs technical services for sizing recommendations.

#### Entrypoint

Note: The platform image includes an entrypoint script that handles the setting of permissions for the emptyDir volumes.

### S3 Buckets

The application makes use of two types of S3 buckets:

- **Primary Bucket**: This is the main storage bucket for the application where artifacts such as thumbnails or proxy videos are stored.

- **Content Bucket**: These are buckets containing the source media files that you wish to ingest into the system.

`s3.primaryBucket` and `s3.region` are both required and have no defaults. Install fails with the offending value named if either is missing:

```yaml
s3:
  primaryBucket: my-primary-bucket
  region: eu-west-2          # the region the bucket and cluster are in
```

Set `s3.region` to the region your primary bucket is actually in. It also selects the regional STS endpoint used for IRSA credentials, so a value that does not match the bucket is not limited to S3: requests pay an extra redirect and credentials are vended from the wrong region.

### S3-Compatible Primary Storage (Non-AWS)

By default Platform uses AWS S3 for its primary storage (thumbnails, proxy videos, and other artifacts), authenticated via IRSA. If you are running on-premises or on a cloud that provides an S3-compatible object store (e.g. Ceph RGW, MinIO, GCS S3-interop), you can point Platform at that instead.

Configure the following `s3` values in your values file. Each value sets a corresponding environment variable that the application reads at runtime:

| Value | Env var set | Required | Description |
|---|---|---|---|
| `s3.primaryBucket` | `S3_PRIMARY_BUCKET` | Yes | Name of the bucket to use for primary storage |
| `s3.region` | `COMPATIBLE_S3_REGION`, `AWS_REGION` | No | Region string — most non-AWS stores ignore this, but the SDK requires it (default: `us-east-1`) |
| `s3.compatibleEndpoint` | `COMPATIBLE_ENDPOINT_URL_S3` | Yes | Full URL of the S3-compatible endpoint that pods use for all S3 operations (e.g. `http://my-ceph-rgw:80`) |
| `s3.compatiblePublicEndpoint` | `COMPATIBLE_PUBLIC_ENDPOINT_URL_S3` | No | Browser-reachable URL for the same store, when it differs from `s3.compatibleEndpoint` (see below) |
| `s3.compatibleCredentialsSecret` | — | Yes | Name of a Kubernetes Secret containing HMAC credentials (sets `COMPATIBLE_S3_ACCESS_KEY` / `COMPATIBLE_S3_SECRET_KEY`) |
| `s3.compatibleAccessKeyField` | — | No | Key name within `compatibleCredentialsSecret` for the access key ID (default: `access_key_id`) |
| `s3.compatibleSecretKeyField` | — | No | Key name within `compatibleCredentialsSecret` for the secret access key (default: `secret_access_key`) |
| `s3.compatibleForcePathStyle` | `COMPATIBLE_S3_FORCE_PATH_STYLE` | No | Use path-style S3 URLs — `"true"` or `"false"` (default: `"true"`). Required by Ceph, MinIO, and GCS S3 interop. Only set to `"false"` if your store explicitly uses virtual-hosted style URLs. |

These values only take effect when `s3.compatibleEndpoint` is set. When it is not set, Platform falls back to AWS S3 via IRSA with no static credentials required.

#### GCS (Google Cloud Storage S3-interop) example

```yaml
s3:
  primaryBucket: my-gcs-bucket-name
  region: "auto"
  compatibleEndpoint: "https://storage.googleapis.com"
  compatibleCredentialsSecret: gcs-hmac-credentials   # Secret with keys access_key_id / secret_access_key
```

GCS S3-interop uses a single endpoint reachable from both pods and browsers, so `compatiblePublicEndpoint` is not required.

#### Ceph / MinIO (in-cluster) example

```yaml
s3:
  primaryBucket: my-bucket-name
  region: "us-east-1"
  compatibleEndpoint: "http://my-object-store.internal:80"
  compatibleCredentialsSecret: my-s3-credentials   # Secret with keys access_key_id / secret_access_key
```

If your credentials Secret uses different key names (e.g. a Rook OBC-created Secret uses `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), override them:

```yaml
s3:
  primaryBucket: my-bucket-name
  region: "us-east-1"
  compatibleEndpoint: "http://rook-ceph-rgw.rook-ceph.svc:80"
  compatibleCredentialsSecret: my-obc-secret
  compatibleAccessKeyField: "AWS_ACCESS_KEY_ID"
  compatibleSecretKeyField: "AWS_SECRET_ACCESS_KEY"
```

#### Split internal/external endpoint (`s3.compatiblePublicEndpoint`)

If the endpoint pods use to reach your object store is not reachable from browsers (for example a Ceph RGW exposed only as a Kubernetes ClusterIP service), presigned URLs embedded in page responses will fail in the browser.

Set `s3.compatiblePublicEndpoint` to a URL that browsers can reach (for example a MetalLB LoadBalancer IP or a hostname routable over VPN). Platform will continue using `s3.compatibleEndpoint` for all pod-to-S3 operations and will use `s3.compatiblePublicEndpoint` only when generating presigned URLs returned to clients.

```yaml
s3:
  primaryBucket: my-bucket-name
  compatibleEndpoint: "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80"  # internal ClusterIP
  compatiblePublicEndpoint: "http://10.35.7.108"  # MetalLB LoadBalancer IP, reachable from browsers
  compatibleCredentialsSecret: my-s3-credentials
```

If `COMPATIBLE_PUBLIC_ENDPOINT_URL_S3` is not set, presigned URLs use the same host as `COMPATIBLE_ENDPOINT_URL_S3`. This is correct for any setup where the object store endpoint is already reachable from browsers.

#### Alternatives to the split endpoint

`COMPATIBLE_PUBLIC_ENDPOINT_URL_S3` is only needed when your primary S3-compatible store is deployed inside the cluster (or otherwise has a different address for pods than for browser clients). This is typical of in-cluster Ceph RGW, MinIO, or similar stores exposed only via a ClusterIP service. If your object store already has a single address reachable from both pods and browsers — for example, an external MinIO instance or a managed S3-compatible service — you can omit `COMPATIBLE_PUBLIC_ENDPOINT_URL_S3` entirely.

Where a split is unavoidable, the following infrastructure options let you collapse it to a single address, which is preferable because the split-endpoint path patches Rails' presigned URL generation and could be affected by future Rails upgrades.

**Option A — Use the LoadBalancer IP for everything (simplest)**

If you are already exposing your object store via a LoadBalancer (e.g. MetalLB), set `s3.compatibleEndpoint` to that IP and omit `s3.compatiblePublicEndpoint`:

```yaml
s3:
  compatibleEndpoint: "http://10.35.7.108"   # LoadBalancer IP — reachable from both pods and browsers
```

Pod traffic to the LoadBalancer IP is typically handled by kube-proxy DNAT rules without leaving the cluster. Verify this works on your CNI before relying on it — on some configurations traffic will physically hairpin out of the cluster and back in, which adds latency but still works.

**Option B — DNS split-horizon**

Configure a single hostname (e.g. `s3.cluster.example.com`) that resolves to the object store's ClusterIP internally (via a CoreDNS override) and to the LoadBalancer IP externally (via VPN or external DNS). Both pods and browsers use the same hostname; no split endpoint config is needed. This avoids any hairpin and is the most efficient option, but requires coordinating cluster DNS and external/VPN DNS.

**Option C — Ingress with a real hostname and TLS**

Put an NGINX or Traefik ingress in front of your object store, backed by a DNS record and TLS certificate. Both pods and browsers use `https://s3.customer.example.com`. This is the most robust long-term option and is recommended if your deployment already has a working ingress controller and certificate management.

#### What breaks if COMPATIBLE_PUBLIC_ENDPOINT_URL_S3 is misconfigured

Only operations that send a presigned URL to a browser are affected:

- **Manual file upload via the UI** — fails with a CORS or DNS error (browser cannot PUT to the presigned URL)
- **Video and media playback in the UI** — fails to load (presigned GET URL contains the wrong host)

Operations that are unaffected (all server-side, no presigned URLs sent to browsers):

- API material creation via `media.url` — the server fetches the file directly, no presigned URL involved
- Ingest source scanning and auto-ingest
- All other background processing

Customers who create materials exclusively via the API (providing a source URL rather than uploading a file) do not need `COMPATIBLE_PUBLIC_ENDPOINT_URL_S3` and are unaffected if it is absent or misconfigured.

#### Bucket CORS configuration

Platform uploads files directly from the browser to the object store using presigned PUT URLs. The bucket must have a CORS policy that allows requests from the Platform domain, otherwise uploads will fail with a 403 CORS error.

Set the CORS policy using the AWS CLI (or any S3-compatible client) against your public endpoint, replacing `https://snicketlabs.example.com` with your `domain` value:

```bash
aws s3api put-bucket-cors \
  --endpoint-url <your-s3.compatiblePublicEndpoint-or-s3.compatibleEndpoint> \
  --bucket <your-bucket-name> \
  --region <your-region> \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedOrigins": ["https://snicketlabs.example.com"],
      "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }]
  }'
```

This only needs to be run once per bucket. It persists in the object store independently of Helm deployments, but must be re-applied if the bucket is recreated.

> AWS S3 users should configure CORS via the bucket policy in the reference architecture Terraform rather than the CLI.

### Optional Content via S3 Compatible API

Content to ingest may be provided to the application via an S3 compatible endpoint.
Static Access Keys and Secret credentials to access an S3 compatible endpoint may be provided in Platform's web interface.

#### Credentials via AWS IAM with Kubernetes Service Account (IRSA)

For content in an AWS S3 bucket an IAM Role assumable by a Kubernetes service account (IRSA) in an EKS pod may also be used by providing a IAM role ARN to annotate
the Service Account with.  See the AWS IAM Roles for service accounts [documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) for further information on how to configure the IAM role and EKS cluster.

```
serviceAccount:
  annotations:
   eks.amazonaws.com/role-arn: "arn:aws:iam::111122223333:role/my-role"
```

## Postgres Database

**The chart does not provision a database.** Supply your own — a managed service
such as AWS RDS, an in-cluster operator such as CloudNativePG, or any Postgres
the cluster can reach. Backups and high availability are yours to configure.

A host is required. Rendering fails with a named error if neither
`postgres.primaryHost` nor `postgres.dbPrimaryHostSecret` is set.

```yaml
postgres:
  primaryHost: my-external-database.example.internal
  port: 5432
  auth:
    username: platform
    database: platform
  passwordSecret:
    name: postgres-password # The name of the secret that contains the Postgres password.
    key: password # The key in the secret that contains the Postgres password.
```

An example secret to provide the password:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-password
type: Opaque
data:
  password: bXlfc3VwZXJfc2VjcmV0X3Bhc3N3b3Jk== # Base64 encoded password
```

### Reading the rest of the connection from a Secret

The username, database name, host and port can each come from a Secret instead
of a plain value. Use as many as suit how your credentials are stored:

```yaml
postgres:
  userNameSecret:
    name: postgres-credentials
    key: username
  dbNameSecret:
    name: postgres-credentials
    key: db_name
  dbPrimaryHostSecret:
    name: postgres-credentials
    key: host
  dbPortSecret:
    name: postgres-credentials
    key: port
```

`dbPrimaryHostSecret` hides the host from the chart at render time, and KEDA
needs a literal one — set `kedaAutoScaling.postgres.host` as well when you use it.

## Database roles this chart creates

The chart creates two **read-only** Postgres roles. Neither can write, and neither
is the application's own database user. If you are reviewing what this chart does
to your database, this is the whole list.

| Role | Used by | `SELECT` on | Turn off with |
|---|---|---|---|
| `db_keda_ro` | KEDA's scalers, to read queue depth | `good_jobs`, `good_job_processes` | `kedaAutoScaling.postgres.autoCreateRole: false` |
| `db_grafana_ro` | Grafana's Postgres datasource | the above plus `jobs`, `ingest_masters`, `materials` | `monitoring.postgresDashboards.autoCreateRole: false` |

Both are created and converged by the database preparation Job on every install
and upgrade, each with its own generated password held in its own Secret. Rename
either with the matching `roleName`.

They are separate on purpose. The two want different tables, and a role named for
one consumer being quietly relied on by another is how dashboards ended up
depending on KEDA's grants.

Neither is granted `pg_read_all_data`, `pg_monitor` or anything else broad. A
table the chart cannot grant on never fails your install — KEDA's role is the one
exception, because without `good_jobs` it cannot scale at all and silently not
scaling is worse than failing.

Setting either to `false` leaves that role to you; the `GRANT` statements are in
[Manual setup](#keda-autoscaling) below and alongside the Grafana datasource.
Nothing else in the chart touches database permissions.

## KEDA Autoscaling

Platform uses [KEDA (Kubernetes Event Driven Autoscaling)](https://keda.sh/) to scale GoodJob workers on queue depth in Postgres, creating pods on demand when work is available and scaling to zero when queues are empty. All job processing runs this way. Without KEDA installed the install fails: the chart creates ScaledObject and ScaledJob resources, and the API server rejects them when the CRDs are absent.

### Prerequisites

**KEDA Installation Required**

KEDA must be installed on your Kubernetes cluster before you deploy Platform. Platform supports KEDA v2.x.

Install KEDA using Helm:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

Or follow the [KEDA installation documentation](https://keda.sh/docs/latest/deploy/).

**Scrape KEDA's metrics if you want the dashboards**

KEDA's operator exposes `keda_scaler_metrics_value` on port 8080, one series per
trigger. Because every worker here scales on a Postgres query counting rows in
`good_jobs`, that value *is* the queue depth for each queue — for ScaledJobs and
ScaledObjects alike.

This is the only queue-depth source the chart has, so if it is not scraped the
pipeline dashboards have nothing to draw.

KEDA's own chart can create the ServiceMonitor for you:

```bash
helm install keda kedacore/keda --namespace keda --create-namespace \
  --set prometheus.operator.enabled=true \
  --set prometheus.operator.serviceMonitor.enabled=true
```

**Both flags are needed.** `prometheus.operator.enabled` is what exposes the
metrics; `serviceMonitor.enabled` only creates the object that scrapes them.
Setting the second alone renders no ServiceMonitor at all, silently.

Already running KEDA? Same two values on an upgrade:

```bash
helm upgrade keda kedacore/keda -n keda --reuse-values \
  --set prometheus.operator.enabled=true \
  --set prometheus.operator.serviceMonitor.enabled=true
```

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

**Kubernetes Version**

- Kubernetes 1.32+ is required (the minimum version the chart is tested against).

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

### Postgres Connection Configuration

> Workers run `good_job start` and scaledJobs run `good_job:perform_inline_task[<queue>]`. GoodJob has no queue weights: when a worker's queues have different `priority` values they are claimed in strict order, highest first, and when they are all equal GoodJob takes jobs from any of them by priority and creation time. Each worker's `concurrency` and `shutdownTimeout` set its GoodJob thread count and shutdown timeout. `kedaAutoScaling.postgres.host` must be set whenever the chart can't work out the database host itself (for example `postgres.dbPrimaryHostSecret`), and rendering fails with a message if it isn't. See the `goodJob` values for polling, probe and grace-period settings. scaledJob task pods drain for `goodJob.shutdownTimeout` seconds (600 by default) after a termination signal and get `terminationGracePeriodSeconds` of that plus `goodJob.shutdownGraceSeconds` (60). A task still running after the drain is interrupted and retried, and counts towards its retry limit, so set `goodJob.shutdownTimeout` to cover your longest tasks.

KEDA polls the `good_jobs` table directly (via a `postgresql`-type trigger). This needs a dedicated, read-only Postgres role — not your application's own DB user — so KEDA's blast radius is limited to counting rows in `good_jobs` and `good_job_processes`.

**Automatic setup (default: `kedaAutoScaling.postgres.autoCreateRole: true`)**

The database preparation Job, on install and on every upgrade, also creates (or converges) a `db_keda_ro` role and grants it `SELECT` on `good_jobs` and `good_job_processes` only — never broader access like `pg_read_all_data`. The role's password is generated once and stored in a Secret that's stable across upgrades.

Grafana's Postgres datasource gets its **own** role, `db_grafana_ro`, created by the same Job and in the same way. It holds `SELECT` on `good_jobs`, `good_job_processes`, `jobs`, `ingest_masters` and `materials` — the five tables the dashboards read — and nothing else.

It is deliberately not KEDA's role. The two want different tables, and a role named for one consumer being quietly relied on by another is how dashboards ended up depending on KEDA's grants. Configure it under `monitoring.postgresDashboards.roleName` and `.autoCreateRole`.

Either way the datasource never runs as the application's database user. It executes whatever SQL someone types into Explore, so it gets read-only access to the tables the dashboards need and no more.

With `autoCreateRole: false` the role is yours to create:

```sql
CREATE ROLE db_grafana_ro LOGIN PASSWORD 'choose-a-strong-password';
GRANT CONNECT ON DATABASE your_database_name TO db_grafana_ro;
GRANT USAGE ON SCHEMA public TO db_grafana_ro;
GRANT SELECT ON good_jobs, good_job_processes, jobs, ingest_masters, materials TO db_grafana_ro;
```

A table the chart cannot grant on never fails your install — it logs a warning and the panels reading that table show a permissions error.

Permission problems never fail your install or upgrade: if your Postgres user doesn't have `CREATEROLE` (common if you supply your own Postgres — see below), the Job logs a warning and exits successfully. It does fail if `good_jobs` or `good_job_processes` doesn't exist after the schema is loaded, which usually means the application image doesn't include GoodJob. Check the database preparation Job's logs (`app.kubernetes.io/component: db-prepare-initial` on install, `db-prepare` on upgrades) if KEDA scaling doesn't come up — if it couldn't create the role automatically, use the manual setup below.

**Manual setup**

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
  enabled: true
  postgres:
    autoCreateRole: false
    dbUser: db_keda_ro    # or your own role name
    authenticationRef:
      secretName: my-keda-postgres-secret
```

If your Postgres host isn't resolvable from `postgres.primaryHost` (for example, you use `postgres.dbPrimaryHostSecret`), also set `kedaAutoScaling.postgres.host` explicitly — KEDA needs a literal host string at render time and can't read one from a Secret the way application env vars can.

### Worker Types

Platform provides two types of autoscaled workers:

**ScaledJobs (One-and-Done Pattern)**
- Best for CPU-intensive, long-running, or variable-duration tasks (e.g., video fingerprinting, transcoding)
- Creates ephemeral pods that process exactly one job then terminate
- Processes ONE queue per scaledJob
- Scales from 0 to maxReplicaCount based on queue depth

**ScaledObjects (HPA-like Pattern)**
- Best for lightweight, fast-processing tasks with multiple related queues
- Long-running worker deployments that scale similar to HorizontalPodAutoscaler
- Can process MULTIPLE queues per worker with configurable concurrency
- Scales between minReplicaCount and maxReplicaCount based on aggregate queue depth

The chart ships a single set of autoscaling defaults in `values.yaml`. Pods scale to demand, bounded by each worker's `maxReplicaCount`, by `materialProcessingCount`, and by what your cluster can schedule. Raise a ceiling in `your-custom-values.yaml` if a workload needs it — see [Sizing the Workloads](#sizing-the-workloads).

### Postgres panels fail behind a WAF

If the Postgres panels error while everything else on the same dashboard loads,
and the error text is an HTML block page rather than a database message, a web
application firewall is eating the request.

Grafana's Postgres datasource posts the literal SQL in the body of a request to
`/api/ds/query`:

```
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

```
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

### Upgrades and field conflicts

If an upgrade fails with an error like this, the cause is KEDA, not your values:

```
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

Deploying through distr, there is no flag to pass: tick **Force Conflicts** on
the deployment before hitting update.

The owner named in the error is not always `keda`. Deploying through distr it is
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

## Fingerprinting Resource Tuning

Video fingerprinting runs in the `*-matchcore` scaledJobs. Each one is a tier
for a kind of content: the application routes every ingest to the tier that
matches its source, and each tier has its own CPU and memory envelope.

| Tier | Content | CPU request / limit | Memory | Threads |
|---|---|---|---|---|
| `dv-matchcore` | DV | 2 / 4 | 2Gi | 4 |
| `interlaced-matchcore` | Interlaced VC-3 and DVCPRO HD 1080i | 6 / 8 | 2Gi | 4 |
| `hd-matchcore` | HD | 5 / 8 | 3Gi | 8 |
| `uhd-matchcore` | UHD / 4K | 6 / 8 | 4Gi | 8 |
| `tiff-sequence-matchcore` | TIFF image sequences | 4 / 8 | 4Gi | 8 |
| `j2k-hd-matchcore` | JPEG 2000, HD | 8 / 8 | 2Gi | 8 |
| `j2k-uhd-matchcore` | JPEG 2000, UHD / 4K | 12 / 12 | 6Gi | 12 |

**Node sizing.** The scheduler places a pod by its *request*, so each tier needs
a node with that much allocatable CPU free. The largest request,
`j2k-uhd-matchcore` at 12 CPU and 6Gi, never fits an 8 vCPU node and fits a
16 vCPU node only when little else is running on it. If you will ingest 4K JPEG
2000, provide nodes that can hold it. Raising a tier's CPU limit above the
cores its node has does nothing.

**Tuning a tier.** When you override a tier's resources:

- Keep `matchcoreThreads` no higher than the CPU limit, and leave the limit
  above it where the tier already does. The same thread count goes to both the
  fingerprinter and the proxy encoder, so a pod can use more cores than it has
  threads. Cutting the limit to equal the thread count throttles the job:
  interlaced VC-3 at threads 4 and limit 4 took 50% longer than at limit 8.
- Keep the memory request equal to the limit. An eviction mid-decode loses the
  work.
- Write quantities in canonical form; see
  [Upgrades and field conflicts](#upgrades-and-field-conflicts).

Tier figures come from benchmark measurements, not production workloads. Use the
MatchCore tiers dashboard (see [Getting the most out of your metrics](MONITORING.md#getting-the-most-out-of-your-metrics))
to compare what each tier actually uses against its envelope.

## Image Pull Secrets

Platform images and the Helm chart are hosted on the Snicketlabs registry at `registry.snicketlabs.io`. Access is controlled by a personal access token generated at **https://deploy.snicketlabs.io/settings/access-tokens**.

Log in to the registry with your token (required before pulling the Helm chart):

```bash
helm registry login registry.snicketlabs.io \
  --username ignored \
  --password <your-access-token>
```

Create a Kubernetes image pull secret in the namespace you are deploying to:

```bash
kubectl -n snicketlabs create secret docker-registry dockercredentials \
  --docker-server=registry.snicketlabs.io \
  --docker-password=<your-access-token>
```

Then reference the secret in your values file:

```yaml
imagePullSecrets:
  - name: "dockercredentials"
```

> We recommend using a secret management solution such as AWS Secrets Manager CSI Driver, External Secrets Operator, or Vault to manage this credential in production.

## Ingress and Domain

To allow access to Platform's user interface and API an Ingress must be configured, the ingress should provide TLS termination with certificates trusted by any clients you wish to connect to the interface.

This is an example ingress configuration using the AWS Load Balancer Controller.

```
ingress:
  enabled: true
  className: "alb"
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123123123:certificate/a11111-11111-11111-1111-1111
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/success-codes: "200-402"
    # Platform performs long-running comparison requests. The ALB default idle
    # timeout of 60s may cause 504 timeout errors on these requests. Increase to
    # at least 300s (5 minutes) to allow comparisons to complete.
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=300

  hosts:
    - host: snicketlabs.company.example.com
      paths:
        - path: /
          pathType: Prefix
```

The application domain must be configured the same as the Ingress.

```
domain: snicketlabs.company.example.com
```

### EKS Auto Mode

On clusters running EKS Auto Mode the built-in `eks.amazonaws.com/alb` controller is used instead of the standalone AWS Load Balancer Controller. In this mode, ALB annotations such as `alb.ingress.kubernetes.io/load-balancer-attributes` are **not supported** — they are silently ignored.

Use `ingress.ingressClassParams` to create an `IngressClassParams` resource instead, if your cluster does not already have one configured.

```yaml
ingress:
  enabled: true
  className: "snicketlabs-alb"
  annotations:
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123123123:certificate/a11111-11111-11111-1111-1111
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /up
    alb.ingress.kubernetes.io/success-codes: "200-402"
  hosts:
    - host: snicketlabs.company.example.com
      paths:
        - path: /
          pathType: Prefix

  # EKS Auto Mode: replaces the load-balancer-attributes annotation (which is ignored).
  ingressClassParams:
    create: true
    scheme: internet-facing
    loadBalancerAttributes:
      - key: idle_timeout.timeout_seconds
        value: "300"
```

Platform is intended to run on a dedicated cluster. `IngressClassParams` is cluster-scoped, so if you share a cluster across environments, only one environment should set `ingressClassParams.create: true` for a given `className`.

### DNS

A DNS entry must be configured to match the `domain` value pointing to the Ingress service providing TLS termination.

## Monitoring

Prometheus, Grafana, Loki, dashboards and alerts: see [Monitoring](MONITORING.md).

## Application Errors

The application can send error traces to honeybadger.io. This is **optional** and off by default.

> Please consult with Snicket Labs technical services for your unique API key.

### Honeybadger Configuration

Honeybadger is off while `honeybadger.environment` is empty, which is the default. In that state the chart sets no Honeybadger API key or environment on the pods, tells the application not to report (`HONEYBADGER_REPORT_DATA=false`), and the platform pods do not need a `honeybadger-api-key` secret.

> **Note**: If you sync secrets with `secrets-configuration-aws`, that chart still expects `snicketlabs-honeybadger-secret` to exist in AWS Secrets Manager whether or not Honeybadger is on. See [Prerequisites (Reference Architecture users)](#prerequisites-reference-architecture-users).

To turn on Honeybadger error tracking, you need:

1. **Honeybadger API Key and Environment Name**: These will be provided to you by Snicket Labs technical services during setup.

2. **Create a Kubernetes secret** containing your API key:

```bash
kubectl create secret generic honeybadger-api-key \
  --namespace snicketlabs \
  --from-literal=apiKey=YOUR_HONEYBADGER_API_KEY
```

3. **Configure your values file** with the environment name. Setting it is what turns Honeybadger on:

```yaml
honeybadger:
  secretName: honeybadger-api-key
  secretKey: apiKey
  environment: "your-environment-name"  # Provided by Snicket Labs
```

> **Note**: Once `environment` is set, every platform pod reads the API key from the secret. Create the secret first, or the pods fail to start with `CreateContainerConfigError`.

**If you need to use a different secret name or key**, update your values file accordingly:

```yaml
honeybadger:
  secretName: my-custom-honeybadger-secret  # Custom secret name
  secretKey: my-api-key                      # Custom key within the secret
  environment: "your-environment-name"       # Provided by Snicket Labs
```

> We recommend using a secret management solution such as AWS Secrets Manager CSI Driver, External Secrets Operator, Vault, or another secret management solution of your choice.

## SMTP Email Configuration

Platform can be configured to send email notifications via SMTP. To enable SMTP, we recommend creating a Kubernetes secret containing your SMTP credentials:

```bash
  kubectl create secret generic smtp-secrets \
    --from-literal=SMTP_ADDRESS=smtp.example.com \
    --from-literal=SMTP_DOMAIN=example.com \
    --from-literal=SMTP_PORT=587 \
    --from-literal=SMTP_USER_NAME='AKIABLAHBLAHBLAH' \
    --from-literal=SMTP_PASSWORD='awssecretaccesskeyhere' \
    --from-literal=MAILER_DEFAULT_FROM="no-reply@example.com"
```

The secret must include the following keys:
- `SMTP_ADDRESS`: SMTP server hostname (e.g. "smtp.example.com")
- `SMTP_DOMAIN`: HELO/EHLO domain to use (e.g. "example.com")
- `SMTP_PORT`: SMTP server port (e.g. "587")
- `SMTP_USER_NAME`: Username for SMTP authentication (Using AWS SES this will be the AWS Access Key ID for the smtp user)
- `SMTP_PASSWORD`: Password for SMTP authentication (Using AWS SES this will be AWS Secret Access Key for the smtp user)
- `MAILER_DEFAULT_FROM` : The default 'no-reply' address you wish to use. (e.g "no-reply@example.com")

Then enable SMTP in your values file:

```yaml
smtp:
  enabled: true
  secret:
    name: smtp-secrets
```

## Initial User Configuration

When Platform is first deployed, an initial user account is created to allow you to access the system. This user is configured via the `owningUser` section in your values file.

```yaml
owningUser:
  email: "admin@example.invalid"
  firstName: "Admin"
  lastName: "User"
  organisationName: "Example Org"
```

**Configuration:**
- `email`: Email address for the initial user account (used for login)
- `firstName`: First name of the user
- `lastName`: Last name of the user
- `organisationName`: Name of the organization this user belongs to

> After the initial deployment, you should create additional user accounts through the Platform web interface and can remove or disable this initial user account. Do not use this for production user management.

> The initial password for this user will be randomly generated during deployment. You can reset it through the Platform web interface or using the Rails console. It is also possible to set a password in the values file.

## Sizing the Workloads

Node pools autoscale and the application scales its workers to demand. The two values
that bound throughput are:

- **`materialProcessingCount`** (default `"default=5"`) — how many materials the application
  admits for processing at once.
- **`maxReplicaCount`** on each scaledJob and scaledObject — how far that worker may scale.

They ship aligned, at five materials in and five slots at each stage, so no single stage is
the bottleneck by default. Raise both together in `your-custom-values.yaml` if you want more
throughput and have the cluster capacity for it; raising one alone will not help.

How much either costs you depends on your content, library size, comparison types and which
features you use, which is why the chart does not guess on your behalf.

> Please consult with Snicket Labs technical services for sizing recommendations.

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

**If you are not running the monitoring in this chart at all**, the two values at
the top of this section are still what bound throughput, and the symptom above is
still what to look for. How you observe it is your choice: the dashboards here
need Grafana and Prometheus, and nothing about the symptom requires either.

---

# AWS EKS QuickStart Deployment Guide

Deploying the chart with the default values will install Platform to the `snicketlabs` namespace, however, you will need to modify your own values.yml file to achieve a fully functional EKS deployment.

## Prerequisites (Reference Architecture users)

Complete these steps before installing this chart.

**1. Deploy the Terraform reference architecture**

Follow the two-stage apply in the reference architecture README. Once complete, update your kubeconfig:

```bash
aws eks update-kubeconfig --region <your-region> --name <your-cluster-name>
```

**2. Create the two manually-provisioned AWS Secrets Manager secrets**

These are not created by Terraform, and must exist before the secrets are synced — whichever way you do it:

```bash
# Honeybadger API key (provided to you by Snicket Labs). Create it even if you
# leave Honeybadger off: the secrets-configuration-aws syncer mounts it
# unconditionally and will not start without it.
# Store the key as a RAW string — not JSON. The SecretProviderClass copies this
# value verbatim into the HONEYBADGER_API_KEY environment variable, so a JSON
# wrapper would be sent to Honeybadger as the token and rejected.
aws secretsmanager create-secret \
  --name snicketlabs-honeybadger-secret \
  --region <your-region> \
  --secret-string 'hbp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# Verify it stored as a bare string — expect 40 (or 41 if a trailing newline
# was added). A larger number means the JSON wrapper is still present.
aws secretsmanager get-secret-value \
  --secret-id snicketlabs-honeybadger-secret \
  --region <your-region> \
  --query SecretString --output text | wc -c

# Snicketlabs registry credentials (access token generated at https://deploy.snicketlabs.io/settings/access-tokens)
aws secretsmanager create-secret \
  --name snicketlabs-docker-secret \
  --region <your-region> \
  --secret-string '{"auths":{"registry.snicketlabs.io":{"password":"<your-access-token>"}}}'
```

**3. Sync the secrets from AWS Secrets Manager**

**Using the reference architecture Terraform? This is already done** — its
`tf-dt-eks-secret-provider-classes` module installs the chart for you and feeds
it the secret names from Terraform's own outputs. Skip to step 4.

**If you are not, you need either this chart or to create the Kubernetes Secrets
yourself** — see *Option B — Manual secret creation* under Postgres below for
what they have to contain. To use the chart, run from your infrastructure
directory:

```bash
helm repo add snicketlabs https://snicketlabs.github.io/helm-charts
helm repo update

helm install secrets-configuration snicketlabs/secrets-configuration-aws \
  -n snicketlabs --create-namespace \
  --set clusterName=$(terraform output -json eks_cluster_details | jq -r '.cluster_name') \
  --set apiSecretName=$(terraform output -raw api_secret_name) \
  --set rdsPgSecretName=$(terraform output -raw rds_pg_secret_name) \
  --set userSecretName=$(terraform output -raw user_secret_name) \
  --set secretStoreRoleArn=$(terraform output -raw secret_store_role_arn) \
  --set redis.enabled=false
```

`redis.enabled=false` is only needed on chart 0.3.0 and earlier, where it
defaults to on; from 0.4.0 the chart has no Redis and ignores it.

The secrets (`api-secrets`, `postgres-credentials`, `owning-user-credentials`, `honeybadger-api-key`) are created by the chart's own syncer pod, which exists only to mount the CSI volumes and force the driver to write them. They will not appear in `kubectl get secrets` until that pod is running, so it needs schedulable compute — and if it is later scaled to zero, rotations in Secrets Manager stop propagating.

**4. Create the image pull secret**

See [Image Pull Secrets](#image-pull-secrets) below.

---

Use the steps below as a checklist when creating your own `your-custom-values.yaml` file.

## 1. Image Tags

The main `image.tag` defaults to the chart's `appVersion` if not set. Override it only when you need to pin the platform app to a specific release independently of the chart.

```yaml
# image.tag is optional — omit to use the chart's appVersion
image:
  repository: registry.snicketlabs.io/snicketlabs/platform
  # tag: 4.0.0  # uncomment to override appVersion
```

> Don't forget to configure the initial user account. See the [Initial User Configuration](#initial-user-configuration) section above for details.

## 2. Initial User Configuration

```yaml
owningUser:
  email: "admin@{YOUR_DOMAIN}"
  firstName: "Admin"
  lastName: "User"
  organisationName: "{YOUR_ORGANISATION_NAME}"
```

---

## 3. AWS IAM Service Account (IRSA)

See reference architecture or configure IRSA for service account to access AWS resources such as S3.

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::*********:role/your-service-account-role
```

> The reference architecture contains sample IAM permissions required by the application.

---

## 4. Domain and Ingress Configuration

### Domain Name

Set your application domain.

```yaml
domain: your-domain-name.example.com # Your domain name
```

### Ingress Configuration

Platform is intended to run on a dedicated cluster. Configure ingress for EKS Auto Mode — the built-in ALB controller does not honour `alb.ingress.kubernetes.io/load-balancer-attributes`, so the idle timeout is set via `ingressClassParams` instead.

```yaml
ingress:
  enabled: true
  className: "snicketlabs-alb"
  annotations:
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {YOUR_CERTIFICATE_ARN}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /up
    alb.ingress.kubernetes.io/success-codes: "200-402"
    external-dns.alpha.kubernetes.io/hostname: {YOUR_DOMAIN}

  # Platform performs long-running comparison requests. The ALB default idle
  # timeout of 60s may cause 504 timeout errors on these requests. On EKS Auto Mode
  # this must be set via IngressClassParams rather than an annotation.
  ingressClassParams:
    create: true
    scheme: internet-facing
    loadBalancerAttributes:
      - key: idle_timeout.timeout_seconds
        value: "300"

  hosts:
    - host: {YOUR_DOMAIN}
      paths:
        - path: /
          pathType: Prefix
```

## 5. Database Configuration

### PostgreSQL (RDS)

> See the reference architecture for AWS RDS configuration.

This chart expects the database password to exist as a Kubernetes secret before install. There are two ways to provide it:

**Option A — AWS Secrets Manager via ASCP (recommended for reference architecture users)**

Using the [reference-architecture](https://github.com/snicketlabs/reference-architecture) Terraform, there is nothing to do here: the RDS password is stored in AWS Secrets Manager, and its `tf-dt-eks-secret-provider-classes` module syncs it — and every other required secret — into the cluster via the AWS Secrets Store CSI Driver. GCP uses External Secrets Operator against GCP Secret Manager instead, through the same mechanism.

If you are not using it, you need either this chart or Option B below:

```bash
helm repo add snicketlabs https://snicketlabs.github.io/helm-charts
helm install secrets-configuration snicketlabs/secrets-configuration-aws -n snicketlabs -f your-values.yaml
```

This chart is what creates `postgres-credentials`, `api-secrets`, `owning-user-credentials`, and `honeybadger-api-key` as Kubernetes secrets. Without it (or equivalent manual steps below), the platform pods will fail to start with `CreateContainerConfigError`.

**Option B — Manual secret creation**

If you are not using ASCP, create the required secrets manually:

```bash
kubectl create secret generic postgres-password \
  --namespace snicketlabs \
  --from-literal=password='YOUR_DATABASE_PASSWORD'
```

See also the `secretKeys` section of `values.yaml` for `api-secrets` and other required secrets — all must exist before installing this chart.

**Configure the connection:**

```yaml
postgres:
  primaryHost: my-external-database.example.internal
  port: 5432
  auth:
    username: platform
    database: platform
  passwordSecret:
    name: postgres-password
    key: password
```

### 6. S3 Storage Configuration

#### AWS S3 (IRSA)

Create a primary S3 bucket for the application.

> Consult the reference architecture for AWS S3 configuration.

Configure your primary S3 bucket in the values file:

```yaml
s3:
  primaryBucket: your-s3-bucket-name  # Your S3 bucket name
  region: us-east-1                   # Your AWS region
```

> Ensure your IAM role (IRSA) has appropriate S3 permissions for the bucket.

#### S3-Compatible Storage (Non-AWS)

For Ceph, MinIO, GCS S3-interop, or any other S3-compatible store, see [S3-Compatible Primary Storage (Non-AWS)](#s3-compatible-primary-storage-non-aws) in the requirements section above.

## 7. Image Pull Secrets

For configuring image pull secrets to authenticate with the Snicket Labs (formerly Ad Signal) container registry, see [Image Pull Secrets](#image-pull-secrets) above.

## 8. Add HoneyBadger Credentials (optional)

Only needed if you enable Honeybadger error tracking. See the [Honeybadger Configuration](#honeybadger-configuration) section.

## 9. Network Access Requirements

| Direction | Service | Address(s) | Port | Description |
|-----------|---------|------------|------|-------------|
| Egress | Honeybadger | api.honeybadger.io | 443 | Application Error tracking, only if Honeybadger is enabled [Honeybadger API IP addresses](https://docs.honeybadger.io/resources/security/#for-exception-monitoring)|
| Egress | Snicketlabs Registry | registry.snicketlabs.io | 443 | Container images and Helm chart |
| Egress | SMTP | Customers SMTP server | - | For password resets etc. |
| Ingress | Web/API | Customer domain | 443 | Access to Web interface and API |

---

## Quick Start Checklist

### Pre-install (Reference Architecture users)

- [ ] Terraform reference architecture deployed (two-stage apply complete)
- [ ] kubeconfig updated (`aws eks update-kubeconfig`)
- [ ] `snicketlabs-honeybadger-secret` created in AWS Secrets Manager (required by `secrets-configuration-aws` even with Honeybadger off)
- [ ] `snicketlabs-docker-secret` created in AWS Secrets Manager
- [ ] Kubernetes secrets synced from AWS Secrets Manager — automatic with the reference architecture, otherwise install `secrets-configuration-aws` yourself
- [ ] `dockercredentials` image pull secret created in the `snicketlabs` namespace

### Values configuration

- [ ] Initial user configured (`owningUser.email`, `owningUser.organisationName`)
- [ ] IRSA service account annotation set
- [ ] Domain name configured
- [ ] Ingress configured with ACM certificate ARN
- [ ] Postgres connection configured (use Terraform outputs)
- [ ] S3 bucket configured (use Terraform outputs)
- [ ] `imagePullSecrets` set to `dockercredentials` in values

---

## Deployment Command

Once you've customized your `values.yaml` file, install the chart with the relevant size file:

> Please consult with Snicketlabs technical services for sizing recommendations.

Charts are served directly from the Snicketlabs OCI registry. Ensure you are logged in first (see [Image Pull Secrets](#image-pull-secrets)), then install:

```bash
helm install oci://registry.snicketlabs.io/snicketlabs/platform-chart/platform \
  --version <chart-version> \
  --namespace snicketlabs \
  --generate-name \
  --create-namespace \
  --values your-custom-values.yaml \
  --wait --wait-for-jobs --timeout 15m
```

`--wait --wait-for-jobs` makes `helm install` report a failure if the database preparation Job (schema, seeds, KEDA role) or the application doesn't come up, instead of returning as soon as the resources are created. Allow enough `--timeout` for Postgres to start and the schema to load; on a failure Helm reports when the timeout runs out, while the Job itself (`app.kubernetes.io/component: db-prepare-initial`) shows as failed after a few attempts.

### Retrieving the Initial Password

The helm command above will output the kubectl command to retrieve the initial user password, if you are unable to use this you can use the kubectl command below:

```bash
kubectl get secret owning-user-credentials -n snicketlabs -o jsonpath='{.data.password}' | base64 -d
```

### Resetting the Initial Password

The initial user's email is set via `owningUser.email` in your helm values. To reset the password from the command line, use the Rails runner on the web pod:

```bash
kubectl exec -n snicketlabs deployment/web-platform -- bin/rails runner \
  "u = User.find_by(email: 'admin@yourcompany.com'); \
   new_pass = 'YourNewPassword123!'; \
   u.update!(password: new_pass, password_confirmation: new_pass); \
   puts 'Password reset for ' + u.email"
```

To sync the password back to the value in the Kubernetes secret (e.g. after rotating in AWS Secrets Manager):

```bash
NEW_PASS=$(kubectl get secret owning-user-credentials -n snicketlabs -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n snicketlabs deployment/web-platform -- bin/rails runner \
  "u = User.find_by(email: 'admin@yourcompany.com'); \
   u.update!(password: '$NEW_PASS', password_confirmation: '$NEW_PASS'); \
   puts 'Password reset for ' + u.email"
```

----

## Getting Help

> For sizing recommendations, production configuration guidance, or deployment assistance, please consult with Snicket Labs technical services.

**Common Issues:**
- **Image pull errors**: Verify `imagePullSecrets` are correctly configured and that image tags are valid
- **Database connection issues**: Check RDS security groups and secret values
- **Storage issues**: Scratch is an emptyDir on the node; check node disk pressure, and for evicted MatchCore jobs the tier's `ephemeral-storage` limit. See [Scratch Storage (/tmp)](#scratch-storage-tmp)
- **Ingress issues**: Verify ALB controller is installed and certificate ARN is correct

## Long Term Checklist

Use this checklist to ensure you've replaced more temporary measures with production-ready solutions.

> For secrets management, you can use AWS Secrets Manager CSI Driver or another Kubernetes secret management solution of your choice.

- [ ] Replaced `imagePullSecrets` with a secret manager
- [ ] Migrated database password from manual Kubernetes secret to a secret manager
- [ ] Configured SMTP using a secret manager
- [ ] Set up monitoring and alerting (Prometheus, Grafana, Loki) # Please consult with Snicket Labs technical services for production-ready solutions
- [ ] Configured database backups and disaster recovery procedures
- [ ] Reviewed and optimized resource requests and limits based on actual usage

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://grafana-community.github.io/helm-charts | loki | 21.4.1 |
| https://grafana.github.io/helm-charts | alloy | 1.16.0 |
| https://prometheus-community.github.io/helm-charts | kube-prometheus-stack | 93.4.1 |

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Snicket Labs Platform | <platform@snicketlabs.io> |  |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| adminUser.email | string | `"admin@snicketlabs.io"` |  |
| adminUser.firstName | string | `"Admin"` |  |
| adminUser.lastName | string | `"User"` |  |
| adminUser.organisationName | string | `"Snicket Labs"` |  |
| adminUser.organisationRoles | string | `"assure_admin"` |  |
| adminUser.roles | string | `"email_and_password,assure_admin"` |  |
| affinity | object | `{}` |  |
| alloy.alloy.configMap.content | string | `"discovery.kubernetes \"pods\" {\n  role = \"pod\"\n  selectors {\n    role  = \"pod\"\n    field = \"spec.nodeName=\" + sys.env(\"HOSTNAME\")\n  }\n}\n\ndiscovery.relabel \"pods\" {\n  targets = discovery.kubernetes.pods.targets\n\n  rule {\n    source_labels = [\"__meta_kubernetes_namespace\"]\n    target_label  = \"namespace\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_name\"]\n    target_label  = \"pod\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_container_name\"]\n    target_label  = \"container\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_node_name\"]\n    target_label  = \"node_name\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_label_app_kubernetes_io_name\", \"__meta_kubernetes_pod_label_app\"]\n    regex         = \"^;*([^;]+)(;.*)?$\"\n    target_label  = \"app\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_label_app_kubernetes_io_component\", \"__meta_kubernetes_pod_label_component\"]\n    regex         = \"^;*([^;]+)(;.*)?$\"\n    target_label  = \"component\"\n  }\n  rule {\n    source_labels = [\"namespace\", \"app\"]\n    separator     = \"/\"\n    target_label  = \"job\"\n  }\n  rule {\n    source_labels = [\"__meta_kubernetes_pod_uid\", \"__meta_kubernetes_pod_container_name\"]\n    separator     = \"/\"\n    target_label  = \"__path__\"\n    replacement   = \"/var/log/pods/*$1/*.log\"\n  }\n}\n\nlocal.file_match \"pods\" {\n  path_targets = discovery.relabel.pods.output\n}\n\nloki.source.file \"pods\" {\n  targets    = local.file_match.pods.targets\n  forward_to = [loki.process.pods.receiver]\n}\n\nloki.process \"pods\" {\n  stage.cri {}\n  forward_to = [loki.write.default.receiver]\n}\n\nloki.write \"default\" {\n  endpoint {\n    url = \"http://{{ include \"platform.lokiName\" . }}:3100/loki/api/v1/push\"\n  }\n}"` |  |
| alloy.alloy.mounts.varlog | bool | `true` |  |
| alloy.alloy.resources.requests.cpu | string | `"10m"` |  |
| alloy.alloy.resources.requests.memory | string | `"64Mi"` |  |
| alloy.controller.tolerations[0].effect | string | `"NoSchedule"` |  |
| alloy.controller.tolerations[0].key | string | `"CriticalAddonsOnly"` |  |
| alloy.controller.tolerations[0].operator | string | `"Exists"` |  |
| alloy.controller.tolerations[1].effect | string | `"NoSchedule"` |  |
| alloy.controller.tolerations[1].key | string | `"node-role.kubernetes.io/master"` |  |
| alloy.controller.tolerations[1].operator | string | `"Exists"` |  |
| alloy.controller.tolerations[2].effect | string | `"NoSchedule"` |  |
| alloy.controller.tolerations[2].key | string | `"node-role.kubernetes.io/control-plane"` |  |
| alloy.controller.tolerations[2].operator | string | `"Exists"` |  |
| alloy.controller.type | string | `"daemonset"` |  |
| alloy.crds.create | bool | `false` |  |
| contentSecrets | list | `[]` |  |
| dbPrepareJob.annotations | object | `{}` |  |
| dbPrepareJob.backoffLimit | int | `2` |  |
| dbPrepareJob.helmHookAnnotations."helm.sh/hook" | string | `"pre-upgrade"` |  |
| dbPrepareJob.helmHookAnnotations."helm.sh/hook-delete-policy" | string | `""` |  |
| dbPrepareJob.helmHookAnnotations."helm.sh/hook-weight" | string | `"0"` |  |
| domain | string | `"snicketlabs.example.com"` |  |
| duration_async_required | string | `"300"` |  |
| env | list | `[]` |  |
| extraEnvSecrets | list | `[]` |  |
| extraEnvs | list | `[]` |  |
| fullnameOverride | string | `"platform"` |  |
| gke.enabled | bool | `false` |  |
| gke.healthCheckPath | string | `"/up"` |  |
| goodJob.pollInterval | int | `5` |  |
| goodJob.probePort | int | `7001` |  |
| goodJob.shutdownGraceSeconds | int | `60` |  |
| goodJob.shutdownTimeout | int | `600` |  |
| honeybadger.environment | string | `""` |  |
| honeybadger.secretKey | string | `"apiKey"` |  |
| honeybadger.secretName | string | `"honeybadger-api-key"` |  |
| httpRoute.annotations | object | `{}` |  |
| httpRoute.enabled | bool | `false` |  |
| httpRoute.hostnames | list | `[]` |  |
| httpRoute.parentRefs[0].name | string | `"gateway"` |  |
| httpRoute.rules[0].matches[0].path.type | string | `"PathPrefix"` |  |
| httpRoute.rules[0].matches[0].path.value | string | `"/"` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"registry.snicketlabs.io/snicketlabs/platform"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.ingressClassParams.create | bool | `false` |  |
| ingress.ingressClassParams.loadBalancerAttributes | list | `[]` |  |
| ingress.ingressClassParams.scheme | string | `"internet-facing"` |  |
| ingress.tls | list | `[]` |  |
| kedaAutoScaling.postgres.authenticationRef.name | string | `"keda-trigger-auth-postgres"` |  |
| kedaAutoScaling.postgres.authenticationRef.secretKey | string | `"password"` |  |
| kedaAutoScaling.postgres.authenticationRef.secretName | string | `""` |  |
| kedaAutoScaling.postgres.autoCreateRole | bool | `true` |  |
| kedaAutoScaling.postgres.dbName | string | `""` |  |
| kedaAutoScaling.postgres.dbUser | string | `""` |  |
| kedaAutoScaling.postgres.host | string | `""` |  |
| kedaAutoScaling.postgres.pollingInterval | int | `30` |  |
| kedaAutoScaling.postgres.port | int | `5432` |  |
| kedaAutoScaling.postgres.roleName | string | `"db_keda_ro"` |  |
| kedaAutoScaling.postgres.sslmode | string | `"require"` |  |
| kube-prometheus-stack.alertmanager.enabled | bool | `false` |  |
| kube-prometheus-stack.crds.upgradeJob.enabled | bool | `true` |  |
| kube-prometheus-stack.grafana."grafana.ini".server.serve_from_sub_path | bool | `true` |  |
| kube-prometheus-stack.grafana.adminPassword | string | `""` |  |
| kube-prometheus-stack.grafana.deploymentStrategy.type | string | `"Recreate"` |  |
| kube-prometheus-stack.grafana.envFromConfigMaps[0].name | string | `"{{ .Release.Name }}-grafana-server"` |  |
| kube-prometheus-stack.grafana.envFromConfigMaps[0].optional | bool | `true` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].items[0].key | string | `"password"` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].items[0].path | string | `"password"` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].mountPath | string | `"/etc/secrets"` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].name | string | `"pg-secrets"` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].optional | bool | `true` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].readOnly | bool | `true` |  |
| kube-prometheus-stack.grafana.extraSecretMounts[0].secretName | string | `"platform-grafana-postgres-ro"` |  |
| kube-prometheus-stack.grafana.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| kube-prometheus-stack.grafana.persistence.enabled | bool | `true` |  |
| kube-prometheus-stack.grafana.persistence.size | string | `"10Gi"` |  |
| kube-prometheus-stack.grafana.persistence.type | string | `"pvc"` |  |
| kube-prometheus-stack.grafana.rbac.namespaced | bool | `true` |  |
| kube-prometheus-stack.grafana.serviceAccount.annotations | object | `{}` |  |
| kube-prometheus-stack.grafana.serviceAccount.create | bool | `false` |  |
| kube-prometheus-stack.grafana.serviceAccount.name | string | `"grafana"` |  |
| kube-prometheus-stack.grafana.sidecar.dashboards.searchNamespace | string | `""` |  |
| kube-prometheus-stack.prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues | bool | `false` |  |
| kube-prometheus-stack.prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues | bool | `false` |  |
| kube-prometheus-stack.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0] | string | `"ReadWriteOnce"` |  |
| kube-prometheus-stack.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage | string | `"50Gi"` |  |
| logLevel | string | `"info"` |  |
| log_path | string | `"/app/log/production.log"` |  |
| log_path_mode | string | `"0664"` |  |
| loki.backend.replicas | int | `0` |  |
| loki.chunksCache.enabled | bool | `false` |  |
| loki.deploymentMode | string | `"Monolithic"` |  |
| loki.gateway.enabled | bool | `false` |  |
| loki.loki.auth_enabled | bool | `false` |  |
| loki.loki.commonConfig.replication_factor | int | `1` |  |
| loki.loki.compactor.delete_request_store | string | `"filesystem"` |  |
| loki.loki.compactor.retention_enabled | bool | `true` |  |
| loki.loki.configObjectName | string | `"{{ include \"loki.fullname\" . }}"` |  |
| loki.loki.generatedConfigObjectName | string | `"{{ include \"loki.fullname\" . }}"` |  |
| loki.loki.limits_config.allow_structured_metadata | bool | `true` |  |
| loki.loki.limits_config.discover_log_levels | bool | `true` |  |
| loki.loki.limits_config.retention_period | string | `"744h"` |  |
| loki.loki.limits_config.volume_enabled | bool | `true` |  |
| loki.loki.pattern_ingester.enabled | bool | `true` |  |
| loki.loki.schemaConfig.configs[0].from | string | `"2026-01-01"` |  |
| loki.loki.schemaConfig.configs[0].index.period | string | `"24h"` |  |
| loki.loki.schemaConfig.configs[0].index.prefix | string | `"index_"` |  |
| loki.loki.schemaConfig.configs[0].object_store | string | `"filesystem"` |  |
| loki.loki.schemaConfig.configs[0].schema | string | `"v13"` |  |
| loki.loki.schemaConfig.configs[0].store | string | `"tsdb"` |  |
| loki.loki.storage.type | string | `"filesystem"` |  |
| loki.lokiCanary.enabled | bool | `false` |  |
| loki.memcached.enabled | bool | `false` |  |
| loki.nameOverride | string | `"logs"` |  |
| loki.rbac.namespaced | bool | `true` |  |
| loki.read.replicas | int | `0` |  |
| loki.resultsCache.enabled | bool | `false` |  |
| loki.sidecar.rules.enabled | bool | `false` |  |
| loki.singleBinary.persistence.enabled | bool | `true` |  |
| loki.singleBinary.persistence.size | string | `"10Gi"` |  |
| loki.singleBinary.persistence.storageClass | string | `""` |  |
| loki.singleBinary.replicas | int | `1` |  |
| loki.singleBinary.resources.requests.cpu | string | `"100m"` |  |
| loki.singleBinary.resources.requests.memory | string | `"256Mi"` |  |
| loki.test.enabled | bool | `false` |  |
| loki.write.replicas | int | `0` |  |
| materialProcessingCount | string | `"default=5"` |  |
| materialProcessingPipelines | string | `"default|duration>=0"` |  |
| metrics.enabled | bool | `true` |  |
| metrics.metricsPort | int | `9090` |  |
| monitoring.alerts.alertLabels | object | `{}` |  |
| monitoring.alerts.enabled | bool | `false` |  |
| monitoring.alerts.oomKilledWindow | string | `"15m"` |  |
| monitoring.alerts.ruleLabels | object | `{}` |  |
| monitoring.aws.cloudwatchRoleArn | string | `""` |  |
| monitoring.aws.enabled | bool | `false` |  |
| monitoring.aws.grafanaRoleArn | string | `""` |  |
| monitoring.aws.region | string | `""` |  |
| monitoring.dashboards.enabled | string | `nil` |  |
| monitoring.enabled | bool | `false` |  |
| monitoring.logging.enabled | bool | `false` |  |
| monitoring.matchDashboards.enabled | string | `nil` |  |
| monitoring.postgresDashboards.autoCreateRole | bool | `true` |  |
| monitoring.postgresDashboards.enabled | string | `nil` |  |
| monitoring.postgresDashboards.roleName | string | `"db_grafana_ro"` |  |
| nameOverride | string | `"platform"` |  |
| nodeSelector | object | `{}` |  |
| owningUser.email | string | `"admin@example.invalid"` |  |
| owningUser.firstName | string | `"Admin"` |  |
| owningUser.lastName | string | `"User"` |  |
| owningUser.organisationName | string | `"Example Org"` |  |
| owningUser.secret.generate | bool | `false` |  |
| owningUser.secret.name | string | `"owning-user-credentials"` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `65532` |  |
| podSecurityContext.runAsUser | int | `65532` |  |
| postgres.auth.database | string | `"platform"` |  |
| postgres.auth.password | string | `""` |  |
| postgres.auth.username | string | `"platform"` |  |
| postgres.port | int | `5432` |  |
| postgres.primaryHost | string | `""` |  |
| railsConsole.enabled | bool | `false` |  |
| railsConsole.replicas | int | `1` |  |
| railsConsole.resources.limits.memory | string | `"1Gi"` |  |
| railsConsole.resources.requests.cpu | string | `"50m"` |  |
| railsConsole.resources.requests.memory | string | `"512Mi"` |  |
| rails_env | string | `"production"` |  |
| s3.accessKeyId | string | `"dummy-key"` |  |
| s3.compatibleAccessKeyField | string | `""` |  |
| s3.compatibleCredentialsSecret | string | `""` |  |
| s3.compatibleEndpoint | string | `""` |  |
| s3.compatibleForcePathStyle | string | `""` |  |
| s3.compatiblePublicEndpoint | string | `""` |  |
| s3.compatibleSecretKeyField | string | `""` |  |
| s3.primaryBucket | string | `""` |  |
| s3.region | string | `""` |  |
| s3.secretAccessKey | string | `"dummy-secret"` |  |
| scaledJobs.audiomatch-fingerprint.activeDeadlineSeconds | int | `28800` |  |
| scaledJobs.audiomatch-fingerprint.enabled | bool | `true` |  |
| scaledJobs.audiomatch-fingerprint.maxReplicaCount | int | `5` |  |
| scaledJobs.audiomatch-fingerprint.queue | string | `"audio_match_frames_fingerprint_tasks"` |  |
| scaledJobs.audiomatch-fingerprint.resources.limits.cpu | string | `"1500m"` |  |
| scaledJobs.audiomatch-fingerprint.resources.limits.memory | string | `"8Gi"` |  |
| scaledJobs.audiomatch-fingerprint.resources.requests.cpu | string | `"1"` |  |
| scaledJobs.audiomatch-fingerprint.resources.requests.memory | string | `"5500Mi"` |  |
| scaledJobs.compare-find-related.activeDeadlineSeconds | int | `3600` |  |
| scaledJobs.compare-find-related.enabled | bool | `true` |  |
| scaledJobs.compare-find-related.maxReplicaCount | int | `5` |  |
| scaledJobs.compare-find-related.queue | string | `"find_related_materials"` |  |
| scaledJobs.compare-find-related.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.compare-find-related.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.compare-find-related.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.compare-find-related.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.compare-relate.activeDeadlineSeconds | int | `14400` |  |
| scaledJobs.compare-relate.enabled | bool | `true` |  |
| scaledJobs.compare-relate.maxReplicaCount | int | `5` |  |
| scaledJobs.compare-relate.queue | string | `"relate_materials"` |  |
| scaledJobs.compare-relate.resources.limits.cpu | string | `"2"` |  |
| scaledJobs.compare-relate.resources.limits.memory | string | `"3Gi"` |  |
| scaledJobs.compare-relate.resources.requests.cpu | string | `"500m"` |  |
| scaledJobs.compare-relate.resources.requests.memory | string | `"3Gi"` |  |
| scaledJobs.comparison-longform-data-generation.activeDeadlineSeconds | int | `6600` |  |
| scaledJobs.comparison-longform-data-generation.enabled | bool | `true` |  |
| scaledJobs.comparison-longform-data-generation.maxReplicaCount | int | `6` |  |
| scaledJobs.comparison-longform-data-generation.queue | string | `"generate_grouped_comparison_result_data"` |  |
| scaledJobs.comparison-longform-data-generation.resources.limits.memory | string | `"3Gi"` |  |
| scaledJobs.comparison-longform-data-generation.resources.requests.cpu | string | `"1"` |  |
| scaledJobs.comparison-longform-data-generation.resources.requests.memory | string | `"3Gi"` |  |
| scaledJobs.dv-matchcore.activeDeadlineSeconds | int | `7200` |  |
| scaledJobs.dv-matchcore.enabled | bool | `true` |  |
| scaledJobs.dv-matchcore.matchcoreThreads | int | `4` |  |
| scaledJobs.dv-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.dv-matchcore.queue | string | `"dv_matchcore"` |  |
| scaledJobs.dv-matchcore.resources.limits.cpu | string | `"4"` |  |
| scaledJobs.dv-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.dv-matchcore.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.dv-matchcore.resources.requests.cpu | string | `"2"` |  |
| scaledJobs.dv-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.dv-matchcore.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.hd-matchcore.activeDeadlineSeconds | int | `7200` |  |
| scaledJobs.hd-matchcore.enabled | bool | `true` |  |
| scaledJobs.hd-matchcore.matchcoreThreads | int | `8` |  |
| scaledJobs.hd-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.hd-matchcore.queue | string | `"hd_matchcore"` |  |
| scaledJobs.hd-matchcore.resources.limits.cpu | string | `"8"` |  |
| scaledJobs.hd-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.hd-matchcore.resources.limits.memory | string | `"3Gi"` |  |
| scaledJobs.hd-matchcore.resources.requests.cpu | string | `"5"` |  |
| scaledJobs.hd-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.hd-matchcore.resources.requests.memory | string | `"3Gi"` |  |
| scaledJobs.ingest-download-media.activeDeadlineSeconds | int | `5400` |  |
| scaledJobs.ingest-download-media.enabled | bool | `true` |  |
| scaledJobs.ingest-download-media.maxReplicaCount | int | `5` |  |
| scaledJobs.ingest-download-media.queue | string | `"download_media"` |  |
| scaledJobs.ingest-download-media.resources.limits.cpu | string | `"500m"` |  |
| scaledJobs.ingest-download-media.resources.limits.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-download-media.resources.requests.cpu | string | `"500m"` |  |
| scaledJobs.ingest-download-media.resources.requests.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-materials.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.ingest-materials.enabled | bool | `true` |  |
| scaledJobs.ingest-materials.maxReplicaCount | int | `5` |  |
| scaledJobs.ingest-materials.queue | string | `"ingest_materials"` |  |
| scaledJobs.ingest-materials.resources.limits.cpu | string | `"500m"` |  |
| scaledJobs.ingest-materials.resources.limits.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-materials.resources.requests.cpu | string | `"500m"` |  |
| scaledJobs.ingest-materials.resources.requests.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-process-materials.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.ingest-process-materials.enabled | bool | `true` |  |
| scaledJobs.ingest-process-materials.maxReplicaCount | int | `5` |  |
| scaledJobs.ingest-process-materials.queue | string | `"process_materials"` |  |
| scaledJobs.ingest-process-materials.resources.limits.cpu | string | `"500m"` |  |
| scaledJobs.ingest-process-materials.resources.limits.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-process-materials.resources.requests.cpu | string | `"500m"` |  |
| scaledJobs.ingest-process-materials.resources.requests.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-process-media.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.ingest-process-media.enabled | bool | `true` |  |
| scaledJobs.ingest-process-media.maxReplicaCount | int | `5` |  |
| scaledJobs.ingest-process-media.queue | string | `"process_media"` |  |
| scaledJobs.ingest-process-media.resources.limits.cpu | string | `"500m"` |  |
| scaledJobs.ingest-process-media.resources.limits.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-process-media.resources.requests.cpu | string | `"500m"` |  |
| scaledJobs.ingest-process-media.resources.requests.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-process-qc.activeDeadlineSeconds | int | `3600` |  |
| scaledJobs.ingest-process-qc.enabled | bool | `true` |  |
| scaledJobs.ingest-process-qc.maxReplicaCount | int | `2` |  |
| scaledJobs.ingest-process-qc.queue | string | `"process_qc"` |  |
| scaledJobs.ingest-process-qc.resources.limits.cpu | string | `"4"` |  |
| scaledJobs.ingest-process-qc.resources.limits.memory | string | `"3Gi"` |  |
| scaledJobs.ingest-process-qc.resources.requests.cpu | string | `"2"` |  |
| scaledJobs.ingest-process-qc.resources.requests.memory | string | `"820Mi"` |  |
| scaledJobs.ingest-proxy-generate.activeDeadlineSeconds | int | `5400` |  |
| scaledJobs.ingest-proxy-generate.enabled | bool | `true` |  |
| scaledJobs.ingest-proxy-generate.maxReplicaCount | int | `5` |  |
| scaledJobs.ingest-proxy-generate.queue | string | `"proxy_generate_tasks"` |  |
| scaledJobs.ingest-proxy-generate.resources.limits.cpu | string | `"6"` |  |
| scaledJobs.ingest-proxy-generate.resources.limits.memory | string | `"4Gi"` |  |
| scaledJobs.ingest-proxy-generate.resources.requests.cpu | string | `"2"` |  |
| scaledJobs.ingest-proxy-generate.resources.requests.memory | string | `"1280Mi"` |  |
| scaledJobs.interlaced-matchcore.activeDeadlineSeconds | int | `7200` |  |
| scaledJobs.interlaced-matchcore.enabled | bool | `true` |  |
| scaledJobs.interlaced-matchcore.matchcoreThreads | int | `4` |  |
| scaledJobs.interlaced-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.interlaced-matchcore.queue | string | `"interlaced_matchcore"` |  |
| scaledJobs.interlaced-matchcore.resources.limits.cpu | string | `"8"` |  |
| scaledJobs.interlaced-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.interlaced-matchcore.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.interlaced-matchcore.resources.requests.cpu | string | `"6"` |  |
| scaledJobs.interlaced-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.interlaced-matchcore.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.j2k-hd-matchcore.activeDeadlineSeconds | int | `14400` |  |
| scaledJobs.j2k-hd-matchcore.enabled | bool | `true` |  |
| scaledJobs.j2k-hd-matchcore.matchcoreThreads | int | `8` |  |
| scaledJobs.j2k-hd-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.j2k-hd-matchcore.queue | string | `"j2k_hd_matchcore"` |  |
| scaledJobs.j2k-hd-matchcore.resources.limits.cpu | string | `"8"` |  |
| scaledJobs.j2k-hd-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.j2k-hd-matchcore.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.j2k-hd-matchcore.resources.requests.cpu | string | `"8"` |  |
| scaledJobs.j2k-hd-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.j2k-hd-matchcore.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.j2k-uhd-matchcore.activeDeadlineSeconds | int | `43200` |  |
| scaledJobs.j2k-uhd-matchcore.enabled | bool | `true` |  |
| scaledJobs.j2k-uhd-matchcore.matchcoreThreads | int | `12` |  |
| scaledJobs.j2k-uhd-matchcore.maxReplicaCount | int | `1` |  |
| scaledJobs.j2k-uhd-matchcore.queue | string | `"j2k_uhd_matchcore"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.limits.cpu | string | `"12"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.limits.memory | string | `"6Gi"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.requests.cpu | string | `"12"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.j2k-uhd-matchcore.resources.requests.memory | string | `"6Gi"` |  |
| scaledJobs.process-ai-tagging.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-ai-tagging.enabled | bool | `true` |  |
| scaledJobs.process-ai-tagging.maxReplicaCount | int | `5` |  |
| scaledJobs.process-ai-tagging.queue | string | `"ai_tagging"` |  |
| scaledJobs.process-ai-tagging.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-ai-tagging.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-ai-tagging.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-ai-tagging.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.process-audio-insights.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-audio-insights.enabled | bool | `true` |  |
| scaledJobs.process-audio-insights.maxReplicaCount | int | `5` |  |
| scaledJobs.process-audio-insights.queue | string | `"audio_insights"` |  |
| scaledJobs.process-audio-insights.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-audio-insights.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-audio-insights.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-audio-insights.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.process-complete-materials.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-complete-materials.enabled | bool | `true` |  |
| scaledJobs.process-complete-materials.maxReplicaCount | int | `5` |  |
| scaledJobs.process-complete-materials.queue | string | `"complete_materials"` |  |
| scaledJobs.process-complete-materials.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-complete-materials.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-complete-materials.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-complete-materials.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.process-extract-frames.activeDeadlineSeconds | int | `5400` |  |
| scaledJobs.process-extract-frames.enabled | bool | `true` |  |
| scaledJobs.process-extract-frames.maxReplicaCount | int | `5` |  |
| scaledJobs.process-extract-frames.queue | string | `"video_match_frames_extract_frames_tasks"` |  |
| scaledJobs.process-extract-frames.resources.limits.cpu | string | `"3"` |  |
| scaledJobs.process-extract-frames.resources.limits.memory | string | `"1500Mi"` |  |
| scaledJobs.process-extract-frames.resources.requests.cpu | string | `"1"` |  |
| scaledJobs.process-extract-frames.resources.requests.memory | string | `"512Mi"` |  |
| scaledJobs.process-sbf.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-sbf.enabled | bool | `true` |  |
| scaledJobs.process-sbf.maxReplicaCount | int | `5` |  |
| scaledJobs.process-sbf.queue | string | `"process_sbf"` |  |
| scaledJobs.process-sbf.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-sbf.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-sbf.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-sbf.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.process-unique-frames-create.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-unique-frames-create.enabled | bool | `true` |  |
| scaledJobs.process-unique-frames-create.maxReplicaCount | int | `5` |  |
| scaledJobs.process-unique-frames-create.queue | string | `"video_unique_frames_create_tasks"` |  |
| scaledJobs.process-unique-frames-create.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-unique-frames-create.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-unique-frames-create.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-unique-frames-create.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.process-unique-frames-groups.activeDeadlineSeconds | int | `600` |  |
| scaledJobs.process-unique-frames-groups.enabled | bool | `true` |  |
| scaledJobs.process-unique-frames-groups.maxReplicaCount | int | `5` |  |
| scaledJobs.process-unique-frames-groups.queue | string | `"video_unique_frames_create_groups_tasks"` |  |
| scaledJobs.process-unique-frames-groups.resources.limits.cpu | string | `"750m"` |  |
| scaledJobs.process-unique-frames-groups.resources.limits.memory | string | `"2Gi"` |  |
| scaledJobs.process-unique-frames-groups.resources.requests.cpu | string | `"750m"` |  |
| scaledJobs.process-unique-frames-groups.resources.requests.memory | string | `"2Gi"` |  |
| scaledJobs.tiff-sequence-matchcore.activeDeadlineSeconds | int | `28800` |  |
| scaledJobs.tiff-sequence-matchcore.enabled | bool | `true` |  |
| scaledJobs.tiff-sequence-matchcore.imageSequence.bufferMegabytes | int | `640` |  |
| scaledJobs.tiff-sequence-matchcore.imageSequence.downloadThreads | int | `8` |  |
| scaledJobs.tiff-sequence-matchcore.matchcoreThreads | int | `8` |  |
| scaledJobs.tiff-sequence-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.tiff-sequence-matchcore.queue | string | `"tiff_sequence_matchcore"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.limits.cpu | string | `"8"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.limits.memory | string | `"4Gi"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.requests.cpu | string | `"4"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.tiff-sequence-matchcore.resources.requests.memory | string | `"4Gi"` |  |
| scaledJobs.uhd-matchcore.activeDeadlineSeconds | int | `28800` |  |
| scaledJobs.uhd-matchcore.enabled | bool | `true` |  |
| scaledJobs.uhd-matchcore.matchcoreThreads | int | `8` |  |
| scaledJobs.uhd-matchcore.maxReplicaCount | int | `5` |  |
| scaledJobs.uhd-matchcore.queue | string | `"uhd_matchcore"` |  |
| scaledJobs.uhd-matchcore.resources.limits.cpu | string | `"8"` |  |
| scaledJobs.uhd-matchcore.resources.limits.ephemeral-storage | string | `"4Gi"` |  |
| scaledJobs.uhd-matchcore.resources.limits.memory | string | `"4Gi"` |  |
| scaledJobs.uhd-matchcore.resources.requests.cpu | string | `"6"` |  |
| scaledJobs.uhd-matchcore.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scaledJobs.uhd-matchcore.resources.requests.memory | string | `"4Gi"` |  |
| scaledObjects.generic.concurrency | int | `10` |  |
| scaledObjects.generic.dbFollowerPoolSize | int | `10` |  |
| scaledObjects.generic.dbPoolSize | int | `10` |  |
| scaledObjects.generic.maxReplicaCount | int | `3` |  |
| scaledObjects.generic.minReplicaCount | int | `2` |  |
| scaledObjects.generic.pdb.enabled | bool | `true` |  |
| scaledObjects.generic.queues[0].name | string | `"default"` |  |
| scaledObjects.generic.queues[0].priority | int | `1` |  |
| scaledObjects.generic.queues[1].name | string | `"pipeline"` |  |
| scaledObjects.generic.queues[1].priority | int | `2` |  |
| scaledObjects.generic.queues[2].name | string | `"mailers"` |  |
| scaledObjects.generic.queues[2].priority | int | `3` |  |
| scaledObjects.generic.queues[3].name | string | `"active_storage_purge"` |  |
| scaledObjects.generic.queues[3].priority | int | `4` |  |
| scaledObjects.generic.queues[4].name | string | `"refresh_ingest_source_reports"` |  |
| scaledObjects.generic.queues[4].priority | int | `5` |  |
| scaledObjects.generic.resources.limits.cpu | string | `"300m"` |  |
| scaledObjects.generic.resources.limits.memory | string | `"1500Mi"` |  |
| scaledObjects.generic.resources.requests.cpu | string | `"300m"` |  |
| scaledObjects.generic.resources.requests.memory | string | `"300Mi"` |  |
| scaledObjects.generic.shutdownTimeout | int | `30` |  |
| secretKeys.secret.generate | bool | `false` |  |
| secretKeys.secret.name | string | `"api-secrets"` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsUser | int | `65532` |  |
| service.annotations | object | `{}` |  |
| service.port | int | `3000` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `true` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| smtp.enabled | bool | `false` |  |
| smtp.secret.name | string | `"smtp-secrets"` |  |
| snicketPort | string | `""` |  |
| snicketProtocol | string | `""` |  |
| storage.tmpStorage.enabled | bool | `true` |  |
| storage.tmpStorage.path | string | `"/tmp/app_tmp"` |  |
| tolerations | list | `[]` |  |
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |
| webServers.livenessProbe.timeoutSeconds | int | `5` |  |
| webServers.pdb.enabled | bool | `true` |  |
| webServers.port | int | `3000` |  |
| webServers.railsMaxThreads | int | `15` |  |
| webServers.readinessProbe.timeoutSeconds | int | `5` |  |
| webServers.replicas | int | `2` |  |
| webServers.resources.limits.memory | string | `"1536Mi"` |  |
| webServers.resources.requests.cpu | string | `"1"` |  |
| webServers.resources.requests.memory | string | `"1Gi"` |  |
