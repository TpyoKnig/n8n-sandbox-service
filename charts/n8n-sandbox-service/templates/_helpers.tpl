{{/*
Expand the name of the chart.
*/}}
{{- define "n8n-sandbox-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "n8n-sandbox-service.fullname" -}}
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
Chart name and version label.
*/}}
{{- define "n8n-sandbox-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "n8n-sandbox-service.apiName" -}}
{{- printf "%s-api" (include "n8n-sandbox-service.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "n8n-sandbox-service.sysboxRunnerName" -}}
{{- printf "%s-sysbox-runner" (include "n8n-sandbox-service.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The in-chart runner, whichever data plane mode selected it.

Both modes run the same runner image and differ only in how the container gets
the privileges to run an inner Docker daemon: sysbox supplies them through the
node runtime, dind by asking the kernel directly. Everything downstream of that
(config, TLS, service, registration) is identical, so the runner templates are
written once against these helpers rather than duplicated per mode.

The names and component labels stay mode-specific on purpose. A StatefulSet's
selector is immutable, so folding sysbox onto a shared "runner" label would make
every existing release fail to upgrade with a field-is-immutable error.
*/}}

{{- define "n8n-sandbox-service.runnerMode" -}}
{{- if has .Values.dataPlane.mode (list "sysbox" "dind") -}}
{{- .Values.dataPlane.mode -}}
{{- end -}}
{{- end }}

{{/* The values block belonging to the active mode. */}}
{{- define "n8n-sandbox-service.runnerValues" -}}
{{- if eq .Values.dataPlane.mode "dind" -}}
{{- toYaml .Values.dindRunner -}}
{{- else -}}
{{- toYaml .Values.sysboxRunner -}}
{{- end -}}
{{- end }}

{{- define "n8n-sandbox-service.runnerComponent" -}}
{{- printf "%s-runner" (include "n8n-sandbox-service.runnerMode" .) -}}
{{- end }}

{{- define "n8n-sandbox-service.runnerName" -}}
{{- printf "%s-%s" (include "n8n-sandbox-service.fullname" .) (include "n8n-sandbox-service.runnerComponent" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* True only when the active mode ships a runner and that runner is enabled. */}}
{{- define "n8n-sandbox-service.runnerEnabled" -}}
{{- $mode := include "n8n-sandbox-service.runnerMode" . -}}
{{- if $mode -}}
{{- $runner := fromYaml (include "n8n-sandbox-service.runnerValues" .) -}}
{{- if $runner.enabled -}}true{{- end -}}
{{- end -}}
{{- end }}

{{- define "n8n-sandbox-service.authSecretName" -}}
{{- default (printf "%s-auth" (include "n8n-sandbox-service.fullname" .)) .Values.auth.existingSecret | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "n8n-sandbox-service.labels" -}}
helm.sh/chart: {{ include "n8n-sandbox-service.chart" . }}
app.kubernetes.io/name: {{ include "n8n-sandbox-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "n8n-sandbox-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "n8n-sandbox-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "n8n-sandbox-service.sandboxImage" -}}
{{- $runner := fromYaml (include "n8n-sandbox-service.runnerValues" .) -}}
{{- printf "%s:%s" $runner.sandboxImage.repository $runner.sandboxImage.tag }}
{{- end }}
