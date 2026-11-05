#!/usr/bin/env bash
# OpenLegacy Hub on OpenShift - installer.
#
#   ./install.sh [install]            install / upgrade (idempotent; safe to re-run; installed apps are kept)
#   ./install.sh add APP [APP...]     add apps to an existing install (+ their dependencies)
#   ./install.sh remove APP [APP...]  switch apps off in the Hub and uninstall them (data volumes/secrets kept)
#   ./install.sh status               releases, pods, URLs, Hub /config
#   ./install.sh create-tenant        tenant row + admin user, then activate MASTER_LICENSE_FILE through the Hub
#   ./install.sh sync-keycloak        re-apply realm settings (redirect URIs, user profile, admin user)
#   ./install.sh set-secret APP K=V   set one key of the app's secret and restart the app
#   ./install.sh uninstall [--purge]  remove the releases (--purge also deletes PVCs and secrets)
# Options: -c <conf> (default ./install.conf), -y (no prompts), --dry-run (render only)
#
# Order: postgres 17 (+ schema keycloak) -> keycloak (realm ol-hub) -> hub (migration) -> tenant row ->
#        realm sync (admin user ol-hub + its tenant role) -> optional apps -> hub again with the apps switched
#        on -> master licence activated through the Hub (MASTER_LICENSE_FILE).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_FILE="$ROOT/install.conf"
ASSUME_YES=false; DRY_RUN=false; PURGE=false; CMD=install; CMD_ARGS=()

(( BASH_VERSINFO[0] >= 4 )) || { echo "bash 4+ is required (macOS: brew install bash)" >&2; exit 1; }
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/secrets.sh
source "$ROOT/lib/secrets.sh"
# shellcheck source=lib/db.sh
source "$ROOT/lib/db.sh"
# shellcheck source=lib/keycloak.sh
source "$ROOT/lib/keycloak.sh"
# shellcheck source=lib/tenant.sh
source "$ROOT/lib/tenant.sh"

while (( $# )); do
  case $1 in
    -c) CONF_FILE=$2; shift ;;
    -y|--yes) ASSUME_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --purge) PURGE=true ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    install|add|remove|status|create-tenant|sync-keycloak|set-secret|uninstall) CMD=$1 ;;
    *) CMD_ARGS+=("$1") ;;
  esac
  shift
done

GEN="$ROOT/generated"; GLOBAL="$GEN/global-values.yaml"
HELM_TIMEOUT=${HELM_TIMEOUT:-15m}

preflight() {
  section "Prerequisites"
  local c; for c in oc helm jq openssl base64 curl; do need "$c"; done
  helm version --short | grep -qE '^v(3\.(1[0-9]|[89])|[4-9])' || die "helm 3.8+ is required"
  if [[ "$DRY_RUN" == true ]] && ! oc whoami >/dev/null 2>&1; then
    warn "dry run without a cluster login: set APPS_DOMAIN in the config"; return 0
  fi
  oc whoami >/dev/null 2>&1 || die "Not logged in: oc login <cluster>"
  oc api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -q routes || die "Not an OpenShift cluster (no route.openshift.io)"
  info "Cluster: $(oc whoami --show-server)  user: $(oc whoami)  context: $(oc config current-context)"
  confirm "Use this cluster?" || die "Aborted"
}

write_global_values() {
  mkdir -p "$GEN"
  local hosts='{}' a
  for a in "${!APP_HOST[@]}"; do hosts=$(jq --arg k "$a" --arg v "${APP_HOST[$a]}" '. + {($k):$v}' <<<"$hosts"); done
  jq -n --arg ns "$NAMESPACE" --arg dom "$APPS_DOMAIN" --arg hub "$HUB_HOST" --arg kc "$KEYCLOAK_HOST" \
    --argjson hosts "$hosts" --arg dbh "$DB_HOST" --arg dbp "$DB_PORT" --arg dbn "$DB_NAME" \
    --arg sc "$STORAGE_CLASS" --arg ps "$IMAGE_PULL_SECRET" '{global:{
      namespace:$ns, appsDomain:$dom, hubHost:$hub, keycloakHost:$kc, appHosts:$hosts,
      hubInternal:"http://ol-hub",
      keycloakService:"hub-enterprise-keycloak",
      keycloakInternal:"https://hub-enterprise-keycloak/auth",
      keycloakPublic:("https://"+$kc+"/auth"),
      issuer:("https://"+$kc+"/auth/realms/ol-hub"),
      db:{host:$dbh, port:$dbp, name:$dbn},
      dbSecret:"ol-db", hubSecret:"ol-hub-secrets", keycloakAdminSecret:"ol-keycloak-admin",
      storageClass:$sc, imagePullSecret:$ps}}' > "$GLOBAL"
  info "Values: $GLOBAL"
}

