{{/*
Name of a SecretProviderClass: <secretProviderClassPrefix>-<component>-secret-provider-class,
or <component>-secret-provider-class when the prefix is empty.
*/}}
{{- define "ascp.spcName" -}}
{{- $prefix := .root.Values.secretProviderClassPrefix -}}
{{- if $prefix -}}
{{- printf "%s-%s-secret-provider-class" $prefix .component -}}
{{- else -}}
{{- printf "%s-secret-provider-class" .component -}}
{{- end -}}
{{- end -}}
