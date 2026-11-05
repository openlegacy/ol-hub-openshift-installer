# OpenLegacy Hub on OpenShift — installer

One command installs the OpenLegacy Hub and any of its apps into an OpenShift namespace with Helm.
Everything that can be derived from the cluster or generated is. The only inputs you have to give are a
namespace, the apps you want and the master-licence key.

| Always installed | |
|---|---|
| PostgreSQL 17 | `hub-enterprise-postgres:5432`, one database shared by everything (one schema per app) |
| Keycloak 26.8 | `hub-enterprise-keycloak`, realm `ol-hub` (clients `hub-spa`, `hub-client`) |
| OpenLegacy Hub 4.0.0 | `ol-hub`, with the embedded multi-app gateway (one pod: nginx 8080 → Hub JVM) |

Optional apps: `ol-integration`, `ol-termiq`, `ol-dataiq` (+ `ol-dataiq-batch`), `ol-appiq`, `ol-next`,
`ol-spec`, `ol-code`, `ol-terminal`, `ol-coreiq`, `ol-atomiq`.

Contents: [Requirements](#requirements) · [How to install](#how-to-install) · [Day-2 operations](#day-2-operations) ·
[Configuration](#configuration) · [Apps](#apps) · [What the installer does](#what-the-installer-does) ·
[Keycloak](#keycloak-realm-ol-hub-and-the-hub-spa-redirect-uris) · [Tenant and licence](#tenant-and-master-licence) ·
[Secrets](#secrets) · [Troubleshooting](#troubleshooting)

---

## Requirements

### Workstation (where `install.sh` runs)

| | Requirement |
|---|---|
| OS | Linux or macOS (on Windows: WSL 2) |
| Shell | **bash 4+**. On macOS the system bash is 3.2: run `brew install bash` |
| Tools | `oc` (OpenShift CLI, matching the cluster's minor version ±1), **`helm` 3.8+** (tested with 4.3), `jq` 1.6+, `openssl`, `curl`, `base64` |
| Network | the cluster API (`oc login`), and **HTTPS to the Hub and Keycloak Routes**: the installer signs in as the admin user and activates the licence through the Hub's public URL |
| Disk | a few MB (`generated/` holds the rendered values and manifests) |
| Files | the master-licence key from OpenLegacy, saved as a file (for example `master-license.jwt`) |

The installer checks the tools, the Helm version, the cluster login and that the cluster is OpenShift
before it changes anything.

### Cluster

| | Requirement |
|---|---|
| Platform | OpenShift 4.x (tested on 4.22), with the default ingress controller. Routes use edge TLS on the cluster's wildcard certificate |
| Permissions | a user who can create a project (or is admin of an existing one) and create Deployments, Services, Routes, Secrets, ConfigMaps, PVCs and Jobs in it. No cluster-admin rights and no special SCC: every pod runs under the default `restricted-v2` SCC with an arbitrary UID |
| Storage | a default StorageClass (or `STORAGE_CLASS`) with **ReadWriteOnce** volumes and dynamic provisioning |
| Images | pull access to `public.ecr.aws/openlegacy/hub/*`, `public.ecr.aws/docker/library/postgres` and `docker.io/openlegacy/openlegacy-keycloak`. In a disconnected cluster, mirror them and set the `IMAGE_*` lines (and `IMAGE_PULL_SECRET` for a private registry) |
| DNS | the apps domain (`*.apps.<cluster>`) must resolve for the users' browsers and for the workstation |
| Database | the bundled PostgreSQL 17, or an external PostgreSQL 17 (`DB_HOST`, `DB_PASSWORD`) with a database the user owns (the installer creates its schemas) |

### Hardware sizing

These figures are what the charts **request** from the scheduler (guaranteed) and the memory **limit** each pod
may grow to. No CPU limits are set, because the JVMs need short CPU bursts at start-up. The "idle" column was
measured on a working install with all apps (cluster07, namespace `ol-hub`, 2026-10-21).

| Footprint | CPU request | Memory request | Memory limit | Persistent storage | Idle memory (measured) |
|---|---|---|---|---|---|
| Core only (PostgreSQL + Keycloak + Hub) | 0.55 vCPU | 2.3 GiB | 6.5 GiB | 20 GiB | 1.3 GiB |
| Core + all 11 apps | 1.8 vCPU | 10 GiB | 28 GiB | 40 GiB (5 PVCs) | 5.4 GiB |

Recommended free capacity on the worker nodes:

| Install | vCPU | Memory | Storage |
|---|---|---|---|
| Core only (evaluation) | 2 | 8 GiB | 20 GiB |
| Core + a few apps | 4 | 16 GiB | 30 GiB |
| Core + all apps | 4–6 | 32 GiB | 40 GiB |

With all apps the largest single pod limit is 3 GiB (Hub, OL-Integration), so any worker with ≥ 4 GiB free can
run any pod. The reference cluster has 4 workers × 3.5 vCPU / 15 GiB allocatable. The database grows with
use. A fresh install needs under 100 MB, and the 20 GiB volume is the starting size, not an estimate.

### Per component

| Component | Image (default tag) | Needs | CPU req | Memory req / limit | Storage | Idle memory | Own Route |
|---|---|---|---|---|---|---|---|
| PostgreSQL | `postgres:17` | – | 100m | 512 Mi / 2 Gi | 20 Gi PVC | 150 Mi | – |
| Keycloak | `openlegacy-keycloak:26.8.0` | PostgreSQL | 200m | 768 Mi / 1.5 Gi | – (in PostgreSQL) | 800 Mi | yes |
| Hub + gateway | `ol-hub:4.0.0-*` | PostgreSQL, Keycloak | 250m | 1 Gi / 3 Gi | – | 320 Mi | yes |
| ol-integration | `ol-integration:4.0.0` | – | 250m | 1 Gi / 3 Gi | – | 440 Mi | – |
| ol-termiq | `ol-termiq:1.0.5-onprem` | ol-integration | 100m | 768 Mi / 2 Gi | – | 310 Mi | – |
| ol-dataiq | `dataiq:1.6.7` | ol-integration, ol-dataiq-batch | 100m | 1 Gi / 2 Gi | 5 Gi PVC | 460 Mi | – |
| ol-dataiq-batch | `dataiq-batch:1.6.7` | – | 100m | 512 Mi / 1.5 Gi | – | 260 Mi | yes |
| ol-appiq | `appiq:1.3.7-onprem-embedded-fix` | ol-integration | 100m | 768 Mi / 2 Gi | – | 390 Mi | – |
| ol-next | `ol-next:1.7.0-onprem` | – | 100m | 768 Mi / 1.5 Gi | – (emptyDir) | 320 Mi | – |
| ol-spec | `olspec:1.1.8-onprem-embedded-fix2` | – | 100m | 768 Mi / 2 Gi | 5 Gi PVC | 390 Mi | – |
| ol-code | `ol-code:3.0.41-onprem` | – | 100m | 768 Mi / 2 Gi | 5 Gi PVC | 280 Mi | yes |
| ol-terminal | `ol-terminal:2.0.7.4-onprem` | – | 100m | 512 Mi / 2 Gi | 5 Gi PVC | 370 Mi | yes |
| ol-coreiq | `coreiq:1.7.4-onprem` | – | 100m | 512 Mi / 1.5 Gi | – | 600 Mi | – |
| ol-atomiq | `atomiq:1.5.3-onprem` | – | 100m | 512 Mi / 1.5 Gi | – | 360 Mi | – |

Every app stores its data in the shared PostgreSQL database, and a PVC holds only local files (keys, uploads,
workspaces). The installer adds dependencies automatically. During install and upgrade a short-lived Job runs
the Hub image in `migrate` mode with the Hub's resources.
To change an app's sizing, edit `resources:` in `apps/<app>.yaml` and re-run.

---

## How to install

### 1. Get the files ready

```sh
cd ol-openshift-installer
cp install.conf.example install.conf
cp /path/to/your-licence.jwt master-license.jwt && chmod 600 master-license.jwt   # git-ignored
```

### 2. Edit `install.conf`

The minimum is:

```sh
NAMESPACE=ol-hub                                   # created if missing
APPS="ol-integration ol-termiq ol-next"            # or "" to be asked per app
MASTER_LICENSE_FILE=./master-license.jwt
TENANT_ORGANIZATION="My Company"
```

Everything else has a default, listed under [Configuration](#configuration). The image tags come from `images.conf`.

### 3. Log in and preview

```sh
oc login https://api.<cluster>:6443
./install.sh --dry-run          # renders every manifest into generated/, changes nothing
```

### 4. Install

```sh
./install.sh                    # interactive: shows the cluster and the plan, asks before it starts
./install.sh -c install.conf -y # non-interactive (CI)
```

The installer runs these steps in order. A first run takes about 10–20 minutes, mostly pulling the images.

| Step | What happens |
|---|---|
| Secrets | generated once (database, Keycloak admin, Hub keys, admin user, per-app keys) |
| PostgreSQL | started, schema `keycloak` created |
| Keycloak | realm `ol-hub` imported |
| Hub | schema migration Job, then the Hub |
| Tenant | the ACTIVE tenant row, the admin user `ol-hub` and its role |
| Apps | one Helm release per app, each waited for until Ready |
| Hub switch | each Ready app is switched on in the Hub shell |
| Licence | `MASTER_LICENSE_FILE` activated through the Hub |

### 5. Sign in

The installer prints the URLs at the end:

| What | URL | Credentials |
|---|---|---|
| Hub (sign in here) | `https://ol-hub-<ns>.<apps-domain>` | user `ol-hub`, password in secret `ol-hub-admin-user` |
| Keycloak admin console | `https://keycloak-<ns>.<apps-domain>/auth/admin` | secret `ol-keycloak-admin` |
| OL Code / OL Terminal / DataIQ batch | `https://<app>-<ns>.<apps-domain>` | their own Routes |

```sh
oc -n <ns> get secret ol-hub-admin-user -o jsonpath='{.data.password}' | base64 -d; echo
```

The admin user `ol-hub` has the email `HUB_ADMIN_EMAIL` (default `admin@openlegacy.com`).

### 6. Check

```sh
./install.sh status             # releases, pods, Hub /config, every app remote through the gateway (expect 200)
```

---

## Day-2 operations

```sh
./install.sh status                         # health of everything
./install.sh add ol-spec ol-coreiq          # add apps (+ dependencies); Postgres/Keycloak/Hub are not reinstalled
./install.sh remove ol-coreiq               # Hub switch off first, then uninstall; PVC + secrets are kept
./install.sh remove ol-coreiq --purge       # ...and delete its PVC + secrets
./install.sh                                # re-run: upgrade images, repair drift (idempotent)
./install.sh create-tenant                  # tenant row + admin user, then activate MASTER_LICENSE_FILE
./install.sh sync-keycloak                  # redirect URIs, user profile, admin user (tenant link, email)
./install.sh set-secret <app> KEY=VALUE     # set one key of the app's secret, then restart the app
./install.sh uninstall                      # releases only; PVCs and secrets kept (re-install reuses them)
./install.sh uninstall --purge              # also deletes PVCs (the database!) and secrets
```

Common options: `-c <file>` config file (default `install.conf`), `-y` no questions, `--dry-run` render only,
`--purge` with `remove` / `uninstall`. `HELM_TIMEOUT=30m ./install.sh` for slow nodes (default 15m per release).

- **Upgrade an app:** change its line in `images.conf` (or override it in `install.conf`), then re-run `./install.sh`.
- **Re-runs are safe.** Apps already installed always stay installed and switched on, whatever `APPS` says
  (use `remove` to take one out). `remove` refuses to remove an app another installed app needs.
- **Back up** the PostgreSQL volume (or `pg_dump`) **together with the secrets**. The encryption keys in them
  are needed to read the data.

---

## Configuration

`install.conf` (template: `install.conf.example`). Everything except `NAMESPACE` and `APPS` is optional:

| Variable | Default |
|---|---|
| `NAMESPACE` | asked (`ol-hub`); created if missing |
| `APPS` | asked per app |
| `APPS_DOMAIN` | the cluster's `ingresses.config.openshift.io/cluster` domain |
| `HUB_HOST`, `KEYCLOAK_HOST` | `ol-hub-<ns>.<domain>`, `keycloak-<ns>.<domain>` |
| `STORAGE_CLASS` | cluster default |
| `MASTER_LICENSE_FILE` | none: the master-licence key (JWT) from OpenLegacy |
| `TENANT_ORGANIZATION`, `TENANT_CONTACT`, `TENANT_ID` | `OpenLegacy`, `ol-hub`, `4a6bfc5d-3bae-45a3-99b9-d1e255875adb` |
| `HUB_ADMIN_EMAIL` | `admin@openlegacy.com`: email of the Keycloak admin user `ol-hub` (set again on every `sync-keycloak`; empty = none) |
| `EXTRA_REDIRECT_URIS` | none |
| `DB_HOST` … `DB_PASSWORD` | bundled PostgreSQL; set `DB_HOST` + `DB_PASSWORD` for an external one |
| `IMAGE_PULL_SECRET` | none |
| `IMAGE_*` | `images.conf` |

**Images:** `images.conf` has one line per component (current tags on public.ecr.aws). Override any of them
in `install.conf`, including by digest (`IMAGE_OL_COREIQ=public.ecr.aws/openlegacy/hub/coreiq@sha256:…`).
`IMAGE_PULL_POLICY=Always` by default, because tags are re-pushed under the same name.

**Old names:** `termiq`, `dataiq`, `dataiq-batch`, `appiq`, `coreiq`, `atomiq` and the old `IMAGE_TERMIQ`-style
variables are still accepted. Deployments, pods and Routes are named after the app (`ol-coreiq-…`).
Services keep their old names (`coreiq`, `olspec`, `dataiq-service`…) because the Hub gateway and the
other apps address them. Secrets keep their old names too (`coreiq-secrets`…). An install made before the
rename keeps its Helm release names and its PVCs (`dataiq-data`, `olspec-data`). The next `./install.sh`
scales the old Deployment down and replaces it with the `ol-` one.

---

## Apps

| App | Service → port | Probe | In the Hub shell | Own Route |
|---|---|---|---|---|
| ol-integration | `ol-integration` 80 → 8080, 9095 | `/health` | `/backend`, designer remote | – |
| ol-termiq | `ol-termiq` 80 → 8094 | `/health` | `/remotes/termiq` | – |
| ol-dataiq | `dataiq-service` 80 → 9092 | `/health` | `/remotes/dataiq` | – |
| ol-dataiq-batch | `dataiq-batch` 80 → 8089 | `/actuator/health` | – | yes ("View job" link) |
| ol-appiq | `appiq` 80 → 8095 | `/health` | `/remotes/appiq` | – |
| ol-next | `ol-next` 80/8080 → 8080 | `/api` | `/remotes/ol-next` | – |
| ol-spec | `olspec` 80 → 3008 | `/health` | `/remotes/olspec` | – |
| ol-code | `ol-code` 80 → 9091 | `/health` | `/remotes/olcode` | yes (standalone SPA) |
| ol-terminal | `ol-terminal` 80 → 9093 | `/health` | loaded from its own Route | yes |
| ol-coreiq | `coreiq` 80 → 8090 | `/health` | `/remotes/ol-coreiq` | – |
| ol-atomiq | `atomiq` 80 → 8091 | `/health` | `/remotes/ol-atomiq` | – |

Dependencies: `ol-termiq`, `ol-dataiq` and `ol-appiq` need `ol-integration`, and `ol-dataiq` needs
`ol-dataiq-batch`. With `ol-integration` installed, RBAC comes from OL-Integration (`legacy` mode), and
without it from the Hub (`hub` mode).

Env, volumes and secrets per app are in `apps/<app>.yaml` (comments name the runbook each value comes from).
To add an app, add one values file, one line in `images.conf` and its catalog entry in `lib/common.sh`
(and its Hub switch in `charts/ol-hub/values.yaml` → `integrations`).

---

## What the installer does

1. **Secrets:** created once, never overwritten (a re-run only adds missing keys; see [Secrets](#secrets)).
2. **PostgreSQL 17** (skipped with an external `DB_HOST`), then **schema `keycloak`** (`CREATE SCHEMA IF NOT
   EXISTS`). Keycloak starts before the Hub and keeps its tables there (`KC_DB_SCHEMA=keycloak`).
3. **Keycloak:** imports realm `ol-hub` on first start from `charts/ol-keycloak/files/realm-ol-hub.json`.
4. **Hub:** a pre-install/pre-upgrade Job runs the image's `migrate` mode (Hub schemas), then the Hub starts.
   Readiness is `GET /health` on 8080.
5. **Tenant row**, then **realm sync** (both below): admin user `ol-hub` with its tenant role. The redirect URIs
   include the app routes.
6. **Apps:** one Helm release per app from the universal chart `charts/ol-app` + `apps/<app>.yaml`. They start
   after the tenant exists, so the apps that migrate a schema per ACTIVE tenant at start do it right away.
7. **Hub again**, with each app switched on (`<APP>_URL` + `<APP>_HOST/PORT`). An app is switched on only once
   it is Ready, because a Hub switch without a live route can stop the whole shell from loading.
8. **Master licence** activated through the Hub (`MASTER_LICENSE_FILE`, below).

## Keycloak: realm `ol-hub` and the `hub-spa` redirect URIs

The realm template is the realm a working install runs, stripped of everything install-specific: no signing
keys (each install generates its own), no client secrets, no users, no IDs. It carries a user profile with
unmanaged attributes enabled. Two values are Keycloak placeholders, resolved from the pod env at import time,
so the ConfigMap stores no secret:

- `hub-client` secret = `${KEYCLOAK_MANAGEMENT_CLIENT_SECRET}` (secret `ol-hub-secrets`; the Hub uses the same
  value to manage users)
- `hub-spa` first redirect URI = `${HUB_SPA_REDIRECT_URI}` (`https://<hub host>/*`)

The import happens only once (an existing realm is never overwritten). On **every** run `install.sh` then
syncs the realm with `kcadm` inside the Keycloak pod (`./install.sh sync-keycloak` does just this step):

| Setting | Value |
|---|---|
| `hub-spa` → Valid redirect URIs | `https://<hub host>/*`, plus `https://<route>/*` of every installed app with its own Route (`ol-code`, `ol-terminal`, `ol-dataiq-batch`), plus `EXTRA_REDIRECT_URIS`. Existing URIs are kept (union). |
| `hub-spa` → Web origins | `+` (= every redirect URI's origin) |
| User profile → Unmanaged attributes | `Enabled`. Otherwise Keycloak silently drops `ol-tenantId`, `ol-company` and `ol-fullname` |
| User `ol-hub` (id `9a780e8b-ba98-4f0c-8424-4e4cc27b1f67`) | **The built-in admin.** The Hub (`auth.tenant_user_role`) and OL-Integration (`data_<tenant>.user_role`) seed exactly this id as admin of the default tenant, so the user must have it. It is created by Keycloak partial import, the only admin API that keeps an id. Email `HUB_ADMIN_EMAIL`. `ol-tenantId` = the tenant and `ol-company` = its organization; the `hub-spa` mappers copy them into every token (`https://ol.tenants/tenantId`). The admin role rows are ensured as well. Password: secret `ol-hub-admin-user`. |

To do the same by hand in the admin console, open realm `ol-hub` → Clients → `hub-spa` → Settings. Under
*Valid redirect URIs*, add `https://<host>/*` for the Hub route and every app route a browser opens. Set *Web origins* to `+`.

How login works: the browser signs in at the Keycloak route, so tokens carry
`iss = https://<keycloak host>/auth/realms/ol-hub`. The apps that compare the issuer (OL-Next, OL-Spec) get exactly
that value as `KEYCLOAK_ISSUER`. Every app fetches the signing keys in-cluster from `https://hub-enterprise-keycloak/auth`
(self-signed, trust-all).

## Tenant and master licence

The installer does this the same way as the official on-prem bundle (`ol-hub/ops/onprem/install.sh`) and the Hub:

1. **Tenant: always, no input needed.** A fresh Hub creates no tenant and has no route to create one. So,
   right after the Hub migration, the installer inserts the ACTIVE `operational.tenant` row by SQL, with id
   `4a6bfc5d-3bae-45a3-99b9-d1e255875adb`, the built-in tenant. At boot, OL-Integration seeds that tenant's
   admin (Keycloak user `ol-hub`, id `9a780e8b-…`) in `data_<tenant>` for every ACTIVE tenant, which is why the
   row must exist before any app starts. The realm sync then creates user `ol-hub` and its admin role.
2. **Master licence: activated through the Hub**, as the last step (after the apps, once the admin role
   resolves). The installer calls `PUT /backoffice/api/v1/tenants/<id>/license {"license": "<JWT>"}` as `ol-hub`,
   the same call as the shell's licence screen. The Hub verifies the OpenLegacy signature, refuses expired and
   non-MASTER licences, and stores the licence itself, with the expiry truncated to the day as every app's licence check expects.

| Input | Setting | Notes |
|---|---|---|
| Master-licence key | `MASTER_LICENSE_FILE` | A JWT signed by OpenLegacy (RS256, `licenseType: MASTER`), saved to a file. Without it the tenant exists but is unlicensed: activate it in the Hub UI, or set the file and run `./install.sh create-tenant` |
| Organization | `TENANT_ORGANIZATION` | default `OpenLegacy`; also the `company` claim in the admin's token |
| Contact person | `TENANT_CONTACT` | default `ol-hub` |
| Tenant id | `TENANT_ID` | Default `4a6bfc5d-3bae-45a3-99b9-d1e255875adb` (keep it). The licence's own `tenantId` does not have to match, because the Hub ties tenant and licence by licence id |

- Re-running is safe. One licence belongs to one tenant: a licence already stored for another tenant is refused.
- Licence rows written by earlier installer versions (expiry not day-truncated) are replaced by the Hub's own.
- Keep the licence file out of git; `.gitignore` covers `*.jwt`.

## Secrets

All secrets are in the install namespace, generated by `install.sh`. Their values are never printed:

| Secret | Keys | Used by |
|---|---|---|
| `ol-db` | `OL_DB_TYPE` `OL_DB_HOST` `OL_DB_PORT` `OL_DB_NAME` `OL_DB_USER` `OL_DB_PASSWORD` | Postgres, Keycloak, the Hub and every app (`envFrom`; ol-dataiq-batch maps them to its own names) |
| `ol-hub-secrets` | `OL_HUB_ENCRYPT_SECRET` `OL_HUB_PK_API_KEY_SIGN` `OL_INTERNAL_SERVICE_SECRET` `KEYCLOAK_MANAGEMENT_CLIENT_SECRET` | Hub, OL-Integration, Keycloak (`hub-client`) |
| `ol-keycloak-admin` | `username` `password` | Keycloak master admin |
| `ol-hub-admin-user` | `username` (`ol-hub`) `password` | the built-in admin `ol-hub` |
| `<app>-secrets` | per app: encryption keys, admin passwords, `api-key` (dataiq-batch) | ol-code, ol-terminal, ol-coreiq, ol-atomiq, ol-dataiq, ol-dataiq-batch |

The encryption keys (`OL_HUB_ENCRYPT_SECRET`, `SETTINGS_ENCRYPTION_KEY`, `CREDENTIAL_ENCRYPTION_KEY`,
`db-encryption-secret`) protect data stored in the database. Back them up with the database and never rotate them in place.
To set one key afterwards (this restarts the app), run `./install.sh set-secret <app> KEY=VALUE`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bash 4+ is required` | bash 3 (macOS default): `brew install bash`, then run `install.sh` with the new bash |
| `helm 3.8+ is required` / `Not an OpenShift cluster` | update Helm; `oc login` to the OpenShift cluster, not a plain Kubernetes context |
| Licence activation fails with HTTP `000` | the workstation cannot reach the Hub/Keycloak Route over HTTPS (proxy, VPN, DNS). Fix access and run `./install.sh create-tenant` |
| Pod `Pending` | not enough free CPU/memory on any worker (see [Hardware sizing](#hardware-sizing)) or no default StorageClass: `oc -n <ns> describe pod <pod>` |
| `ImagePullBackOff` | the image is not reachable from the cluster: mirror it, set `IMAGE_*` / `IMAGE_PULL_SECRET` |
| App answers 401 with a valid session | Issuer or JWKS: check the app's `KEYCLOAK_*` against the Keycloak section; `./install.sh sync-keycloak` |
| App answers 403 "Tenant not found or inactive" / licence not valid | No tenant (set `MASTER_LICENSE_FILE`, `./install.sh create-tenant`), the user is not linked to it (`./install.sh sync-keycloak`), or the licence is past expiry + grace |
| Hub / OL-Integration show a licence pop-up; Hub log `Could not resolve the tenant role for user=…` (503) | The signed-in user has no admin role in the tenant: sign in as `ol-hub` (the built-in admin), keep `TENANT_ID` at the default, `./install.sh sync-keycloak` |
| `licence … is already stored for tenant …` | That licence was used for another tenant. Set `TENANT_ID` to the id shown to re-run for that tenant. A new tenant needs its own licence |
| Login redirect error "Invalid parameter: redirect_uri" | The page's origin is not in `hub-spa`: add it to `EXTRA_REDIRECT_URIS`, `./install.sh sync-keycloak` |
| `/remotes/<app>/` 404 | App not switched on in the Hub (it was not Ready): re-run once it is |
| `/remotes/<app>/` 502 | The app's pod is down: `oc -n <ns> logs deploy/<app>` |
| A release times out | `oc -n <ns> get events --sort-by=.lastTimestamp`; then re-run (idempotent). `HELM_TIMEOUT=30m ./install.sh` for slow nodes |


## Layout

```
install.sh            entry point (install | add | remove | status | create-tenant | sync-keycloak | set-secret | uninstall)
install.conf.example  user configuration template
images.conf           image per component
lib/                  common.sh (config, app catalog), secrets.sh, db.sh, keycloak.sh, tenant.sh
charts/ol-postgres    PostgreSQL 17
charts/ol-keycloak    Keycloak + realm ol-hub template (files/realm-ol-hub.json)
charts/ol-hub         Hub + embedded gateway + migration hook; per-app Hub switches ("integrations")
charts/ol-app         universal chart for every optional app
apps/<app>.yaml       one values file per app
IMAGE-CONTRACT.md     what each image must provide (for the build pipelines)
```

