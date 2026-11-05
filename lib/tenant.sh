#!/usr/bin/env bash
# Tenant + master licence, the way the official on-prem bundle and the Hub do it (ol-hub release/4.0.0):
#
# 1. seed_tenant - always. A fresh Hub migration creates no tenant (no route creates one either), so the
#    installer inserts the ACTIVE operational.tenant row by SQL, like ol-hub/ops/onprem/install.sh. Default id:
#    the built-in tenant 4a6bfc5d... whose admin (Keycloak user ol-hub, 9a780e8b...) OL-Integration seeds in
#    data_<tenant> at boot - so the row must exist before OL-Integration first starts. keycloak_sync then
#    creates that user and its auth.tenant_user_role admin row.
#
# 2. activate_license - when MASTER_LICENSE_FILE is set. The licence is NOT written by SQL: it is activated
#    through the Hub, PUT /backoffice/api/v1/tenants/<id>/license {"license": "<JWT>"}, as the tenant admin
#    (the shell's licence screen calls the same route). The Hub verifies the RS256 signature, refuses expired
#    or non-MASTER licences, truncates expirationDate to the day (every app's licence check compares that
#    value with the JWT) and stores the row (key = the JWT, dev_key = its devKey). Run after the apps are up,
#    when the admin role resolves (RBAC "hub" without OL-Integration, "legacy" = OL-Integration with it).

b64url_decode() { local s; s=$(tr '_-' '/+'); while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | openssl base64 -d -A; }

