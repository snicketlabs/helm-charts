{{/*
Expand the name of the chart.
*/}}
{{- define "platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "platform.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "platform.labels" -}}
helm.sh/chart: {{ include "platform.chart" . }}
{{ include "platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "platform.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate a consistent random password for the ingester user
*/}}
{{- define "platform.ingesterPassword" -}}
{{- if and .Values.ingesterUser .Values.ingesterUser.password }}
{{- .Values.ingesterUser.password }}
{{- else }}
{{- $secretName := printf "%s-ingester-credentials" (include "platform.fullname" .) }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "password" | b64dec }}
{{- else }}
{{- printf "%s%s%s%s" (randAlpha 4) (randAlpha 4 | upper) (randNumeric 4) "!@#$" | shuffle }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Init container that blocks pod startup until the database schema exists.
Prevents workers and web from entering CrashLoopBackOff on fresh installs
while db-prepare-initial is still running. On upgrades the schema already
exists so this exits immediately on the first attempt.
It also waits for the GoodJob tables: a GoodJob
process that boots before they exist caches an empty column list and its
notifier then errors every minute until the pod restarts. schema_migrations
alone is not enough: a stray `db:seed` against an empty database creates it
before the schema is loaded.
*/}}
{{- define "platform.waitForSchema" -}}
- name: wait-for-schema
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      until PGPASSWORD="$DB_PASSWORD" psql -h "$DB_PRIMARY_HOST" -U "$DB_USERNAME" -d "$DB_DATABASE" \
        -c "SELECT 1 FROM schema_migrations, good_jobs, good_job_processes LIMIT 1" > /dev/null 2>&1; do
        echo "waiting for schema to be ready..."
        sleep 5
      done
  env:
   {{- include "platform.envVars" . | nindent 4 }}
{{- end }}

{{- define "platform.volumes" -}}
{{- if .Values.storage.tmpStorage.enabled }}
- name: tmp-storage
  {{- if .Values.storage.tmpStorage.sizeLimit }}
  emptyDir:
    sizeLimit: {{ .Values.storage.tmpStorage.sizeLimit }}
  {{- else }}
  emptyDir: {}
  {{- end }}
{{- end }}
{{- with .Values.volumes }}
{{ toYaml . }}
{{- end }}
{{- end }}
{{- define "platform.volumeMounts" -}}
{{- if .Values.storage.tmpStorage.enabled }}
- name: tmp-storage
  mountPath: /tmp
{{- end }}
{{- with .Values.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Generate a consistent random API secret key base for the first deploy using release name and namespace
*/}}
{{- define "platform.apiSecretKeyBase" -}}
{{- $secretName := .Values.secretKeys.secret.name }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "api_secret_key_base" | b64dec }}
{{- else }}
{{- printf "%s%s" (randAlphaNum 64 | sha256sum) (randAlphaNum 64 | sha256sum) }}
{{- end }}
{{- end }}

{{/*
Generate a consistent random secret key base for the first deploy using release name and namespace
*/}}
{{- define "platform.secretKeyBase" -}}
{{- $secretName := .Values.secretKeys.secret.name }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "secret_key_base" | b64dec }}
{{- else }}
{{- printf "%s%s" (randAlphaNum 64 | sha256sum) (randAlphaNum 64 | sha256sum) }}
{{- end }}
{{- end }}

{{/*
Generate a consistent random ingest credential encryption key for the first deploy using release name and namespace
*/}}
{{- define "platform.ingestCredentialEncryptionKey" -}}
{{- $secretName := .Values.secretKeys.secret.name }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "ingest_credential_encryption_key" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}

{{/*
Generate a consistent random password for the owning user for the first deploy using release name and namespace
*/}}
{{- define "platform.owningUserPassword" -}}
{{- $secretName := .Values.owningUser.secret.name }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "password" | b64dec }}
{{- else }}
{{- (printf "%s%s%s%s%s" (randAlpha 12) (randAlpha 8 | upper) (randNumeric 6) "!@#" (randAlpha 4)) | shuffle }}
{{- end }}
{{- end }}

