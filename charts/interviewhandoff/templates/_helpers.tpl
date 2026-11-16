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

{{- define "interviewhandoff.workerImage" -}}
{{- printf "%s/%s:%s" .Values.global.registry .Values.worker.image.repository .Values.worker.image.tag -}}
{{- end -}}

{{/* Pod scheduling extras: priority class, and spread replicas across nodes. Call with
     (dict "root" $ "app" "<app label>" "replicas" N). */}}
{{- define "interviewhandoff.scheduling" -}}
{{- with .root.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- if gt (int .replicas) 1 }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: {{ .app }}
{{- end }}
{{- end }}
