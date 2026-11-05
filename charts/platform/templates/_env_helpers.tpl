{{- define "platform.envVars" -}}
- name: ENABLE_DYNAMIC_QUEUING
  value: "false"
- name: RAILS_ENV
  value: "{{.Values.rails_env}}"
- name: RAILS_SERVE_STATIC_FILES
  value: "1"
- name: AD_SIGNAL_ENVIRONMENT
  value: "external"
- name: DURATION_ASYNC_REQUIRED
  value: "{{ .Values.duration_async_required | default "300" }}"
- name: RAILS_LOG_LEVEL
  value: "{{.Values.logLevel}}"
- name: DISABLE_SPRING
  value: "1"
- name: LOG_PATH_MODE
  value: "{{.Values.log_path_mode}}"
- name: LOG_PATH
  value: "{{.Values.log_path}}"
# Unused in external environments
- name: SLACK_API_TOKEN
  value: "ignored"
- name: "RAILS_LOG_TO_STDOUT"
  value: "1"
- name: API_SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretKeys.secret.name }}
      key: api_secret_key_base
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretKeys.secret.name }}
      key: secret_key_base
- name: INGEST_CREDENTIAL_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretKeys.secret.name }}
      key: ingest_credential_encryption_key
- name: S3_PRIMARY_BUCKET
  value: "{{ required "s3.primaryBucket is required. Set it to the bucket this deployment should use for primary storage in values.yaml" .Values.s3.primaryBucket }}"
{{- /* AWS_REGION also selects the regional STS endpoint used by IRSA, so a wrong
       value is not limited to S3: every request pays an extra redirect and
       credentials are vended from the wrong region. There is no safe default. */}}
- name: COMPATIBLE_S3_REGION
  value: "{{ required "s3.region is required. Set it to the region your primary bucket and cluster are in, e.g. eu-west-2" .Values.s3.region }}"
- name: AWS_REGION
  value: "{{ required "s3.region is required. Set it to the region your primary bucket and cluster are in, e.g. eu-west-2" .Values.s3.region }}"
{{- if .Values.s3.compatibleEndpoint }}
{{- /* Internal pod→storage URL for S3-compatible backends (Ceph, GCS, MinIO, etc.).
       Points Active Storage and S3CompatibleCredential at the storage API.
       Leave empty on AWS — IRSA and the default S3 endpoint are used. */}}
- name: COMPATIBLE_ENDPOINT_URL_S3
  value: "{{ .Values.s3.compatibleEndpoint }}"
{{- end }}
{{- if .Values.s3.compatiblePublicEndpoint }}
{{- /* Browser-reachable URL for presigned URLs. Set when the internal endpoint is a
       cluster-DNS name unreachable by browsers (e.g. on-prem Ceph behind MetalLB). */}}
- name: COMPATIBLE_PUBLIC_ENDPOINT_URL_S3
  value: "{{ .Values.s3.compatiblePublicEndpoint }}"
{{- end }}
{{- if .Values.s3.compatibleForcePathStyle }}
- name: COMPATIBLE_S3_FORCE_PATH_STYLE
  value: "{{ .Values.s3.compatibleForcePathStyle }}"
{{- end }}
{{- if .Values.s3.compatibleCredentialsSecret }}
{{- /* HMAC creds for the S3-compatible backend. AWS leaves this empty (uses IRSA).
       Key names default to access_key_id / secret_access_key (ESO convention).
       Override compatibleAccessKeyField / compatibleSecretKeyField for secrets that
       use different key names (e.g. Rook OBC secrets use AWS_ACCESS_KEY_ID). */}}
- name: COMPATIBLE_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3.compatibleCredentialsSecret }}
      key: {{ .Values.s3.compatibleAccessKeyField | default "access_key_id" }}
- name: COMPATIBLE_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3.compatibleCredentialsSecret }}
      key: {{ .Values.s3.compatibleSecretKeyField | default "secret_access_key" }}
{{- end }}
  {{- if .Values.domain }}
- name: ADSIGNAL_BASE_DOMAIN
  value: {{ .Values.domain }}
  {{- end }}
{{- if .Values.postgres.passwordSecret }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.passwordSecret.name }}
      key: {{ .Values.postgres.passwordSecret.key }}
{{- else }}
- name: DB_PASSWORD
  value: "{{ .Values.postgres.auth.password | default "" }}"
{{- end }}
{{ if .Values.postgres.userNameSecret}}
- name: DB_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.userNameSecret.name }}
      key: {{ .Values.postgres.userNameSecret.key }}
{{- else }}
- name: DB_USERNAME
  value: "{{ .Values.postgres.auth.username | default "" }}"
{{- end }}
{{ if .Values.postgres.dbNameSecret }}
- name: DB_DATABASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.dbNameSecret.name }}
      key: {{ .Values.postgres.dbNameSecret.key }}
{{- else }}
- name: DB_DATABASE
  value: "{{ .Values.postgres.auth.database | default "platform" }}"
{{- end }}
{{- if not (or .Values.postgres.dbPrimaryHostSecret .Values.postgres.primaryHost) }}
{{- fail "No Postgres host is configured. The chart does not provision a database: set postgres.primaryHost, or postgres.dbPrimaryHostSecret to read the host from a Secret." }}
{{- end }}
{{- if .Values.postgres.dbPrimaryHostSecret }}
- name: DB_PRIMARY_HOST
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.dbPrimaryHostSecret.name }}
      key: {{ .Values.postgres.dbPrimaryHostSecret.key }}
