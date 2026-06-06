{{/* Common labels for all resources */}}
{{- define "hiresense.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "hiresense.image" -}}
{{- printf "%s/%s:%s" .Values.global.registry .repository .tag -}}
{{- end -}}