helm_up() {   # helm_up <release> <chart> [helm args...]
  local rel=$1 chart=$2; shift 2
  if [[ "$DRY_RUN" == true ]]; then
    helm template "$rel" "$chart" -n "$NAMESPACE" -f "$GLOBAL" "$@" > "$GEN/rendered-$rel.yaml"
    info "rendered $GEN/rendered-$rel.yaml"; return 0
  fi
  info "helm upgrade --install $rel"
  # --force-conflicts: Helm 4 applies server-side, so a manual `oc set image/env` would otherwise own
  # that field and block every later upgrade. The installer's values win.
  helm upgrade --install "$rel" "$chart" -n "$NAMESPACE" -f "$GLOBAL" --force-conflicts --wait --timeout "$HELM_TIMEOUT" "$@" >/dev/null \
    || { oc -n "$NAMESPACE" get pods -o wide | sed 's/^/    /'; die "release $rel failed (see: oc -n $NAMESPACE get events --sort-by=.lastTimestamp)"; }
  ok "$rel"
}

deploy_ready() { [[ "$(oc -n "$NAMESPACE" get deploy "$1" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" == 1 ]]; }

hub_apps_args() {   # --set apps.<x>=true for every selected app that is Ready
  local args=() a
  for a in "${SELECTED_APPS[@]}"; do
    in_list "$a" "${APPS_IN_HUB[@]}" || continue
    # an app not upgraded since the ol- prefix still runs under its old Deployment name
    if [[ "$DRY_RUN" == true ]] || deploy_ready "$a" || deploy_ready "$(app_obj "$a")"; then args+=(--set "apps.$a=true")
    else warn "$a is not Ready - left switched off in the Hub (re-run when it is)"; fi
  done
  (( ${#args[@]} == 0 )) || printf '%s\n' "${args[@]}"
}

hub_switch() {   # Hub upgrade with every selected + Ready app switched on (no migration)
  local hub_args=()
  mapfile -t hub_args < <(hub_apps_args)
  helm_up hub "$ROOT/charts/ol-hub" --set-string "image=$IMAGE_HUB" --set-string "imagePullPolicy=$IMAGE_PULL_POLICY" \
    --set migration.enabled=false "${hub_args[@]}"
}

install_app() {
  local a=$1 img rel; img=$(app_image "$a")
  [[ -n "$img" ]] || die "$(image_var "$a") is not set (images.conf / install.conf)"
  rel=$(app_release "$a")   # an install made before the ol- prefix keeps its release name
  [[ "$rel" == "$a" ]] || info "$a: keeping existing Helm release '$rel'"
  local old pvc="$a-data"; old=$(app_obj "$a")
  if [[ "$old" != "$a" && "$DRY_RUN" != true ]]; then
    # install from before the ol- prefix: keep its volume, and stop the old Deployment first (it holds the
    # RWO volume; Helm deletes it once the release has the new one)
    oc -n "$NAMESPACE" get pvc "$old-data" >/dev/null 2>&1 && pvc="$old-data"
    if oc -n "$NAMESPACE" get deploy "$old" >/dev/null 2>&1; then
      info "$a: Deployment '$old' is renamed to '$a' (Service, secrets and volume keep their names)"
      oc -n "$NAMESPACE" scale deploy "$old" --replicas=0 >/dev/null
      oc -n "$NAMESPACE" wait pod -l "app=$old" --for=delete --timeout=180s >/dev/null 2>&1 || true
    fi
  fi
  helm_up "$rel" "$ROOT/charts/ol-app" -f "$ROOT/apps/$a.yaml" \
    --set-string "image=$img" --set-string "imagePullPolicy=$IMAGE_PULL_POLICY" --set-string "persistence.claimName=$pvc"
}

do_install() {
  preflight
  load_config
  derive_hosts
  section "Plan"
  info "Namespace:  $NAMESPACE"
  info "Hub:        https://$HUB_HOST"
  info "Keycloak:   https://$KEYCLOAK_HOST/auth"
  info "Database:   $DB_HOST:$DB_PORT/$DB_NAME $([[ "$BUNDLED_DB" == true ]] && echo '(bundled PostgreSQL 17)' || echo '(external)')"
  info "Apps:       ${SELECTED_APPS[*]:-<none>}"
  info "Tenant:     ${MASTER_LICENSE_FILE:+from $MASTER_LICENSE_FILE ($TENANT_ORGANIZATION)}${MASTER_LICENSE_FILE:-<none - set MASTER_LICENSE_FILE, or ./install.sh create-tenant later>}"
  [[ -z "$MASTER_LICENSE_FILE" ]] || read_license
  confirm "Proceed?" || die "Aborted"

  if [[ "$DRY_RUN" != true ]]; then
    oc get namespace "$NAMESPACE" >/dev/null 2>&1 || { oc create namespace "$NAMESPACE" >/dev/null; ok "namespace $NAMESPACE created"; }
    ensure_all_secrets
  fi
  write_global_values

  section "1/5 PostgreSQL 17"
  if [[ "$BUNDLED_DB" == true ]]; then
    helm_up postgres "$ROOT/charts/ol-postgres" --set-string "image=$IMAGE_POSTGRES" \
      --set-string "storage.storageClass=$STORAGE_CLASS"
  else
    info "external database $DB_HOST - skipped"
  fi
  [[ "$DRY_RUN" == true ]] || db_prepare

  section "2/5 Keycloak"
  helm_up keycloak "$ROOT/charts/ol-keycloak" --set-string "image=$IMAGE_KEYCLOAK"

  section "3/5 OpenLegacy Hub (embedded gateway)"
  # migration hook first (schemas + tenant); apps already Ready stay switched on, new ones in step 5
  local hub_args=()
  mapfile -t hub_args < <(DRY_RUN=false hub_apps_args 2>/dev/null || true)
  helm_up hub "$ROOT/charts/ol-hub" --set-string "image=$IMAGE_HUB" --set-string "imagePullPolicy=$IMAGE_PULL_POLICY" "${hub_args[@]}"
  if [[ "$DRY_RUN" != true ]]; then
    seed_tenant     # before any app: OL-Integration seeds its admin for every ACTIVE tenant at boot
    keycloak_sync   # user profile, hub-spa redirect URIs (incl. the app routes about to be created), admin user
  fi

  section "4/5 Optional apps"
  local a
  for a in "${SELECTED_APPS[@]}"; do install_app "$a"; done
  [[ ${#SELECTED_APPS[@]} -gt 0 ]] || info "none selected"

  section "5/5 Hub: switch the apps on"
  hub_switch
  [[ "$DRY_RUN" == true ]] || activate_license   # needs the admin role to resolve (RBAC hub, or legacy via OL-Integration)

  [[ "$DRY_RUN" == true ]] && { ok "dry run complete - manifests in $GEN"; return 0; }
  summary
}

summary() {
  section "Done"
  printf '  Hub (sign in here):  https://%s\n' "$HUB_HOST"
  printf '  Keycloak admin:      https://%s/auth/admin   (user/password: secret ol-keycloak-admin)\n' "$KEYCLOAK_HOST"
  printf '  Hub user:            %s   (password: oc -n %s get secret ol-hub-admin-user -o jsonpath={.data.password} | base64 -d)\n' \
    "$(secret_value ol-hub-admin-user username)" "$NAMESPACE"
  read_tenant
  [[ -n "$TENANT_ID" ]] || warn "No ACTIVE tenant - ./install.sh create-tenant"
  local a; for a in "${!APP_HOST[@]}"; do in_list "$a" "${SELECTED_APPS[@]}" && printf '  %-20s https://%s\n' "$a:" "${APP_HOST[$a]}"; done
  printf '\n  Check: ./install.sh status\n'
}

# Add apps to an existing install: secrets, the apps (+ dependencies), redirect URIs, Hub switches.
# Postgres / Keycloak / the Hub are not reinstalled.
do_add() {
  (( ${#CMD_ARGS[@]} )) || die "usage: ./install.sh add <app> [<app>...]   (available: ${APP_ORDER[*]})"
  preflight
  APPS_OVERRIDE="${CMD_ARGS[*]}" NO_PROMPT_APPS=true load_config
  helm -n "$NAMESPACE" status hub >/dev/null 2>&1 || die "No Hub in $NAMESPACE - run ./install.sh first"
  derive_hosts
  local new=() a
  for a in "${SELECTED_APPS[@]}"; do in_list "$a" "${INSTALLED_APPS[@]}" || new+=("$a"); done
  (( ${#new[@]} )) || { info "already installed: ${CMD_ARGS[*]}"; [[ "$DRY_RUN" == true ]] || return 0; }
  section "Add"
  info "New:        ${new[*]:-<none>}"
  info "Installed:  ${INSTALLED_APPS[*]:-<none>}"
  confirm "Proceed?" || die "Aborted"
  [[ "$DRY_RUN" == true ]] || ensure_all_secrets      # creates only the new apps' secrets
  write_global_values
  [[ "$DRY_RUN" == true ]] || keycloak_sync          # redirect URIs for new app routes
  section "Apps"
  for a in "${new[@]}"; do install_app "$a"; done
  section "Hub: switch the apps on"
  hub_switch
  [[ "$DRY_RUN" == true ]] || summary
}

# Remove apps: switch them off in the Hub first (a switch with no backend breaks the shell), then uninstall.
# The app's PVC and secrets are kept (re-adding it reuses them); --purge deletes them as well.
do_remove() {
  (( ${#CMD_ARGS[@]} )) || die "usage: ./install.sh remove <app> [<app>...]"
  preflight
  APPS_OVERRIDE="" NO_PROMPT_APPS=true load_config
  derive_hosts
  local a d keep=() i
  for i in "${!CMD_ARGS[@]}"; do CMD_ARGS[i]=$(canonical_app "${CMD_ARGS[$i]}"); done
  for a in "${CMD_ARGS[@]}"; do in_list "$a" "${INSTALLED_APPS[@]}" || die "'$a' is not installed in $NAMESPACE"; done
  for a in "${INSTALLED_APPS[@]}"; do in_list "$a" "${CMD_ARGS[@]}" || keep+=("$a"); done
  for a in "${keep[@]}"; do
    for d in ${APP_DEPS[$a]:-}; do
      in_list "$d" "${CMD_ARGS[@]}" && die "'$a' needs '$d' - remove '$a' too, or keep '$d'"
    done
  done
  section "Remove"
  info "Removing:   ${CMD_ARGS[*]}"
  info "Keeping:    ${keep[*]:-<none>}"
  confirm "Proceed?" || die "Aborted"
  SELECTED_APPS=("${keep[@]}")
  write_global_values
  section "Hub: switch the apps off"
  hub_switch
  [[ "$DRY_RUN" == true ]] && return 0
  for a in "${CMD_ARGS[@]}"; do
    local rel; rel=$(app_release "$a")
    helm -n "$NAMESPACE" uninstall "$rel" >/dev/null && ok "uninstalled $a${rel:+ (release $rel)}"
    if [[ "$PURGE" == true ]]; then
      local pvcs; mapfile -t pvcs < <(printf "%s-data\n" "$a" "$(app_obj "$a")" | sort -u)
      oc -n "$NAMESPACE" delete pvc "${pvcs[@]}" --ignore-not-found >/dev/null
      oc -n "$NAMESPACE" delete secret "$(app_obj "$a")-secrets" --ignore-not-found >/dev/null
      ok "$a: PVC and secrets deleted"
    fi
  done
  info "hub-spa redirect URIs of removed apps are kept (harmless); edit them in the Keycloak console if needed"
}

do_status() {
  NO_PROMPT_APPS=true load_config; derive_hosts
  section "Releases"; helm -n "$NAMESPACE" list
  section "Pods"; oc -n "$NAMESPACE" get pods -o wide
  section "Hub /config"
  curl -sk "https://$HUB_HOST/config" | jq -c . 2>/dev/null || warn "https://$HUB_HOST/config not reachable"
  section "Remotes through the gateway"
  local p
  for p in /health /remotes/termiq/remoteEntry.json /remotes/dataiq/remoteEntry.json /remotes/appiq/remoteEntry.json \
           /remotes/ol-next/remoteEntry.json /remotes/olspec/remoteEntry.json /remotes/olcode/remoteEntry.json \
           /remotes/ol-coreiq/remoteEntry.json /remotes/ol-atomiq/remoteEntry.json; do
    printf '  %-40s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code} %{content_type}' "https://$HUB_HOST$p")"
  done
}

do_uninstall() {
  NO_PROMPT_APPS=true load_config
  local what=""; [[ "$PURGE" == true ]] && what=" (purge: PVCs + secrets too)"
  confirm "Uninstall every OpenLegacy release from ${NAMESPACE}${what}?" || die "Aborted"
  local r
  for r in $(helm -n "$NAMESPACE" list -q); do helm -n "$NAMESPACE" uninstall "$r" >/dev/null && ok "uninstalled $r"; done
  if [[ "$PURGE" == true ]]; then
    oc -n "$NAMESPACE" delete pvc --all
    oc -n "$NAMESPACE" delete secret -l app.kubernetes.io/part-of=ol-hub
    oc -n "$NAMESPACE" delete secret ol-code-secrets ol-terminal-secrets coreiq-secrets atomiq-secrets dataiq-secrets dataiq-batch-secrets --ignore-not-found
  else
    info "PVCs and secrets kept (re-install reuses them; --purge removes them)"
  fi
}

case $CMD in
  install)       do_install ;;
  add)           do_add ;;
  remove)        do_remove ;;
  status)        do_status ;;
  sync-keycloak) load_config; derive_hosts; keycloak_sync ;;
  create-tenant) NO_PROMPT_APPS=true load_config; derive_hosts
                 create_tenant ;;
  set-secret)    (( ${#CMD_ARGS[@]} == 2 )) || die "usage: ./install.sh set-secret <app> KEY=VALUE"
                 APPS=${APPS:-}; load_config; set_app_secret "${CMD_ARGS[0]}" "${CMD_ARGS[1]}" ;;
  uninstall)     do_uninstall ;;
esac
