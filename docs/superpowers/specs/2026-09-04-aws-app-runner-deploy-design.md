# AWS App Runner deployment — design

**Date:** 2026-09-04 · **Status:** approved, implemented on `deploy/aws-app-runner`

## Goal

Run God's Eye View on a private-to-me HTTPS URL reachable from a phone, with
the smallest AWS footprint that is still Terraform-managed, without exposing
the operator's LAN and without weakening the repo's security model (secrets
stay server-side; the server is a key broker and must sit behind auth).

## Shape of the workload

One long-running Node process · disk/memory cache with 7–30 day TTLs · a
persistent outbound websocket to AISStream · secrets in env vars · no
database · ~29 MB static bundle. This is a **container**, not a serverless
function; splitting the 7,800-line proxy layer into functions was rejected as
re-architecture for no gain at this scale.

## Decisions

| Decision | Rejected alternative | Reason |
|---|---|---|
| App Runner | ECS/Fargate + ALB + VPC | Container in, URL out; no networking to own. |
| Caddy basic-auth **inside the image** | Cognito, ALB-OIDC, Cloudflare Access | Zero extra services or DNS; credentials are runtime secrets. |
| Image via ECR | App Runner GitHub-connect | Fully Terraform-native; no console click. |
| `vite preview` as the production server | Dev server in a container | Requires preview-hook parity (done); yields a bundled, non-HMR app. |
| One always-on instance, max 1 | Autoscaling | Holds the AIS socket; caps spend. |
| Ephemeral cache | EFS | It is a cache. |

## Components

- **`Dockerfile`** — build stage (`npm ci`, `vite build` with the two
  public keys as build args; prunes puppeteer/sharp), runtime stage
  (`node:24-slim` + Caddy binary, non-root, `HEALTHCHECK` on `/healthz`).
- **`deploy/container/Caddyfile`** — `:8080`, security headers, gzip,
  `/healthz` unauthenticated → proxied to the app, everything else behind
  `basic_auth` from `BASIC_AUTH_USER` / `BASIC_AUTH_HASH`.
- **`deploy/container/entrypoint.sh`** — starts `vite preview` on loopback,
  runs Caddy as PID 1, stops the container if Node exits.
- **`deploy/aws/*.tf`** — ECR (+ lifecycle), SSM SecureString per secret,
  two IAM roles (ECR pull; SSM+KMS read), autoscaling config 1/1, App
  Runner service with `/healthz` HTTP probe and auto-deploy on push.
- **`deploy/aws/build-and-push.sh`** — `buildx --platform linux/amd64`
  (App Runner is x86_64; the host is Apple Silicon), pushes `:latest`.

## Repo changes required

- **Preview parity** (`vite.config.js`): `withPreviewParity()` gives the ten
  dev-only proxies the same hook on preview. Applied per plugin —
  `keySetupEndpoint` (`server.restart()`) and `vite-plugin-cesium` are
  deliberately excluded. `preview.{host,port,allowedHosts,headers}` mirror
  `server`. Pinned by `src/previewParity.test.mjs`.

## Secrets

Server keys → `terraform.tfvars` (gitignored) → SSM → runtime env. The two
client-side keys are build args, restricted at the provider by referrer.
Provider Settings is inert on the hosted instance (loopback-only gate).

## Not automated

`terraform apply` is run by the operator after reading `terraform plan`.

## Verification

Unit suite green, `terraform validate` clean, image builds, and a local
`vite preview` answers the previously-missing `/api/*` routes.