- name: DB_REPLICA_HOSTS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.dbPrimaryHostSecret.name }}
      key: {{ .Values.postgres.dbPrimaryHostSecret.key }}
{{- else}}
- name: DB_PRIMARY_HOST
  value: "{{ .Values.postgres.primaryHost }}"
- name: DB_REPLICA_HOSTS
  value: "{{ .Values.postgres.primaryHost }}"
{{- end }}
{{- if .Values.postgres.dbPortSecret }}
- name: DB_PORT
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgres.dbPortSecret.name }}
      key: {{ .Values.postgres.dbPortSecret.key }}
{{- else }}
- name: DB_PORT
  value: "{{ .Values.postgres.port | default "5432" }}"
{{- end }}
{{- if .Values.smtp.enabled }}
- name: SMTP_ADDRESS
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: SMTP_ADDRESS
- name: SMTP_DOMAIN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: SMTP_DOMAIN
- name: SMTP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: SMTP_PASSWORD
- name: SMTP_PORT
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: SMTP_PORT
- name: SMTP_USER_NAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: SMTP_USER_NAME
- name: MAILER_DEFAULT_FROM
  valueFrom:
    secretKeyRef:
      name: {{ .Values.smtp.secret.name }}
      key: MAILER_DEFAULT_FROM
{{- end }}
- name: MATERIAL_PROCESSING_PIPELINES
  value: "{{ .Values.materialProcessingPipelines }}"
- name: MATERIAL_PROCESSING_COUNT
  value: "{{ .Values.materialProcessingCount }}"
# Honeybadger is opt-in: an empty honeybadger.environment turns it off. Guard on
# the environment, not the map — values.yaml always fills in secretName and
# secretKey, so the map itself is never empty. When off, say so explicitly: hub
# falls back to a placeholder API key and would otherwise still try to report.
{{- if (.Values.honeybadger).environment }}
- name: HONEYBADGER_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.honeybadger.secretName }}
      key: {{ .Values.honeybadger.secretKey }}
- name: HONEYBADGER_ENV
  value: {{ .Values.honeybadger.environment | quote }}
{{- else }}
- name: HONEYBADGER_REPORT_DATA
  value: "false"
{{- end }}
# Routes matchcore fingerprinting to the per-tier queues by source codec. Set on
# every pod rather than only the tier jobs: the queue is chosen when the job is
# enqueued, so the process doing the enqueueing is the one that has to know.
# Not optional: off, every matchcore job lands on a queue nothing consumes.
- name: MATCHCORE_TIER_QUEUES
  value: "true"
{{- range $extraEnv := .Values.extraEnvs }}
- name: {{ $extraEnv.name }}
  value: {{ $extraEnv.value | quote }}
{{- end }}
{{- range $secretEnv := .Values.extraEnvSecrets }}
- name: {{ $secretEnv.name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretEnv.secretName }}
      key: {{ $secretEnv.secretKey }}
{{- end }}
{{- if eq .Values.metrics.enabled true }}
- name: PROMETHEUS_EXPORTER_PORT
  value: "{{ .Values.metrics.metricsPort }}"
{{- else }}
{{- end }}
{{- if .Values.storage.tmpStorage.enabled }}
{{- if not (hasPrefix "/tmp" .Values.storage.tmpStorage.path) }}
{{- fail "storage.tmpStorage.path must be located in /tmp directory" }}
{{- end }}
- name: AD_SIGNAL_TMPDIR
  value: {{ .Values.storage.tmpStorage.path }}
{{- end }}
{{- if .Values.snicketProtocol }}
- name: SNICKET_PROTOCOL
  value: {{ .Values.snicketProtocol | quote }}
- name: SNICKET_PORT
  value: {{ .Values.snicketPort | default "80" | quote }}
{{- end }}
{{- end }}

# Only added to db:prepare job pods
{{- define "platform.owningUserEnvVars" -}}
{{- if .Values.owningUser }}
- name: OWNING_USER_EMAIL
  value: "{{ .Values.owningUser.email }}"
- name: OWNING_USER_FIRSTNAME
  value: "{{ .Values.owningUser.firstName }}"
- name: OWNING_USER_LASTNAME
  value: "{{ .Values.owningUser.lastName }}"
- name: OWNING_USER_ROLES
  value: email_and_password
- name: OWNING_ORGANISATION_NAME
  value: "{{ .Values.owningUser.organisationName }}"
- name: OWNING_USER_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.owningUser.secret.name }}
      key: password
{{- end }}
{{- end }}

