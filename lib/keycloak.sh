#!/usr/bin/env bash
# Keycloak realm ol-hub, kept in sync on every run with kcadm inside the Keycloak pod (logs in with the
# pod's own bootstrap-admin env; no admin password leaves the pod):
#   - user profile: unmanagedAttributePolicy=ENABLED, or the ol-tenantId / ol-company / ol-fullname user
#     attributes (copied into every token by the hub-spa mappers) are silently dropped (the realm template sets
#     it too; this repairs realms imported elsewhere)
#   - hub-spa redirect URIs + web origins: the Hub route, every app Route, EXTRA_REDIRECT_URIS (kept: existing ones)
#   - the built-in admin: user "ol-hub" with the fixed id 9a780e8b... (seeded as admin by the Hub and
#     OL-Integration), linked to the tenant (ol-tenantId), password from secret ol-hub-admin-user

# Pod-side prelude: log in with a fresh, per-call config (a cached session expires and kcadm then fails with
# "Session has expired"), then $K <subcommand> ... runs kcadm with it; the config is removed on exit.
# (kcadm only accepts --config after the subcommand.)
KC_PRELUDE='
  C=$(mktemp /tmp/kcadm.XXXXXX); trap "rm -f $C" EXIT
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --config "$C"; }
  /opt/keycloak/bin/kcadm.sh config credentials --config "$C" --server http://localhost:8080/auth \
    --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 \
    || { echo "kcadm login failed (bootstrap admin from secret ol-keycloak-admin)" >&2; exit 1; }
  K=kc
'
kc_exec() {   # kc_exec '$K get ...' ; stdin is passed through
  oc -n "$NAMESPACE" exec -i deploy/hub-enterprise-keycloak -- bash -c "$KC_PRELUDE$1"
}

wait_realm() {
  local i
  for i in $(seq 1 60); do
    curl -sk -o /dev/null -w '%{http_code}' "https://${KEYCLOAK_HOST}/auth/realms/ol-hub" 2>/dev/null | grep -q 200 && return 0
    oc -n "$NAMESPACE" exec deploy/hub-enterprise-keycloak -- curl -s -o /dev/null -w '%{http_code}' \
      http://localhost:8080/auth/realms/ol-hub 2>/dev/null | grep -q 200 && return 0
    sleep 5
  done
  die "realm ol-hub did not come up"
}

required_redirects() {
  local uris=("https://${HUB_HOST}/*") a
  for a in "${SELECTED_APPS[@]}"; do [[ -n "${APP_HOST[$a]:-}" ]] && uris+=("https://${APP_HOST[$a]}/*"); done
  for a in $EXTRA_REDIRECT_URIS; do uris+=("$a"); done
  printf '%s\n' "${uris[@]}"
}

