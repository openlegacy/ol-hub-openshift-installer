#!/usr/bin/env bash
# SQL against the shared database: in the bundled Postgres pod, or (external DB) in a throwaway pod.
# SQL is passed on stdin; credentials come from the ol-db secret inside the pod.

psql_stdin() {   # psql_stdin [extra psql args] < file.sql
  if [[ "$BUNDLED_DB" == true ]]; then
    oc -n "$NAMESPACE" exec -i deploy/hub-enterprise-postgres -- \
      sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At "$@"' psql "$@"
  else
    local pod="ol-psql-$RANDOM"
    local ov
    ov=$(jq -n --arg img "$IMAGE_POSTGRES" --arg ps "${IMAGE_PULL_SECRET}" '{spec:{
      imagePullSecrets: (if $ps=="" then [] else [{name:$ps}] end),
      containers:[{name:"psql",image:$img,stdin:true,stdinOnce:true,
        command:["sh","-c","PGPASSWORD=\"$OL_DB_PASSWORD\" psql -v ON_ERROR_STOP=1 -h \"$OL_DB_HOST\" -p \"$OL_DB_PORT\" -U \"$OL_DB_USER\" -d \"$OL_DB_NAME\" -At"],
        envFrom:[{secretRef:{name:"ol-db"}}]}]}}')
    oc -n "$NAMESPACE" run "$pod" --rm -i --quiet --restart=Never --image="$IMAGE_POSTGRES" --overrides="$ov"
  fi
}

psql_c() { printf '%s\n' "$1" | psql_stdin; }

db_prepare() {
  # Keycloak keeps its tables in its own schema (KC_DB_SCHEMA=keycloak). The Hub image creates it too, but
  # Keycloak starts before the Hub, so make sure it exists first (no-op when it does).
  psql_c "CREATE SCHEMA IF NOT EXISTS keycloak;" >/dev/null
  ok "schema keycloak ready"
}

# The tenant + master licence are created by the Hub image (its migration / first start).
# First ACTIVE tenant -> TENANT_ID / TENANT_ORG (empty when there is none yet)
# Prefers TENANT_PREF (the tenant create_tenant wrote / TENANT_ID / the licence's tenant) when it is ACTIVE.
read_tenant() {
  local row pref=${TENANT_PREF:-${CONF_TENANT_ID:-}}
  [[ "$pref" =~ ^[0-9a-fA-F-]{36}$ ]] || pref=00000000-0000-0000-0000-000000000000
  row=$(psql_c "SELECT id || '|' || coalesce(organization,'') FROM operational.tenant WHERE status='ACTIVE' ORDER BY (id = '$pref') DESC, created_at LIMIT 1;" 2>/dev/null | head -1 || true)
  TENANT_ID=${row%%|*}; TENANT_ORG=${row#*|}
  [[ "$row" == *"|"* ]] || { TENANT_ID=""; TENANT_ORG=""; }
}
