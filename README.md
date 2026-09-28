# Snicket Labs Helm Charts

Public Helm charts for self-hosting Snicket Labs software in your own Kubernetes
cluster.

```bash
helm repo add snicketlabs https://snicketlabs.github.io/helm-charts
helm repo update
helm search repo snicketlabs
```

## Charts

| Chart | What it installs |
|---|---|
| `platform` | The Snicket Labs platform — web, workers, and supporting resources |

Each chart's own `README.md` under [`charts/`](charts/) is the configuration
reference: values, secrets, networking and the production readiness checklist.

## Installing

The platform chart expects a namespace of its own. Replace the values file with
your own:

```bash
helm install platform snicketlabs/platform \
  --namespace snicketlabs --create-namespace \
  -f your-values.yaml
```

The chart is also published to an OCI registry, which is the distribution route
used for licensed releases:

```
oci://registry.snicketlabs.io/snicketlabs/platform-chart
```

Reference Terraform for standing up the surrounding infrastructure on AWS and
GCP lives in
[snicketlabs/reference-architecture](https://github.com/snicketlabs/reference-architecture).

## How this repository is maintained

Chart sources under `charts/` are **generated**. They are synced here from a
private repository by an automated pull request, so changes made directly in
this repository will be overwritten on the next sync.

Open an issue here if something in a chart is wrong — that is the right place
for it, even though the fix lands upstream.

Releases are cut by
[`chart-releaser`](https://github.com/helm/chart-releaser-action) whenever a
chart's version changes on `main`. It packages the chart, creates a GitHub
release, and updates the repository index served from the `gh-pages` branch at
<https://snicketlabs.github.io/helm-charts>.

## Superseded repository

These charts were previously published from `ad-signalio/helm-charts` under the
name `adsignal-match`. The `platform` chart is a fork of that one rather than a
rename: the chart name, registry, namespace and most in-cluster resource names
all changed, so there is no upgrade path between them. Install `platform` into a
fresh namespace.