keycloak_sync() {
  section "Keycloak realm ol-hub"
  wait_realm
  local tmp; tmp=$(mktemp -d); chmod 700 "$tmp"

  # 1. user profile
  kc_exec '$K get users/profile -r ol-hub' > "$tmp/profile.json"
  if [[ "$(jq -r '.unmanagedAttributePolicy // ""' "$tmp/profile.json")" != ENABLED ]]; then
    jq '.unmanagedAttributePolicy="ENABLED"' "$tmp/profile.json" | kc_exec '$K update users/profile -r ol-hub -f -' >/dev/null
    ok "user profile: unmanaged attributes enabled"
  fi

  # 2. hub-spa redirect URIs / web origins (union - URIs added by hand are kept)
  kc_exec '$K get clients -r ol-hub -q clientId=hub-spa' > "$tmp/clients.json"
  local cid; cid=$(jq -r '.[0].id // empty' "$tmp/clients.json")
  [[ -n "$cid" ]] || die "client hub-spa not found in realm ol-hub"
  required_redirects > "$tmp/req.txt"
  jq --rawfile req "$tmp/req.txt" '.[0]
      | .redirectUris = ((.redirectUris // []) + ($req|split("\n")|map(select(length>0))) | map(select(test("__|\\$\\{")|not)) | unique)
      | .webOrigins = ((.webOrigins // []) + ["+"] | unique)' "$tmp/clients.json" > "$tmp/hub-spa.json"
  kc_exec "\$K update clients/$cid -r ol-hub -f -" < "$tmp/hub-spa.json" >/dev/null
  ok "hub-spa redirect URIs: $(jq -r '.redirectUris|join(" ")' "$tmp/hub-spa.json")"

  # 3. the built-in admin: realm user "ol-hub" with the fixed id HUB_ADMIN_ID, which the Hub
  #    (auth.tenant_user_role) and OL-Integration (data_<tenant>.user_role) seed as admin of the default tenant.
  #    Created by partial import - the only admin API that keeps a given id. Password: secret ol-hub-admin-user.
  local pw; pw=$(secret_value ol-hub-admin-user password)
  if [[ -z "${TENANT_PREF:-}" ]]; then TENANT_PREF=${CONF_TENANT_ID:-$DEFAULT_TENANT_ID}; fi
  read_tenant
  local attrs='{}'
  if [[ -n "$TENANT_ID" ]]; then
    attrs=$(jq -n --arg t "$TENANT_ID" --arg o "${TENANT_ORG:-OpenLegacy}" \
      '{"ol-tenantId":[$t],"ol-company":[$o],"ol-fullname":["ol-hub"]}')
  else
    warn "No ACTIVE tenant (MASTER_LICENSE_FILE + ./install.sh create-tenant) - user '$HUB_ADMIN_USER' is not linked yet"
  fi
  if ! kc_exec "\$K get users/$HUB_ADMIN_ID -r ol-hub" > "$tmp/u.json" 2>/dev/null; then
    jq -n --arg id "$HUB_ADMIN_ID" --arg u "$HUB_ADMIN_USER" --arg e "$HUB_ADMIN_EMAIL" --argjson a "$attrs" '{ifResourceExists:"SKIP", users:[{
        id:$id, username:$u, email:(if $e == "" then null else $e end), enabled:true, emailVerified:true, firstName:"ol", lastName:"hub", attributes:$a,
        realmRoles:["uma_authorization","offline_access"], clientRoles:{account:["manage-account","view-profile"]}}]}' \
      | kc_exec '$K create partialImport -r ol-hub -f -' >/dev/null
    kc_exec "\$K get users/$HUB_ADMIN_ID -r ol-hub" > "$tmp/u.json" 2>/dev/null \
      || die "could not create user '$HUB_ADMIN_USER' with id $HUB_ADMIN_ID (another user named '$HUB_ADMIN_USER'? delete it in the Keycloak console)"
    printf '%s\n' "$pw" | kc_exec "read -r PW; \$K set-password -r ol-hub --userid $HUB_ADMIN_ID --new-password \"\$PW\"" >/dev/null
    ok "user '$HUB_ADMIN_USER'${HUB_ADMIN_EMAIL:+ <$HUB_ADMIN_EMAIL>} ($HUB_ADMIN_ID) created${TENANT_ID:+, tenant $TENANT_ID}"
  else
    jq --argjson a "$attrs" --arg e "$HUB_ADMIN_EMAIL" '.attributes = ((.attributes // {}) + $a)
        | if $e != "" then .email = $e | .emailVerified = true else . end' "$tmp/u.json" \
      | kc_exec "\$K update users/$HUB_ADMIN_ID -r ol-hub -f -" >/dev/null \
      || die "could not update user '$HUB_ADMIN_USER' (is '$HUB_ADMIN_EMAIL' already the email of another realm user?)"
    ok "user '$HUB_ADMIN_USER'${HUB_ADMIN_EMAIL:+ <$HUB_ADMIN_EMAIL>}${TENANT_ID:+ linked to tenant $TENANT_ID}"
  fi

  # 4. admin role rows (normally seeded already for the default tenant; added for any other TENANT_ID).
  #    Without them every backoffice / licence call answers 503 "Could not resolve the tenant role".
  if [[ -n "$TENANT_ID" ]]; then
    local ds="data_${TENANT_ID//-/_}"
    psql_c "INSERT INTO auth.tenant_user_role (tenant_id, user_id, role) VALUES ('$TENANT_ID', '$HUB_ADMIN_ID', 'admin') ON CONFLICT (tenant_id, user_id) DO NOTHING;
DO \$\$ BEGIN
  IF to_regclass('$ds.user_role') IS NOT NULL THEN
    INSERT INTO $ds.user_role (user_id, role) SELECT '$HUB_ADMIN_ID', 'admin'
    WHERE NOT EXISTS (SELECT 1 FROM $ds.user_role WHERE user_id = '$HUB_ADMIN_ID');
  END IF;
END \$\$;" >/dev/null
    psql_c "SELECT to_regclass('$ds.user_role') IS NOT NULL;" | grep -q t \
      || warn "OL-Integration has no schema $ds - roles for tenant $TENANT_ID come only from the Hub (OL-Integration seeds the default tenant only)"
    ok "user '$HUB_ADMIN_USER' is admin of tenant $TENANT_ID"
  fi
  rm -rf "$tmp"
}