{{/*
Postgres host for KEDA's postgresql scaler trigger metadata.

KEDA needs a literal host string at template-render time — there's no secretRef
indirection for this field the way there is for the password. That's fine for a
plain postgres.primaryHost, but breaks down for postgres.dbPrimaryHostSecret
(host only known at pod runtime): use kedaAutoScaling.postgres.host as an
explicit override in that case.
*/}}
{{- define "platform.kedaPostgresHost" -}}
{{- if .Values.kedaAutoScaling.postgres.host -}}
{{- /* Explicit override: used exactly as given. */ -}}
{{- .Values.kedaAutoScaling.postgres.host -}}
{{- else -}}
{{- $host := .Values.postgres.primaryHost -}}
{{- /* The KEDA operator runs in its own namespace, so a bare in-cluster service name never resolves. */ -}}
{{- if not $host -}}
{{- fail "The KEDA scalers need a literal Postgres host, but none could be resolved at render time (postgres.primaryHost is empty, e.g. when using postgres.dbPrimaryHostSecret). Set kedaAutoScaling.postgres.host to your database host." -}}
{{- end -}}
{{- if not (contains "." $host) -}}
{{- printf "%s.%s.svc" $host .Release.Namespace -}}
{{- else -}}
{{- $host -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Default name of the Secret holding the auto-created KEDA read-only Postgres
role's password (kedaAutoScaling.postgres.autoCreateRole).
Deployers using their own pre-existing role/secret (e.g. autoCreateRole: false)
override this via kedaAutoScaling.postgres.authenticationRef.secretName instead.
*/}}
{{- define "platform.kedaPostgresRoleSecretName" -}}
{{- .Values.kedaAutoScaling.postgres.authenticationRef.secretName | default (printf "%s-keda-postgres-ro" (include "platform.fullname" .)) -}}
{{- end }}

{{/*
Password for the auto-created KEDA read-only Postgres role. Looks up any existing
Secret first, mirroring platform.owningUserPassword, so the password — and therefore
the DB role itself — stays stable across upgrades instead of rotating every deploy.
*/}}
{{- define "platform.kedaPostgresRolePassword" -}}
{{- $secretName := include "platform.kedaPostgresRoleSecretName" . }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "password" | b64dec }}
{{- else }}
{{- (printf "%s%s%s%s%s" (randAlpha 12) (randAlpha 8 | upper) (randNumeric 6) "!@#" (randAlpha 4)) | shuffle }}
{{- end }}
{{- end }}

{{/*
Suffix for the one Helm hook Job (rails-prepare-job). Its empty delete policy
means `helm uninstall` leaves it behind until its 24h TTL, and a reinstall
restarts at revision 1, so a revision-only name collided with the leftover on
the first upgrade after a reinstall ("field is immutable"). A few random
characters, generated once per render, make every render's name unique.
*/}}
{{- define "platform.hookJobSuffix" -}}
{{- if not (hasKey .Values "_hookJobSuffix") }}
{{- $_ := set .Values "_hookJobSuffix" (randAlphaNum 5 | lower) }}
{{- end }}
{{- printf "%d-%s" .Release.Revision .Values._hookJobSuffix }}
{{- end }}

{{/*
What both database preparation Jobs run (db-prepare-initial.yaml on install,
db-prepare-job.yaml on upgrades and under ArgoCD): every database step, one
after another in one Rails process, so nothing races (sc-24654).

1. `db:prepare`: loads db/schema.rb into an empty database (and seeds it), or
   runs pending migrations. A load cut short is retried cleanly, because
   schema.rb records schema_migrations last.
2. `db:seed`: so seeds also land on upgrades and on an existing database. On a
   fresh database they run a second time, which is harmless: they are
   idempotent.
3. With KEDA's role auto-created, the read-only role and its grants
   (platform.kedaPostgresRoleScript). The tables it grants on exist by now.

Nothing else may touch an empty database before step 1: a `db:seed` that gets
there first creates an empty schema_migrations, and `db:prepare` then runs
every migration instead of loading schema.rb (failing at CreateComparisons).

Previously the seed step and the KEDA role were separate Jobs. On a fresh
install the seed Job could reach the empty database first and leave it
half-migrated, and the KEDA Jobs could run before the tables they grant on.
*/}}
{{- define "platform.dbPrepareCommand" -}}
- bin/rails
- runner
- |
  Rails.application.load_tasks
  Rake::Task["db:prepare"].invoke
  Rake::Task["db:seed"].invoke
  {{- if include "platform.kedaAutoCreateRole" . }}
  {{- include "platform.kedaPostgresRoleScript" . | nindent 2 }}
  {{- end }}
  {{- if include "platform.grafanaAutoCreateRole" . }}
  {{- include "platform.grafanaPostgresRoleScript" . | nindent 2 }}
  {{- end }}
{{- end }}

