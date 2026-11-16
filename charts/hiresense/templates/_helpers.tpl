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

{{/* Pod scheduling extras: priority class, and spread replicas across nodes. Call with
     (dict "root" $ "app" "<app label>" "replicas" N). */}}
{{- define "hiresense.scheduling" -}}
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
