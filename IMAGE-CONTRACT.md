# On-prem image contract — what the OpenShift installer needs from each image

For whoever updates a repo's CI pipeline to publish the image the installer
(`/Users/serge/env/Openlegacy/8/ol-openshift-installer/`) deploys. Each section says what the image must
provide, what the installer relies on, and what is known to be wrong today. Verified against the running
install in namespace `ol-hub` on cluster07 and the `ol-hub` / `ol-integration` source (`origin/release/4.0.0`)
on 2026-10-19/21.

Read with: `README.md` (how the installer works), `images.conf` (the image of every component),
`apps/<app>.yaml` (env, port, probe, volumes per app), `charts/ol-hub/values.yaml` (Hub env and per-app switches).

## 1. Rules for every image

**Registry and naming**
- Publish to `public.ecr.aws/openlegacy/hub/<repo>:<tag>` — the installer pulls from there with no pull secret.
- One line per image in `images.conf` (`IMAGE_<NAME>=...`, e.g. `IMAGE_OL_COREIQ`). A new version = a new line there; nothing else in
  the installer changes unless the image's contract (port, env, paths) changes.
- **Do not re-push an existing tag with different content.** It happened for `coreiq:1.7.4-onprem`,
  `atomiq:1.5.3-onprem` and `ol-terminal:2.0.7.4-onprem`: nodes kept the cached old build, and the runbook
  hashes stopped matching what the tag served. That is why `IMAGE_PULL_POLICY=Always` is the default. Wanted:
  immutable tags (`<version>-onprem.<build>`) or a published digest per release, so `images.conf` can pin
  `repo@sha256:...`.
- Publish the **image index digest** in the release notes (what `docker buildx imagetools inspect <ref>`
  prints as `Digest:`) — that is the value `images.conf` pins. The tarball sha256 and the config digest are
  different numbers; runbooks have mixed them up.
- `linux/amd64` is enough (the clusters are amd64). A multi-arch index is fine too.

**Runtime**
- Runs as a non-root user. On the test cluster pods run as UID 1000 (custom SCC); under OpenShift's default
  `restricted-v2` SCC they run with an **arbitrary UID in group 0**. Everything the app writes at runtime must be
  either a path the installer mounts (listed per app below) or group-0 writable in the image
  (`chgrp -R 0 <dir> && chmod -R g=u <dir>`). Several images ship `HOME` dirs owned by 1000 with mode 755 — they
  only work because the installer mounts volumes over them.
- One HTTP port, a **health path that answers 200 without a token** (the installer's startup/readiness/liveness
  probe), and no other process needed in the pod.
- Database: the shared Postgres; credentials arrive as `OL_DB_TYPE/HOST/PORT/NAME/USER/PASSWORD` (secret
  `ol-db`, envFrom). An image that defaults to H2 (`OL_DB_TYPE=h2`) must switch on `OL_DB_TYPE=postgres`.
- Hub sign-in through Keycloak realm `ol-hub` (client `hub-spa`): JWKS from the in-cluster
  `https://hub-enterprise-keycloak/auth` (self-signed → trust-all), browser login at the Keycloak route.
  Apps that compare the token issuer get `KEYCLOAK_ISSUER=https://<keycloak-route>/auth/realms/ol-hub`.
- Tenant from the token claim `https://ol.tenants/tenantId`. Default tenant `4a6bfc5d-3bae-45a3-99b9-d1e255875adb`,
  admin = Keycloak user `ol-hub` id `9a780e8b-ba98-4f0c-8424-4e4cc27b1f67` (fixed ids — see §3).
- Licence: checked per request against the tenant's MASTER licence in the Hub backoffice
  (`<hub>/backoffice/api/v1/tenants/<id>/license`) with the caller's token. **No `OL_HUB_API_KEY`, no
  `OL_TOOL_LICENSE`** at startup — an image that needs either to boot does not fit the installer.
- Federation remote: `/remoteEntry.json` served by the app; the Hub shell loads it as
  `/remotes/<name>/remoteEntry.json` through the Hub's embedded gateway (prefix stripped), so the remote's
  own API calls must be relative to the remote's path (the "prefix-aware embed" / `*-embedded-fix` builds).

