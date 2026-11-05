#!/usr/bin/env bash
# Shared helpers: logging, prompts, configuration, the app catalog.

C_RESET=$'\033[0m'; C_BLUE=$'\033[1;36m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[0;31m'
[[ -t 1 ]] || { C_RESET=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; }

log()     { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
info()    { log "${C_BLUE}INFO${C_RESET}  $*"; }
ok()      { log "${C_GREEN}OK${C_RESET}    $*"; }
warn()    { log "${C_YELLOW}WARN${C_RESET}  $*" >&2; }
die()     { log "${C_RED}ERROR${C_RESET} $*" >&2; exit 1; }
section() { printf '\n%s== %s ==%s\n' "$C_BLUE" "$*" "$C_RESET"; }

interactive() { [[ -t 0 && -t 1 && "${ASSUME_YES:-false}" != true ]]; }

ask() {   # ask VAR "question" "default"
  local __var=$1 __q=$2 __def=${3:-} __ans
  if interactive; then
    read -r -e -p "$__q${__def:+ [$__def]}: " __ans || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
  else
    printf -v "$__var" '%s' "$__def"
  fi
}

confirm() {   # confirm "question" -> 0 on yes
  [[ "${ASSUME_YES:-false}" == true ]] && return 0
  interactive || return 0
  local a; read -r -p "$1 [y/N]: " a || true
  [[ "${a,,}" == y || "${a,,}" == yes ]]
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# ---- app catalog ---------------------------------------------------------------------------------
# App names (what APPS, add and remove take; also the Helm release names) all carry the ol- prefix.
# Install order matters: ol-integration before the apps that call /backend, ol-dataiq-batch before ol-dataiq.
# The Hub and OL-Integration ship a built-in default tenant and its admin: their migrations seed
# auth.tenant_user_role and data_<tenant>.user_role with (tenant 4a6bfc5d..., Keycloak user 9a780e8b..., admin).
# Only the operational.tenant row + master licence are left to create (create_tenant), and the realm user
# with exactly that id (keycloak_sync). Same as a-one.
DEFAULT_TENANT_ID=4a6bfc5d-3bae-45a3-99b9-d1e255875adb
HUB_ADMIN_ID=9a780e8b-ba98-4f0c-8424-4e4cc27b1f67
HUB_ADMIN_USER=ol-hub

APP_ORDER=(ol-integration ol-dataiq-batch ol-termiq ol-dataiq ol-appiq ol-next ol-spec ol-code ol-terminal ol-coreiq ol-atomiq)

# Deployment, pod label and Route are named after the app (= values "name:" in apps/<app>.yaml).
# Apps whose objects had another name before the ol- prefix: the Service ("serviceName:" - the gateway and
# other apps address it), <name>-secrets and the <name>-data PVC of an existing install keep that name.
declare -A APP_OLD_NAME=(
  [ol-dataiq]=dataiq [ol-dataiq-batch]=dataiq-batch [ol-appiq]=appiq [ol-spec]=olspec
  [ol-coreiq]=coreiq [ol-atomiq]=atomiq
)
declare -A APP_DEPS=(
  [ol-termiq]="ol-integration" [ol-dataiq]="ol-integration ol-dataiq-batch" [ol-appiq]="ol-integration"
)
# Names used before the ol- prefix (still accepted in APPS / add / remove / IMAGE_*; an install whose Helm
# release has the old name keeps that release - Helm cannot rename one, and a second release would collide)
declare -A APP_ALIAS=(
  [ol-termiq]=termiq [ol-dataiq]=dataiq [ol-dataiq-batch]=dataiq-batch [ol-appiq]=appiq
  [ol-coreiq]=coreiq [ol-atomiq]=atomiq
)
declare -A APP_FROM_ALIAS=()
for __a in "${!APP_ALIAS[@]}"; do APP_FROM_ALIAS[${APP_ALIAS[$__a]}]=$__a; done; unset __a
# Apps with their own public Route (standalone page / browser link) - hub-spa must allow them
APPS_WITH_ROUTE=(ol-code ol-terminal ol-dataiq-batch)
# Apps the Hub switches on in its shell/gateway (ol-hub chart "apps.<name>")
APPS_IN_HUB=(ol-integration ol-termiq ol-dataiq ol-appiq ol-next ol-spec ol-code ol-terminal ol-coreiq ol-atomiq)

app_obj() { echo "${APP_OLD_NAME[$1]:-$1}"; }   # prefix of the app's Service / secret names

canonical_app() { local a=$1; echo "${APP_FROM_ALIAS[$a]:-$a}"; }   # termiq -> ol-termiq

# Apps already installed in NAMESPACE (Helm releases under the new or the old name) -> stdout, install order
installed_apps() {
  [[ -n "${NAMESPACE:-}" ]] || return 0
  local rels a; rels=$(helm -n "$NAMESPACE" list -q 2>/dev/null || true)
  for a in "${APP_ORDER[@]}"; do
    if grep -qx -- "$a" <<<"$rels" || { [[ -n "${APP_ALIAS[$a]:-}" ]] && grep -qx -- "${APP_ALIAS[$a]}" <<<"$rels"; }; then echo "$a"; fi
  done
  return 0
}

# Helm release of an app: its existing release (new or old name), else the new name
app_release() {
  local a=$1 rels; rels=$(helm -n "$NAMESPACE" list -q 2>/dev/null || true)
  if [[ -n "${APP_ALIAS[$a]:-}" ]] && ! grep -qx -- "$a" <<<"$rels" && grep -qx -- "${APP_ALIAS[$a]}" <<<"$rels"; then
    echo "${APP_ALIAS[$a]}"
  else
    echo "$a"
  fi
}

image_var() { local v=${1^^}; echo "IMAGE_${v//-/_}"; }   # ol-atomiq -> IMAGE_OL_ATOMIQ
# Image of an app: IMAGE_OL_<APP>, or the pre-prefix IMAGE_<APP> (e.g. an older install.conf override wins
# only if it is the one set there)
app_image() {
  local a=$1 v old; v=$(image_var "$a")
  if [[ -n "${APP_ALIAS[$a]:-}" ]]; then old=$(image_var "${APP_ALIAS[$a]}"); [[ -n "${!old:-}" ]] && { echo "${!old}"; return; }; fi
  echo "${!v:-}"
}
in_list()   { local x=$1; shift; local i; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }

# Resolve the APPS selection: validate names, add dependencies, sort into install order -> SELECTED_APPS
resolve_apps() {
  local want=() a d changed=true
  for a in $APPS; do
    if [[ -n "${APP_FROM_ALIAS[$a]:-}" ]]; then info "'$a' is now '${APP_FROM_ALIAS[$a]}'"; a=${APP_FROM_ALIAS[$a]}; fi
    in_list "$a" "${APP_ORDER[@]}" || die "Unknown app '$a'. Available: ${APP_ORDER[*]}"
    in_list "$a" "${want[@]}" || want+=("$a")
  done
  while $changed; do
    changed=false
    for a in "${want[@]}"; do
      for d in ${APP_DEPS[$a]:-}; do
        if ! in_list "$d" "${want[@]}"; then want+=("$d"); changed=true; info "Adding '$d' (required by '$a')"; fi
      done
    done
  done
  SELECTED_APPS=()
  for a in "${APP_ORDER[@]}"; do in_list "$a" "${want[@]}" && SELECTED_APPS+=("$a"); done
  return 0
}

# ---- configuration -------------------------------------------------------------------------------
load_config() {
  # shellcheck source=/dev/null
  source "$ROOT/images.conf"
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"; info "Config: $CONF_FILE"
  else
    info "No $CONF_FILE - using defaults and prompts (template: install.conf.example)"
  fi
  : "${NAMESPACE:=}" "${APPS:=__unset__}" "${APPS_DOMAIN:=}" "${HUB_HOST:=}" "${KEYCLOAK_HOST:=}"
  : "${STORAGE_CLASS:=}" "${EXTRA_REDIRECT_URIS:=}" "${IMAGE_PULL_SECRET:=}"
  : "${DB_HOST:=}" "${DB_PORT:=5432}" "${DB_NAME:=postgres}" "${DB_USER:=postgres}" "${DB_PASSWORD:=}"
  : "${IMAGE_PULL_POLICY:=Always}"
  : "${MASTER_LICENSE_FILE:=}" "${TENANT_ORGANIZATION:=OpenLegacy}" "${TENANT_CONTACT:=}" "${TENANT_ID:=}" "${HUB_ADMIN_EMAIL=admin@openlegacy.com}"
  CONF_TENANT_ID=$TENANT_ID   # read_tenant() overwrites TENANT_ID with what it finds in the database
  if [[ -n "$MASTER_LICENSE_FILE" ]]; then
    [[ "$MASTER_LICENSE_FILE" == /* ]] || MASTER_LICENSE_FILE="$(cd "$(dirname "$CONF_FILE")" 2>/dev/null && pwd)/$MASTER_LICENSE_FILE"
    [[ -f "$MASTER_LICENSE_FILE" ]] || die "MASTER_LICENSE_FILE '$MASTER_LICENSE_FILE' not found"
  fi
  [[ "$TENANT_ORGANIZATION$TENANT_CONTACT" != *'$'* ]] || die "TENANT_ORGANIZATION / TENANT_CONTACT must not contain '\$'"
  # add/remove pass their own app list; it wins over APPS from install.conf
  [[ -n "${APPS_OVERRIDE+x}" ]] && APPS=$APPS_OVERRIDE

  [[ -n "$NAMESPACE" ]] || ask NAMESPACE "Namespace" "ol-hub"
  [[ -n "$NAMESPACE" ]] || die "NAMESPACE is required"
  # Apps already installed always stay selected: a re-run never switches an installed app off in the Hub
  # (use ./install.sh remove <app> for that)
  mapfile -t INSTALLED_APPS < <(installed_apps)
  if [[ "$APPS" == "__unset__" ]]; then
    APPS=""
    if interactive && [[ "${NO_PROMPT_APPS:-false}" != true ]]; then
      section "Optional apps"
      local a ans
      for a in "${APP_ORDER[@]}"; do
        if in_list "$a" "${INSTALLED_APPS[@]}"; then printf '  %-15s installed\n' "$a"; continue; fi
        read -r -p "  install $a? [y/N]: " ans || true
        [[ "${ans,,}" == y* ]] && APPS+=" $a"
      done
    fi
  fi
  APPS="$APPS ${INSTALLED_APPS[*]}"
  resolve_apps

  BUNDLED_DB=true; [[ -n "$DB_HOST" ]] && BUNDLED_DB=false
  [[ "$BUNDLED_DB" == true ]] && DB_HOST=hub-enterprise-postgres
  [[ "$BUNDLED_DB" == false && -z "$DB_PASSWORD" ]] && die "DB_PASSWORD is required with an external DB_HOST"
  return 0
}

derive_hosts() {
  if [[ -z "$APPS_DOMAIN" ]]; then
    APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    [[ -n "$APPS_DOMAIN" ]] || die "Cannot read the cluster apps domain - set APPS_DOMAIN in install.conf"
  fi
  : "${HUB_HOST:=ol-hub-${NAMESPACE}.${APPS_DOMAIN}}"
  : "${KEYCLOAK_HOST:=keycloak-${NAMESPACE}.${APPS_DOMAIN}}"
  declare -gA APP_HOST=()
  local a
  for a in "${APPS_WITH_ROUTE[@]}"; do APP_HOST[$a]="${a}-${NAMESPACE}.${APPS_DOMAIN}"; done
}
