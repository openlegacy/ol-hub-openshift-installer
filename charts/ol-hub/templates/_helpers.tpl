{{/* Effective Hub env: base env + the env of every enabled app (values rendered with tpl) */}}
{{- define "ol-hub.env" -}}
{{- $root := . -}}
{{- $env := dict -}}
{{- range $k, $v := .Values.env }}{{ $_ := set $env $k (tpl (toString $v) $root) }}{{ end -}}
{{- range $app, $on := .Values.apps }}
{{- if $on }}
{{- range $k, $v := (index $root.Values.integrations $app) }}{{ $_ := set $env $k (tpl (toString $v) $root) }}{{ end }}
{{- end }}
{{- end -}}
{{- range $k := keys $env | sortAlpha }}
- name: {{ $k }}
  value: {{ index $env $k | quote }}
{{- end }}
{{- range .Values.secretEnv }}
- name: {{ . }}
  valueFrom: {secretKeyRef: {name: {{ $root.Values.global.hubSecret }}, key: {{ . }}}}
{{- end }}
{{- end -}}
