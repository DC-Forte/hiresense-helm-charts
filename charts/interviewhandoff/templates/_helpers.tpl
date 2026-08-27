{{/* Common labels for all resources */}}
{{- define "interviewhandoff.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "interviewhandoff.image" -}}
{{- printf "%s/%s:%s" .Values.global.registry .Values.image.repository .Values.image.tag -}}
{{- end -}}
