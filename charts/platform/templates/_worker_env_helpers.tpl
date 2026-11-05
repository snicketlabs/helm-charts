{{- define "platform.workerEnvVars" -}}
- name: AD_SIGNAL_DATABASE_POOL_SIZE
  value: "{{ mul .worker.concurrency 2 }}"
{{ include "platform.goodJobWorkerEnvVars" . }}
{{- end }}

{{/*
GoodJob settings for a long-running worker (scaledObjects / workers).
Takes the same dict as platform.workerEnvVars: worker, goodJob.
The worker's concurrency and shutdownTimeout are the thread count and
shutdown timeout.
GoodJob has no queue weights. When a worker's queues have different priorities
they are claimed in strict order, highest first, using GoodJob's leading "+" (a later queue only runs when every earlier
one is empty). When all priorities are equal there is no "+": GoodJob then takes
jobs from any of the queues by job priority and creation time, which is fair
across queues; strict order would starve whichever queue sorts last.
*/}}
{{- define "platform.goodJobWorkerEnvVars" -}}
{{- $keyed := list }}
{{- $priorities := list }}
{{- range $queue := .worker.queues }}
{{- $keyed = append $keyed (printf "%05d|%s" (sub 99999 (int $queue.priority)) $queue.name) }}
{{- $priorities = append $priorities (int $queue.priority) }}
{{- end }}
{{- $ordered := gt (len (uniq $priorities)) 1 }}
{{- $names := list }}
{{- range $entry := sortAlpha $keyed }}
{{- $names = append $names (last (splitList "|" $entry)) }}
{{- end }}
- name: GOOD_JOB_QUEUES
  value: {{ printf "%s%s" (ternary "+" "" $ordered) (join "," $names) | quote }}
- name: GOOD_JOB_MAX_THREADS
  value: {{ .worker.concurrency | quote }}
- name: GOOD_JOB_POLL_INTERVAL
  value: {{ .goodJob.pollInterval | quote }}
- name: GOOD_JOB_SHUTDOWN_TIMEOUT
  value: {{ .worker.shutdownTimeout | quote }}
- name: GOOD_JOB_PROBE_PORT
  value: {{ .goodJob.probePort | quote }}
- name: DB_QUEUE_POOL_SIZE
  value: {{ add .worker.concurrency 3 | quote }}
{{- end }}

{{/*
Container args for a long-running worker. Queues, threads and shutdown
timeout come from the GOOD_JOB_* env in platform.goodJobWorkerEnvVars.
*/}}
{{- define "platform.workerArgs" -}}
- /app/bin/bundle
- exec
- good_job
- start
{{- end }}

{{/*
Probes for a GoodJob worker, served by GOOD_JOB_PROBE_PORT. Takes: goodJob.
*/}}
{{- define "platform.goodJobWorkerProbes" -}}
startupProbe:
  httpGet:
    path: /status/started
    port: {{ .goodJob.probePort }}
  failureThreshold: 30
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /status/connected
    port: {{ .goodJob.probePort }}
  failureThreshold: 10
  periodSeconds: 10
{{- end }}