**Verifying a new image against the installer**
```sh
# in the installer folder, with oc logged in to a test cluster
IMAGE_<APP>=<new ref> ./install.sh --dry-run          # renders; checks env/probes/volumes
IMAGE_<APP>=<new ref> ./install.sh add <app>          # installs/upgrades just that app (+ deps)
./install.sh status                                    # pods, Hub /config, every /remotes/*/remoteEntry.json
```
Then call one authenticated API of the app as user `ol-hub` (token from the `hub-spa` password grant; password
in secret `ol-hub-admin-user`) and expect JSON 200 — not 401/403/503, not the SPA's HTML fallback — and open the
app from the Hub shell in a browser.

## 2. Mandatory components

| Component | Image today | Port / probe | Needs |
|---|---|---|---|
| PostgreSQL | `public.ecr.aws/docker/library/postgres:17` | 5432 / `pg_isready` | upstream image, nothing to build |
| Keycloak | `openlegacy/openlegacy-keycloak:26.8.0` (Docker Hub) | 8080 http + 8443 https / `GET /auth/realms/ol-hub` | the `ol` login theme, `KC_HTTP_RELATIVE_PATH=/auth`, TLS keystore on 8443 (in-cluster `https://hub-enterprise-keycloak` → 443 → 8443). Not on public.ecr.aws: mirror it there to avoid Docker Hub limits |
| Hub | `public.ecr.aws/openlegacy/hub/ol-hub:4.0.0-onprem` | 8080 (nginx) / `GET /health` | see below |

**Hub (`ol-hub` repo, `release/4.0.0`, `services/ol-hub-enterprise`)**
- One image, two modes: `/entrypoint.sh migrate` (the installer runs it as a pre-install/pre-upgrade Job; must
  exit 0 when the schemas are current) and the default (Hub JVM).
- Embedded gateway: `OL_HUB_EMBEDDED_GATEWAY=true` runs nginx on 8080 in front of the JVM on 8081. `/health` must
  answer 200 only once the JVM is up. App routes are switched on by `<APP>_HOST`/`<APP>_PORT`; the installer sets
  them for ol-termiq, ol-dataiq, ol-appiq, ol-next, ol-spec, ol-code, ol-coreiq, ol-atomiq and OL-Integration
  (`charts/ol-hub/values.yaml` → `integrations`). OL Terminal has no route (absolute `OL_TERMINAL_URL`).
- Service ports: 8080, plus 9095/9096/9097 (auth-service, flags-router, notifications internal ports — OL-Integration
  calls them).
- Secrets it reads (generated once by the installer, shared with OL-Integration): `OL_HUB_ENCRYPT_SECRET`,
  `OL_HUB_PK_API_KEY_SIGN` (`{base64}` + base64 of a PKCS#8 RSA-2048 PEM; the Hub decodes base64url —
  `JwtApiKeyProvider.kt`), `OL_INTERNAL_SERVICE_SECRET` (+ `_ENFORCED=true`), `KEYCLOAK_MANAGEMENT_CLIENT_SECRET`
  (= realm client `hub-client`).
- RBAC: `OL_RBAC_READ_SOURCE`/`WRITE_SOURCE` = `hub` without OL-Integration, `legacy` with it (the Hub refuses to
  boot attached unless `legacy` + enforced internal secret — `HubOnlyBoot.kt`).
- Licence activation route used by the installer: `PUT /backoffice/api/v1/tenants/<id>/license`
  `{"license":"<JWT>"}`, admin only (`HubOnlyRouter.kt`). Keep it.
- `/config` must advertise every `*_URL` switch the installer sets (`OL_TERMIQ_URL`, `DATAIQ_URL`, `APPIQ_URL`,
  `OL_NEXT_URL`, `OL_SPEC_URL`, `OL_CODE_URL`, `OL_TERMINAL_URL`, `COREIQ_URL`, `ATOMIQ_URL`). The `release/4.0.0`
  `HubOnlyConfig.kt` reads only four of them; the published embedded-gateway image reads all — build from the
  branch that does.
- Gateway catalog: one `/opt/gateway/catalog/apps/ol-<app>.conf` per app (appiq, atomiq, code, coreiq, dataiq,
  integration, next, spec, termiq). Each upstream placeholder (`coreiq:8090`, `atomiq:8091`, …) must be the one
  `docker-entrypoint-gateway.sh` substitutes with `<APP>_HOST:<APP>_PORT`. **Fixed** in `4.0.0-onprem`
  `sha256:5afa55802025…` (2026-10-21): it has `/remotes/ol-atomiq/` + `/atomiq/` and `/remotes/ol-coreiq/` +
  `/coreiq/`, and CoreIQ's placeholder now matches (an earlier `4.0.0-onprem`, `bcf03b836239`, had neither route,
  so AtomIQ opened standalone and redirected to the in-cluster Keycloak host). Keep every app conf in the image.