# Decode + validate MASTER_LICENSE_FILE locally -> LIC_JWT, LIC_PAYLOAD (JSON), LIC_ID
read_license() {
  [[ -f "$MASTER_LICENSE_FILE" ]] || die "MASTER_LICENSE_FILE '$MASTER_LICENSE_FILE' not found"
  LIC_JWT=$(tr -d ' \r\n\t' < "$MASTER_LICENSE_FILE")
  [[ "$LIC_JWT" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || die "$MASTER_LICENSE_FILE is not a JWT (header.payload.signature)"
  local hdr; hdr=$(cut -d. -f1 <<<"$LIC_JWT" | b64url_decode) || die "licence header is not base64url"
  LIC_PAYLOAD=$(cut -d. -f2 <<<"$LIC_JWT" | b64url_decode) || die "licence payload is not base64url"
  jq -e . >/dev/null 2>&1 <<<"$LIC_PAYLOAD" || die "licence payload is not JSON"
  [[ "$(jq -r '.alg // ""' <<<"$hdr")" == RS256 ]] || warn "licence alg is '$(jq -r '.alg // "?"' <<<"$hdr")' (expected RS256)"
  [[ "$(jq -r '.licenseType // ""' <<<"$LIC_PAYLOAD")" == MASTER ]] || die "not a MASTER licence (licenseType=$(jq -r '.licenseType // "?"' <<<"$LIC_PAYLOAD"))"
  local f; for f in masterLicenseId expirationDate gracePeriodDays tenantId issueDate; do
    jq -e --arg f "$f" 'has($f) and .[$f] != null' >/dev/null <<<"$LIC_PAYLOAD" || die "licence has no $f (the Hub refuses it)"
  done
  LIC_ID=$(jq -r .masterLicenseId <<<"$LIC_PAYLOAD")
  local exp grace; exp=$(jq -r '.expirationDate' <<<"$LIC_PAYLOAD"); grace=$(jq -r .gracePeriodDays <<<"$LIC_PAYLOAD")
  if [[ "$(jq -rn --arg e "$exp" --argjson g "$grace" '(($e|sub("\\.[0-9]+";"")|fromdateiso8601) + $g*86400) < now')" == true ]]; then
    die "licence $LIC_ID expired on $exp and its $grace-day grace period is over - the Hub refuses it"
  fi
  info "licence $LIC_ID: expires $exp, grace $grace days"
}

tenant_id_target() { echo "${CONF_TENANT_ID:-$DEFAULT_TENANT_ID}"; }

# 1. The ACTIVE tenant row (idempotent). Columns as in ol-hub/ops/onprem/install.sh.
seed_tenant() {
  section "Tenant"
  local tid; tid=$(tenant_id_target)
  [[ "$tid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "TENANT_ID '$tid' is not a UUID"
  local contact=${TENANT_CONTACT:-${HUB_ADMIN_USER:-ol-hub}}
  psql_stdin >/dev/null <<SQL
INSERT INTO operational.tenant (id, organization, contact_person, created_at, status, update_status_at, update_at)
VALUES (\$ol\$$tid\$ol\$::uuid, \$ol\$$TENANT_ORGANIZATION\$ol\$, \$ol\$$contact\$ol\$, now(), 'ACTIVE', now(), now())
ON CONFLICT (id) DO NOTHING;
SQL
  TENANT_PREF=$tid
  local st; st=$(psql_c "SELECT status FROM operational.tenant WHERE id = '$tid';" | head -1)
  [[ -n "$st" ]] || die "tenant $tid was not written"
  [[ "$st" == ACTIVE ]] || warn "tenant $tid exists with status $st (not ACTIVE) - left as it is"
  ok "tenant $tid ($st, $TENANT_ORGANIZATION)"
}

# Admin token for user ol-hub (hub-spa password grant) -> stdout. Never printed by callers.
admin_token() {
  local pw; pw=$(secret_value ol-hub-admin-user password)
  curl -sk --max-time 30 -d grant_type=password -d client_id=hub-spa -d "username=$HUB_ADMIN_USER" \
    --data-urlencode "password=$pw" "https://${KEYCLOAK_HOST}/auth/realms/ol-hub/protocol/openid-connect/token" \
    | jq -r '.access_token // empty'
}

# 2. Licence activation through the Hub (idempotent).
activate_license() {
  [[ -n "$MASTER_LICENSE_FILE" ]] || { warn "MASTER_LICENSE_FILE not set - the tenant has no licence; activate it in the Hub UI or set it and run ./install.sh create-tenant"; return 0; }
  section "Master licence"
  read_license
  local tid; tid=$(tenant_id_target)

  # One licence, one tenant
  local owner; owner=$(psql_c "SELECT tenant_id FROM operational.master_license WHERE id = '$LIC_ID';" | head -1 || true)
  if [[ -n "$owner" && "$owner" != "$tid" ]]; then
    die "licence $LIC_ID is already stored for tenant $owner - a tenant needs its own licence (or set TENANT_ID=$owner)"
  fi
  # Rows written by earlier installer versions (raw expiry time, not the Hub's day-truncated value): the Hub
  # only re-links an existing licence row, so drop it and let the Hub store it again.
  local stale; stale=$(psql_c "SELECT count(*) FROM operational.master_license WHERE id = '$LIC_ID' AND expiration_date <> date_trunc('day', expiration_date AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';" | head -1)
  if [[ "$stale" == 1 ]]; then
    psql_c "BEGIN; UPDATE operational.tenant SET master_license_id = NULL WHERE master_license_id = '$LIC_ID'; DELETE FROM operational.master_license WHERE id = '$LIC_ID'; COMMIT;" >/dev/null
    info "replaced licence row $LIC_ID written by an earlier installer version (expiry not day-truncated)"
  fi

  # Already active for this tenant: nothing to do, so no admin login (whose password may have been
  # changed in the Keycloak UI) is needed on a re-install.
  local linked; linked=$(psql_c "SELECT to_char(m.expiration_date AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') FROM operational.tenant t JOIN operational.master_license m ON m.id = t.master_license_id WHERE t.id = '$tid' AND m.id = '$LIC_ID';" | head -1 || true)
  if [[ -n "$linked" ]]; then
    ok "licence $LIC_ID already active for tenant $tid (stored expiry $linked UTC) - skipped"
    return 0
  fi

  local tok i code body; body=$(mktemp); chmod 600 "$body"
  for i in 1 2 3 4 5 6; do   # the admin role may take a moment to resolve right after the apps start
    tok=$(admin_token)
    [[ -n "$tok" ]] || { rm -f "$body"; die "no token for user '$HUB_ADMIN_USER' from https://${KEYCLOAK_HOST} (./install.sh sync-keycloak)"; }
    code=$(jq -n --arg l "$LIC_JWT" '{license:$l}' | curl -sk --max-time 60 -o "$body" -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' --data-binary @- \
      "https://${HUB_HOST}/backoffice/api/v1/tenants/${tid}/license")
    [[ "$code" == 2* ]] && break
    [[ "$code" == 503 || "$code" == 000 ]] || break   # 4xx: refused for good
    info "  Hub answered $code - retrying in 10s ($i/6)"; sleep 10
  done
  unset tok
  if [[ "$code" != 2* ]]; then
    local msg; msg=$(jq -r '.detailedMessage // .message // empty' "$body" 2>/dev/null | head -c 300); rm -f "$body"
    die "licence activation failed: HTTP $code${msg:+ - $msg}"
  fi
  rm -f "$body"

  local row; row=$(psql_c "SELECT coalesce(m.id::text,'none') || '|' || coalesce(to_char(m.expiration_date AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI'),'') FROM operational.tenant t LEFT JOIN operational.master_license m ON m.id = t.master_license_id WHERE t.id = '$tid';" | head -1)
  [[ "${row%%|*}" == "$LIC_ID" ]] || die "the Hub accepted the licence but tenant $tid is linked to '${row%%|*}'"
  ok "licence $LIC_ID activated for tenant $tid (stored expiry ${row#*|} UTC)"
}

# ./install.sh create-tenant : the same three steps on an existing install
create_tenant() {
  [[ -z "$MASTER_LICENSE_FILE" ]] || read_license
  seed_tenant
  keycloak_sync
  activate_license
}