{{- define "platform.kedaAutoCreateRole" -}}
{{- if .Values.kedaAutoScaling.postgres.autoCreateRole -}}
true
{{- end }}
{{- end }}

{{- define "platform.grafanaPostgresRoleSecretName" -}}
{{- printf "%s-grafana-postgres-ro" (include "platform.fullname" .) -}}
{{- end }}

{{/* Same lookup-or-generate as the KEDA role, so the password is stable across upgrades. */}}
{{- define "platform.grafanaPostgresRolePassword" -}}
{{- $secretName := include "platform.grafanaPostgresRoleSecretName" . }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- index $existingSecret.data "password" | b64dec }}
{{- else }}
{{- (printf "%s%s%s%s%s" (randAlpha 12) (randAlpha 8 | upper) (randNumeric 6) "!@#" (randAlpha 4)) | shuffle }}
{{- end }}
{{- end }}

{{/* Only wanted where the datasource exists, and only if we are creating roles. */}}
{{- define "platform.grafanaAutoCreateRole" -}}
{{- if and (include "platform.postgresDashboardsEnabled" .) (.Values.monitoring.postgresDashboards | default dict).autoCreateRole -}}
true
{{- end }}
{{- end }}

{{- define "platform.grafanaPostgresRoleEnv" -}}
{{- if include "platform.grafanaAutoCreateRole" . }}
- name: GRAFANA_RO_ROLE_NAME
  value: {{ (.Values.monitoring.postgresDashboards | default dict).roleName | default "db_grafana_ro" }}
- name: GRAFANA_RO_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "platform.grafanaPostgresRoleSecretName" . }}
      key: password
{{- end }}
{{- end }}

{{- define "platform.kedaPostgresRoleEnv" -}}
{{- if include "platform.kedaAutoCreateRole" . }}
- name: KEDA_RO_ROLE_NAME
  value: {{ .Values.kedaAutoScaling.postgres.roleName | default "db_keda_ro" }}
- name: KEDA_RO_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "platform.kedaPostgresRoleSecretName" . }}
      key: password
{{- end }}
{{- end }}

{{/*
Idempotent, least-privilege setup for the KEDA read-only Postgres role.

Runs as `bin/rails runner` so it reuses the app's own DB connection config
instead of needing a psql client in the image. Grants SELECT on good_jobs and good_job_processes only
(not pg_read_all_data, unlike the CNPG-based Hub SaaS equivalent) — this chart
ships to third-party self-hosted/onprem customers, so the role's blast radius
needs to be defensible in a customer security review, not just convenient.

Permission problems never fail the Job: a customer's DB user may lack
CREATEROLE (common for BYOP/onprem Postgres where the customer intentionally
scopes the credentials they hand over), so those errors are caught and logged
as a warning instead of aborting — a failed helm install/upgrade over this
would be worse than KEDA autoscaling simply not being configured yet. See
docs/README.md for the manual fallback.

A missing good_jobs/good_job_processes table does fail the Job: it runs right
after the schema is loaded or migrated (platform.dbPrepareCommand), so a
missing table means an image without GoodJob, and passing would leave KEDA
silently unable to scale.
*/}}
{{- define "platform.postgresRoleScript" -}}
{{- $tables := .tables -}}
conn = ActiveRecord::Base.connection
role = ENV.fetch("{{ .roleEnv }}")
password = ENV.fetch("{{ .passwordEnv }}")
db_name = ENV.fetch("DB_DATABASE")
missing_tables = []
begin
  conn.execute("SELECT pg_advisory_lock(hashtext('{{ .lockKey }}'))")
  exists = conn.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{conn.quote(role)}")
  if exists
    conn.execute("ALTER ROLE #{conn.quote_table_name(role)} PASSWORD #{conn.quote(password)}")
  else
    conn.execute("CREATE ROLE #{conn.quote_table_name(role)} LOGIN PASSWORD #{conn.quote(password)}")
  end
  conn.execute("GRANT CONNECT ON DATABASE #{conn.quote_table_name(db_name)} TO #{conn.quote_table_name(role)}")
  conn.execute("GRANT USAGE ON SCHEMA public TO #{conn.quote_table_name(role)}")
  %w[{{ join " " $tables }}].each do |table|
    begin
      conn.execute("GRANT SELECT ON #{table} TO #{conn.quote_table_name(role)}")
    rescue => e
      # Each table on its own, so one the chart's user can't grant on doesn't stop the other.
      if e.cause.is_a?(PG::UndefinedTable)
        missing_tables << table
      else
        warn "WARNING: could not grant SELECT on #{table}: #{e.message}"
      end
    end
  end
  puts "{{ .purpose }} read-only role '#{role}' is ready." if missing_tables.empty?
