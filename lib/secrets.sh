#!/usr/bin/env bash
# Secrets: generated once, never overwritten (rotating an encryption key in place makes stored data
# unreadable). A re-run only adds keys that are missing. Values never reach stdout or a command line.

gen_hex()    { openssl rand -hex "$1" | tr -d '\n'; }                                  # 2*N hex chars
gen_alnum()  { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
gen_b64()    { openssl rand -base64 "$1" | tr -d '\n'; }
# Hub API-key signing key, in the format the Hub reads: "{base64}" + base64(PKCS#8 PEM, RSA 2048)
gen_pk_sign() { printf '{base64}%s' "$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | base64 | tr -d '\n')"; }

# ensure_secret NAME KEY=generator-or-literal ...
#   KEY=@hex:32 | @alnum:24 | @b64:32 | @pksign  -> generated
#   KEY=value                                    -> literal (used only when the key is missing)
ensure_secret() {
  local name=$1; shift
  local tmp; tmp=$(mktemp -d); chmod 700 "$tmp"
  local existing="" spec key val added=0
  if oc -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    existing=$(oc -n "$NAMESPACE" get secret "$name" -o json | jq -r '.data // {} | keys[]')
  fi
  local patch='{}'
  for spec in "$@"; do
    key=${spec%%=*}; val=${spec#*=}
    grep -qx -- "$key" <<<"$existing" && continue
    case "$val" in
      @hex:*)   gen_hex "${val#@hex:}"     > "$tmp/v" ;;
      @alnum:*) gen_alnum "${val#@alnum:}" > "$tmp/v" ;;
      @b64:*)   gen_b64 "${val#@b64:}"     > "$tmp/v" ;;
      @pksign)  gen_pk_sign                > "$tmp/v" ;;
      *)        printf '%s' "$val"         > "$tmp/v" ;;
    esac
    patch=$(jq --arg k "$key" --rawfile v "$tmp/v" '. + {($k): ($v|@base64)}' <<<"$patch")
    added=$((added + 1))
  done
  if [[ -z "$existing" ]] && ! oc -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    jq -n --arg n "$name" --argjson d "$patch" \
      '{apiVersion:"v1",kind:"Secret",type:"Opaque",metadata:{name:$n,labels:{"app.kubernetes.io/part-of":"ol-hub"}},data:$d}' \
      > "$tmp/s.json"
    oc -n "$NAMESPACE" create -f "$tmp/s.json" >/dev/null
    ok "secret/$name created ($added keys)"
  elif (( added > 0 )); then
    jq -n --argjson d "$patch" '{data:$d}' > "$tmp/p.json"
    oc -n "$NAMESPACE" patch secret "$name" --type=merge --patch-file "$tmp/p.json" >/dev/null
    ok "secret/$name: added $added missing key(s)"
  else
    info "secret/$name exists - unchanged"
  fi
  rm -rf "$tmp"
}

secret_value() { oc -n "$NAMESPACE" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d; }

# Every secret the selected install needs
ensure_all_secrets() {
  section "Secrets"
  local dbpw=@alnum:24
  [[ -n "$DB_PASSWORD" ]] && dbpw=$DB_PASSWORD
  # One DB secret for everything: the same OL_DB_* names are read by the Hub and every app (envFrom)
  ensure_secret ol-db OL_DB_TYPE=postgres OL_DB_HOST="$DB_HOST" OL_DB_PORT="$DB_PORT" OL_DB_NAME="$DB_NAME" \
    OL_DB_USER="$DB_USER" OL_DB_PASSWORD="$dbpw"
  ensure_secret ol-keycloak-admin username=admin password=@alnum:24
  # Hub secrets; KEYCLOAK_MANAGEMENT_CLIENT_SECRET is also the realm's hub-client secret
  ensure_secret ol-hub-secrets OL_HUB_ENCRYPT_SECRET=@alnum:32 OL_HUB_PK_API_KEY_SIGN=@pksign \
    OL_INTERNAL_SERVICE_SECRET=@hex:32 KEYCLOAK_MANAGEMENT_CLIENT_SECRET=@alnum:32
  ensure_secret ol-hub-admin-user username="$HUB_ADMIN_USER" password=@alnum:20
  if [[ "$(secret_value ol-hub-admin-user username)" != "$HUB_ADMIN_USER" ]]; then   # installs made before the fixed admin
    oc -n "$NAMESPACE" patch secret ol-hub-admin-user --type=merge -p "{\"stringData\":{\"username\":\"$HUB_ADMIN_USER\"}}" >/dev/null
  fi

  local a
  for a in "${SELECTED_APPS[@]}"; do
    case $a in
      ol-code)      ensure_secret ol-code-secrets OL_PASSWORD=@alnum:24 CREDENTIAL_ENCRYPTION_KEY=@hex:32 ;;
      ol-terminal)  ensure_secret ol-terminal-secrets OL_ADMIN=admin OL_PASSWORD=@alnum:24 CREDENTIAL_ENCRYPTION_KEY=@hex:32 ;;
      ol-coreiq)    ensure_secret coreiq-secrets CREDENTIAL_ENCRYPTION_KEY=@hex:32 ADMIN_PASSKEY=@alnum:32 OL_ADMIN=admin OL_PASSWORD=@alnum:24 ;;
      ol-atomiq)    ensure_secret atomiq-secrets ADMIN_PASSKEY=@alnum:32 SETTINGS_ENCRYPTION_KEY=@hex:32 CREDENTIAL_ENCRYPTION_KEY=@hex:32 ;;
      ol-dataiq)    ensure_secret dataiq-secrets db-encryption-secret=@b64:32 ;;
      ol-dataiq-batch) ensure_secret dataiq-batch-secrets api-key=@hex:24 ;;
    esac
  done
}

# ./install.sh set-secret <app> KEY=VALUE  - set one key of <app>-secrets and restart the app
set_app_secret() {
  local app; app=$(canonical_app "$1"); local kv=$2 key=${2%%=*} val=${2#*=}
  in_list "$app" "${APP_ORDER[@]}" || die "Unknown app '$app'"
  local name; name="$(app_obj "$app")-secrets"; local tmp; tmp=$(mktemp -d); chmod 700 "$tmp"
  printf '%s' "$val" > "$tmp/v"
  jq -n --arg k "$key" --rawfile v "$tmp/v" '{data:{($k):($v|@base64)}}' > "$tmp/p.json"
  if oc -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    oc -n "$NAMESPACE" patch secret "$name" --type=merge --patch-file "$tmp/p.json" >/dev/null
  else
    jq --arg n "$name" '{apiVersion:"v1",kind:"Secret",type:"Opaque",metadata:{name:$n}} + .' "$tmp/p.json" > "$tmp/s.json"
    oc -n "$NAMESPACE" create -f "$tmp/s.json" >/dev/null
  fi
  rm -rf "$tmp"; : "$kv"
  ok "secret/$name: $key set"
  oc -n "$NAMESPACE" rollout restart "deploy/$app" >/dev/null 2>&1 && info "restarted deploy/$app"
}
