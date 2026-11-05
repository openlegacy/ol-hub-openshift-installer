{{- define "ol-app.svc" -}}{{ default .Values.name .Values.serviceName }}{{- end -}}
{{- define "ol-app.host" -}}
{{- if .Values.route.host }}{{ tpl .Values.route.host . }}{{ else }}{{ .Values.name }}-{{ .Release.Namespace }}.{{ .Values.global.appsDomain }}{{ end -}}
{{- end -}}