rescue => e
  warn "WARNING: could not create/configure the {{ .purpose }} read-only Postgres role automatically: #{e.message}"
  warn "{{ .consequence }} - see docs/README.md (Manual role setup)."
ensure
  conn.execute("SELECT pg_advisory_unlock(hashtext('{{ .lockKey }}'))") rescue nil
end
unless missing_tables.empty?
{{- if .failOnMissing }}
  warn "ERROR: cannot grant SELECT on #{missing_tables.join(', ')}: table does not exist. The schema is loaded before this runs, so the image may not include GoodJob."
  exit 1
{{- else }}
  warn "WARNING: cannot grant SELECT on #{missing_tables.join(', ')}: table does not exist. Panels reading them will show a permissions error; everything else still works."
{{- end }}
end
{{- end }}

{{/*
KEDA's read-only role. Fails the Job on a missing table: it runs right after the
schema is loaded, so absent good_jobs means an image without GoodJob, and passing
would leave KEDA silently unable to scale.
*/}}
{{- define "platform.kedaPostgresRoleScript" -}}
{{- include "platform.postgresRoleScript" (dict
      "roleEnv" "KEDA_RO_ROLE_NAME"
      "passwordEnv" "KEDA_RO_PASSWORD"
      "tables" (list "good_jobs" "good_job_processes")
      "lockKey" "keda_ro_role_setup"
      "purpose" "KEDA"
      "consequence" "GoodJob KEDA autoscaling will not work until this is created manually"
      "failOnMissing" true) -}}
{{- end }}

{{/*
Grafana's read-only role, for the Postgres datasource behind
monitoring.postgresDashboards. Separate from KEDA's on purpose: the two want
different tables, and a role named for one consumer being quietly relied on by
another is how the KEDA role ended up with dashboards depending on it (sc-25626).

The extra three tables are what the MatchCore tier dashboards join to name the
material behind a job. Read-only on five tables is still far short of the
application's own user, which is what this datasource used to run as.

Does NOT fail the Job on a missing table: a dashboard panel short of a grant is
not a reason to fail someone's install or upgrade.
*/}}
{{- define "platform.grafanaPostgresRoleScript" -}}
{{- include "platform.postgresRoleScript" (dict
      "roleEnv" "GRAFANA_RO_ROLE_NAME"
      "passwordEnv" "GRAFANA_RO_PASSWORD"
      "tables" (list "good_jobs" "good_job_processes" "jobs" "ingest_masters" "materials")
      "lockKey" "grafana_ro_role_setup"
      "purpose" "Grafana"
      "consequence" "The Postgres dashboards will not be able to query until this is created manually"
      "failOnMissing" false) -}}
{{- end }}

