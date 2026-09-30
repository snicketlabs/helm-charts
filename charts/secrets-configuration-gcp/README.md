# secrets-configuration / eso-support (GCP)

ESO-based secrets configuration for GCP — the counterpart to `../ascp-support`
(AWS). Syncs GCP Secret Manager secrets into native Kubernetes Secrets via
[External Secrets Operator](https://external-secrets.io/), authenticated with
GKE Workload Identity. Produces the **same Kubernetes Secrets** (names + keys) as
`ascp-support`, so the platform deployment is identical on AWS and GCP.

## Prerequisites

1. **ESO operator installed** in the cluster — done separately via the
   `tf-dt-external-secrets` Terraform module (sc-22517), not this chart.
2. **Workload Identity GSA** with `roles/secretmanager.secretAccessor`, bound to
   this chart's ServiceAccount — done in Terraform via `tf-dt-workload-identity`
   (sc-22516), `use_existing_k8s_sa = true` against `serviceAccount.name`. Set the
   GSA email in `serviceAccount.gcpServiceAccount` for the KSA annotation.
3. **The source secrets exist** in GCP Secret Manager:
   - Cloud SQL (`tf-dt-cloud-sql`) and Memorystore (`tf-dt-memorystore`) write theirs.
   - API + owning-user secrets: `tf-dt-application-secrets` (sc-22740).
   - `snicketlabs-docker-secret` + `snicketlabs-honeybadger-secret`: created manually (below).

## Prerequisites: manually created secrets (GCP)

The GCP equivalents of the AWS manually-created secrets. GCP Secret Manager
stores plain string values (no per-secret regions/replication flags like AWS).

1. **Docker registry credentials** — the dockerconfigjson, stored as `snicketlabs-docker-secret`:

   ```bash
   # $SECRET_JSON is your docker config json (a single-line JSON string)
   printf '%s' "$SECRET_JSON" | gcloud secrets create snicketlabs-docker-secret \
     --project "$PROJECT_ID" --data-file=-
   ```

2. **Honeybadger API token** (provided securely by Snicket Labs), stored as `snicketlabs-honeybadger-secret`:

   ```bash
   printf '%s' "$HONEYBADGER_API_KEY" | gcloud secrets create snicketlabs-honeybadger-secret \
     --project "$PROJECT_ID" --data-file=-
   ```

   (To rotate either later: `gcloud secrets versions add <name> --project "$PROJECT_ID" --data-file=-`.)

The ESO GSA's `roles/secretmanager.secretAccessor` (granted by `tf-dt-workload-identity`)
covers reading these alongside the Terraform-created secrets.

## What it creates

- A namespaced **`SecretStore`** (`gcpsm` provider + Workload Identity auth).
- A **`ServiceAccount`** carrying the `iam.gke.io/gcp-service-account` annotation.
- **`ExternalSecret`s** producing: `postgres-credentials`, `api-secrets`,
  `owning-user-credentials`, `<clusterName>-redis`, `dockerconfig`,
  `honeybadger-api-key`, `s3-credentials` (GCS S3-interop HMAC, sc-22742),
  and (optional) `smtp-secrets`.

## Open reconciliation points (flagged in templates)

- **Redis keys:** the app's k8s Secret uses `url` / `elasticache_url` / `endpoint`
  (AWS-branded). The GCP Memorystore secret has `host`/`port`/`auth`/`url`, so we map
  `url<-url`, `endpoint<-host`, `elasticache_url<-url`. Confirm against what the app reads.
- **Cloud SQL `db_name`:** GCP secret key is `dbname`; remapped to the app's `db_name`.

Replace the placeholder values in `values.yaml` (project, cluster, secret names,
GSA email) before installing.