- Does **not** create a tenant or a master licence (the installer seeds the tenant row, then activates the licence
  through the route above) — unchanged behaviour is fine.

## 3. OL-Integration (`ol-integration` repo, `release/4.0.0`, image `hub-enterprise`, consumer mode)

| | |
|---|---|
| Image the installer expects | `public.ecr.aws/openlegacy/hub/ol-integration:4.0.0` — **not published yet**; today it exists only in the cluster's internal registry (`ol-integration-enterprise:4.0.0-6f50229ff6`) |
| Mode | consumer: `LAUNCHER_CLASS=io.ol.hub.enterprise.consumer.ConsumerLauncherKt`, `MAIN_CLASS=io.ol.hub.enterprise.consumer.ConsumerMainVerticle` (`services/hub-enterprise/entrypoint.sh`). The consumer code exists only on `release/4.0.0` (commits #6099, #6100), **not on `develop`** |
| Ports / probe | 8080 http, 9095 internal (the Hub's backoffice calls it to seed tenant admins) / `GET /health` |
| Env | `apps/ol-integration.yaml` — matches `ops/onprem/docker-compose.consumer.yml` + `consumer.env.example`; the three Hub secrets must equal the Hub's |
| At boot | migrates its schemas, then for **every ACTIVE tenant** creates `data_<tenant>` (incl. demo project `demo-account-details`) and seeds admin `9a780e8b-...` if the tenant has none (`SetDefaultUserRoleCallback`). Needs `operational.tenant` to exist (the Hub migrated) |

- **Gap for the installer (not the image):** it writes tenant artifacts under `user.home` — `/home/ubuntu/ol-hub-tenant-artifacts`
  and `/home/ubuntu/.ol` (compose and its Helm chart mount volumes there). `apps/ol-integration.yaml` has no volume
  yet, so they are lost on restart. If the image changes these paths, say so.
- Wanted from the pipeline: publish the consumer-mode image to public.ecr.aws under the name above, built from
  `release/4.0.0` (or wherever the consumer launcher lands next).

## 4. Optional apps

Columns: what the installer configures (`apps/<app>.yaml`). "Volumes" = paths the installer mounts (PVC unless
noted); anything else the app writes must be group-0 writable in the image.

| App (`images.conf`) | Image today | Port / probe | Remote / route | Volumes | Source of today's image | Status |
|---|---|---|---|---|---|---|
| ol-termiq (`IMAGE_OL_TERMIQ`) | `ol-termiq:1.0.5-onprem` | 8094 / `/health` | `/remotes/termiq`, `/termiq-backend` | – | `ol-termiq` `release/1.0.5` (`e238254`), `yarn build:he:prod` | works |
| ol-dataiq (`IMAGE_OL_DATAIQ`) | `dataiq:1.6.7` | 9092 / `/health` | `/remotes/dataiq`, `/dataiq-backend` | `/usr/app/.dataiq` (encryption key, operator JDBC jars), `/tmp` | dataiq `release/1.6.7` | token accepted; full check in browser pending |
| ol-dataiq-batch (`IMAGE_OL_DATAIQ_BATCH`) | `dataiq-batch:1.6.7` | 8089 / `/actuator/health` | own Route (DataIQ's "View job" link) | `/tmp` | dataiq `release/1.6.7` tag `1.6.7.b640` | works (health) |
| ol-appiq (`IMAGE_OL_APPIQ`) | `appiq:1.3.7-onprem-embedded-fix` | 8095 / `/health` | `/remotes/appiq`, `/appiq` | – | appiq `release/1.3.7` (`25313fb9`) + embedded fix | token accepted; full check in browser pending |
| ol-next (`IMAGE_OL_NEXT`) | `ol-next:1.7.0-onprem` | 8080 / `/api` | `/remotes/ol-next`, `/ol-next-backend` | emptyDir `/data` (`OL_DATA_DIR`), `/usr/app/.cache`, `/tmp` | ol-next `release/1.7.0`, pnpm | token accepted; full check in browser pending |
| ol-spec (`IMAGE_OL_SPEC`) | `olspec:1.1.8-onprem-embedded-fix2` | 3008 / `/health` | `/remotes/olspec`, `/olspec-backend` (unbuffered, 900s) | `/usr/app/.olspec` (master.key), `/usr/app/.cache`, `/tmp` | olspec `release/1.1.8` + PR #32 + embedded fixes | works |
| ol-code (`IMAGE_OL_CODE`) | `ol-code:3.0.41-onprem` | 9091 / `/health` | `/remotes/olcode` + own Route | `/usr/app` (user.home), `/tmp` | olcode `develop` `a18f44f7` (`v3.0.41-21`) | **broken** — see below |
| ol-terminal (`IMAGE_OL_TERMINAL`) | `ol-terminal:2.0.7.4-onprem` | 9093 / `/health` | mounted from its own Route (`OL_TERMINAL_URL`) | `/usr/app/.ol-terminal/traffic`, `/usr/app/data`, emptyDir `/usr/app/.ol-terminal/logs`, `/tmp` | ol-terminal `feature/hub-license-per-request` `a76a2be` (PR #94) | token accepted; full check in browser pending |
| ol-coreiq (`IMAGE_OL_COREIQ`) | `coreiq:1.7.4-onprem` | 8090 / `/health` (`/api/health` needs a token) | `/remotes/ol-coreiq` | `/tmp` | coreiq `feature/CRIQ-71-onprem` `eea14a43` (PR #157) | works |
| ol-atomiq (`IMAGE_OL_ATOMIQ`) | `atomiq:1.5.3-onprem` | 8091 / `/health` | `/remotes/ol-atomiq` | `/tmp` | atomiq `feature/ATMIQ-10-onprem` `d233a9ea` (PR #68) | works |

Per-app notes for the pipelines:
- **ol-code — fix before the next release.** `3.0.41-onprem` validates the token, then every request needing the
  tenant database fails with HTTP 500 "Tenant database bootstrap failed":
  `java.lang.NoSuchMethodError: kotlinx.coroutines.BuildersKt.runBlockingK$default(...)` at
  `io.ol.common.database.vertx.TenantDatabaseRouting.executeTenantSqlClientBootstrap` (`TenantDatabaseRouting.kt:87`).
  A dependency mismatch: `ol-common-core` compiled against a newer `kotlinx-coroutines` than the jar ships. Align
  the coroutines version (or the `ol-common-core` version) in the build and add a smoke test that opens a tenant
  connection. The image also ignores `JAVA_OPTS` (the installer uses `JAVA_TOOL_OPTIONS`).
- **Feature branches:** ol-terminal, coreiq and atomiq images come from unmerged feature branches/PRs; ol-spec needs
  PR #32 on top of its release branch. The pipelines should build these from release branches once merged.
- **Images defaulting to H2:** ol-next and atomiq (`OL_DB_TYPE=h2` in the image) — fine, the installer sets
  `postgres`; ol-next additionally needs `OL_DB_URL` (JDBC) for postgres.
- **Generated keys on start:** coreiq's entrypoint generates a random `CREDENTIAL_ENCRYPTION_KEY` when unset (stored
  credentials then stop decrypting after a restart). The installer always sets it; an image should rather refuse to
  start without it.
- **AtomIQ 1.5.3:** the app switcher shows six apps until rebuilt with the enterprise-edition fix (atomiq #69).
- **Debug logging:** ol-terminal's `logback.xml` defaults to DEBUG (installer sets `OL_APP_LOG_LEVEL=INFO`); make INFO
  the default in the on-prem build.

## 5. What a pipeline run should produce (checklist)

1. Build from the branch named above (or its successor); record the commit in the image labels
   (`org.opencontainers.image.revision`, `.version`).
2. Image `public.ecr.aws/openlegacy/hub/<repo>:<version>-onprem[.<build>]`, amd64, non-root, writable paths as above.
3. Smoke test in CI: start against Postgres 17 (+ a Keycloak with realm `ol-hub` or a static JWKS), expect the health
   path 200 without a token, `/remoteEntry.json` 200 (remotes), an API call 401 without a token and 200 with a
   `hub-spa`-shaped token carrying the tenant claim; for apps with tenant schemas, one request that opens the tenant
   database (would have caught the ol-code crash).
4. Release note with: image ref, **index digest**, tarball sha256 (if a tarball is shipped for air-gapped installs),
   source commit, and any change to port / health path / env names / writable paths — those need an
   `apps/<app>.yaml` change in the installer.
5. Bump the line in `images.conf`.
