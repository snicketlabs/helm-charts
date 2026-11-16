# Upgrade Notes

`platform` 1.0.0 was the first public release.

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