{{/*
Fail on per-job/worker keys that were renamed when the chart dropped Sidekiq.
The old keys would otherwise be silently ignored: a scaledJob would render
without its queue, and a worker without its thread count or drain time.
Takes: kind (values section), name (entry key), values (the entry).
*/}}
{{- define "platform.rejectRenamedKeys" -}}
{{- $renamed := dict "sideKiqQueue" "queue" "goodJobQueue" "queue" "sidekiqConcurrency" "concurrency" "sidekiqTimeout" "shutdownTimeout" -}}
{{- range $old := keys $renamed | sortAlpha -}}
{{- if hasKey $.values $old -}}
{{- fail (printf "%s.%s.%s was renamed to %s when the chart dropped Sidekiq; rename it in your values (see UPGRADING.md)" $.kind $.name $old (get $renamed $old)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Dashboard enablement.

Monitoring has too many switches. These let `monitoring.enabled: true` be the
only thing most people set: leave a dashboard flag unset and it follows the
monitoring stack, set it explicitly and you get exactly that.

The datasource dashboards cannot simply default on, because a Grafana we do not
install is one we cannot wire. Grafana resolves $__file{} at startup and a
datasource it cannot provision stops it coming up, so rendering a Postgres
datasource into someone else's Grafana breaks it. Two conditions have to hold
before we turn it on by ourselves:

  - we install Grafana, so the password mount is ours to set
    (kube-prometheus-stack.grafana.extraSecretMounts, defaulted in values.yaml)
  - the role's Secret exists, which means autoCreateRole

Explicit true still works for a Grafana you run yourself. You own the mount.
*/}}
{{- define "platform.bundledGrafana" -}}
{{- $kps := (index .Values "kube-prometheus-stack") | default dict -}}
{{- $grafana := $kps.grafana | default dict -}}
{{- $grafanaOn := true -}}
{{- if hasKey $grafana "enabled" -}}{{- $grafanaOn = $grafana.enabled -}}{{- end -}}
{{- if and .Values.monitoring.enabled $grafanaOn -}}true{{- end -}}
{{- end }}

{{/* Unset follows monitoring.enabled; explicit wins either way. */}}
{{- define "platform.dashboardsEnabled" -}}
{{- $v := (.Values.monitoring.dashboards | default dict).enabled -}}
{{- if kindIs "invalid" $v -}}
{{- include "platform.bundledGrafana" . -}}
{{- else if $v -}}true{{- end -}}
{{- end }}

{{/* Also needs a password we can actually supply. */}}
{{- define "platform.postgresDashboardsEnabled" -}}
{{- $v := (.Values.monitoring.postgresDashboards | default dict).enabled -}}
{{- if kindIs "invalid" $v -}}
{{- if and (include "platform.bundledGrafana" .) .Values.kedaAutoScaling.postgres.autoCreateRole -}}true{{- end -}}
{{- else if $v -}}true{{- end -}}
{{- end }}

{{/* Its job tables read through the Postgres datasource, so it follows that. */}}
{{- define "platform.matchDashboardsEnabled" -}}
{{- $v := (.Values.monitoring.matchDashboards | default dict).enabled -}}
{{- if kindIs "invalid" $v -}}
{{- include "platform.postgresDashboardsEnabled" . -}}
{{- else if $v -}}true{{- end -}}
{{- end }}

{{/* PDB for a chart Deployment. Args: ctx, name, component (selector label), pdb (values block). */}}
{{- define "platform.podDisruptionBudget" -}}
{{- $pdb := .pdb | default dict -}}
{{- if $pdb.enabled }}
{{- if and (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable") -}}
{{- fail (printf "%s: set only one of pdb.minAvailable and pdb.maxUnavailable" .name) -}}
{{- end }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  labels:
    {{- include "platform.labels" .ctx | nindent 4 }}
spec:
  {{- if hasKey $pdb "minAvailable" }}
  minAvailable: {{ $pdb.minAvailable }}
  {{- else }}
  maxUnavailable: {{ $pdb.maxUnavailable | default 1 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "platform.selectorLabels" .ctx | nindent 6 }}
      app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{/* Loki's Service. Mirrors loki.fullname with nameOverride: logs. Uses only .Release.Name, as Alloy's config includes it too. */}}
{{- define "platform.lokiName" -}}
{{- if contains "logs" .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-logs" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/* Grafana's Service. Mirrors grafana.fullname. */}}
{{- define "platform.grafanaName" -}}
{{- $grafana := (index .Values "kube-prometheus-stack" | default dict).grafana | default dict -}}
{{- if $grafana.fullnameOverride -}}
{{- $grafana.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "grafana" $grafana.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Route /grafana on the platform's host, unless Grafana has its own ingress. */}}
{{- define "platform.grafanaRoute" -}}
{{- $grafana := (index .Values "kube-prometheus-stack" | default dict).grafana | default dict -}}
{{- if and (include "platform.bundledGrafana" .) (not ($grafana.ingress | default dict).enabled) (or .Values.ingress.enabled .Values.httpRoute.enabled) -}}true{{- end -}}
{{- end }}
