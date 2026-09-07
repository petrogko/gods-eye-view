# Deploying God's Eye View

The app is one long-running Node process (`vite preview` carrying the full
`/api` proxy layer) with an in-memory/disk cache and a persistent outbound
websocket to AISStream. That is a container shape, and `Dockerfile` at the
repo root builds it: Caddy owns the public port with HTTP basic auth, Node
listens on loopback inside the container only.

**The server is a key broker.** Anyone who can reach it can spend whatever
keys it holds. Never run it on a public URL without the auth layer in front.

## AWS App Runner (Terraform)

One container, one HTTPS URL, no VPC/ALB/Cognito. About **$5–15/month** at
one always-on instance (it holds the AIS socket, so it does not scale to zero),
plus **~$8–9/month for WAF** if `enable_waf` stays on.

### Guardrails that ship with it

| Guardrail | What it does | Knob |
|---|---|---|
| **Budget alert** | Emails you at 80% of the monthly ceiling spent and when the forecast crosses 100%. Account-wide. **Warns only** — AWS cannot hard-stop spend. | `alert_email`, `monthly_budget_usd` (default 20) |
| **WAF** | Blocks any IP over 2,000 requests / 5 min, Amazon's IP-reputation list, and known-bad-inputs payloads. The Common Rule Set is deliberately left out: it would block legitimate Overpass QL bodies. | `enable_waf`, `waf_rate_limit_per_5min` |
| **App throttles** | Per-IP caps on the OpenAI and Google endpoints, live from day one so they are already enforced when a key is added. | `ratelimit_openai_per_min` (30), `ratelimit_google_per_min` (120) |
| **1/1 instance** | Cannot autoscale into a surprise bill. | `cpu`, `memory` |
| **Request-spike alarm** | Emails when the service sees more than N requests in 5 min — a scraper or flood. Counts 401s too. AWS sends a one-time SNS confirmation link; click it. | `request_spike_threshold` (3000), `alert_email` |
| **Crawler refusal** | `robots.txt` says `Disallow: /` to everyone; every response carries `X-Robots-Tag: noindex, nofollow, noarchive, noai, noimageai`; known AI crawler user-agents get `403` before the auth prompt. None of this is the real barrier — basic auth is — it just tells honest bots not to try. | `deploy/container/Caddyfile` |
| **Access log** | Caddy logs every request as JSON to stdout → CloudWatch, so failed logins and probing bots are visible. | — |

`/healthz` is the only path reachable without a password, and it fetches a
5 KB icon — never the app document.

### One-time

```sh
brew install awscli hashicorp/tap/terraform     # once per machine
aws configure                                   # or SSO — needs rights for ECR, App Runner, IAM, SSM
open -a Docker                                  # buildx needs the daemon

cd deploy/aws
cp terraform.tfvars.example terraform.tfvars    # gitignored; holds your secrets
docker run --rm caddy:2 caddy hash-password --plaintext 'choose-a-password'
#   → paste the $2a$... hash into basic_auth_hash
```

### Deploy

App Runner refuses to create a service until an image exists, so the first
run is three steps; every later deploy is just `./build-and-push.sh`.

```sh
terraform init
terraform apply -target=aws_ecr_repository.app   # registry only
./build-and-push.sh                              # cross-builds linux/amd64, pushes :latest
terraform apply                                  # everything else; prints service_url
```

Open `service_url`, enter the basic-auth credentials. On Android, Chrome →
menu → **Add to Home screen** gives it an icon and a full-screen window.

### Keys

| Key | Where | Why |
|---|---|---|
| `OPENAI_API_KEY`, `AISSTREAM_API_KEY`, `OPENSKY_*`, `FIRMS_MAP_KEY`, `TOMTOM_API_KEY`, `LL2_API_TOKEN` | `provider_secrets` in `terraform.tfvars` → SSM SecureString → runtime env | Never enters the image; rotated with `terraform apply` |
| `GOOGLE_MAPS_API_KEY`, `CESIUM_ION_TOKEN` | env vars when running `build-and-push.sh` → build args | Client-side by design; Vite inlines them into the bundle. **Restrict both at the provider to the `service_url` hostname** and set a Google Cloud budget cap |

The in-app Provider Settings panel is off on a hosted instance by design (it
answers loopback only), so keys are managed exclusively through Terraform.

### Before you add the first provider key — do these, in this order

The day a key lands, the basic-auth password becomes the only thing between
an attacker and your money. The app throttles and WAF above are guards, not
billing caps. Set the caps where the money actually is:

1. **OpenAI** — platform.openai.com → Settings → Limits → set a monthly
   budget and a hard limit. Use a project-scoped key, not your account key.
2. **Google Cloud** — Billing → Budgets & alerts → create a budget; APIs &
   Services → Credentials → the key → restrict by **HTTP referrer** to your
   `service_url` hostname *and* by **API** to only the ones the app uses.
   Set per-API quotas under APIs & Services → Quotas.
3. **Cesium ion** — use a token scoped to `assets:read` with URL restrictions.
4. **OpenSky / AISStream / FIRMS / TomTom / LL2** — free tiers; nothing to cap,
   but rotate any key that ever appears in a log or chat.
5. Then add the key under `provider_secrets` in `terraform.tfvars`, run
   `terraform apply`, and confirm the service redeployed.

**Rotate the site password** any time it may have been seen: generate a new
hash with `caddy hash-password`, update `basic_auth_hash`, `terraform apply`.

### Operate

```sh
./build-and-push.sh              # redeploy after a code change
terraform apply                  # after changing any variable or secret
terraform destroy                # tear it all down, images included
```

The disk cache (`.gev-cache/`) is ephemeral on App Runner; it refills on
demand. Logs: App Runner console → the service → Logs.

## Running the container anywhere else

```sh
docker build -t gods-eye-view .
docker run --rm -p 8080:8080 \
  -e BASIC_AUTH_USER=me \
  -e BASIC_AUTH_HASH='$2a$14$...' \
  -e OPENAI_API_KEY=... \
  gods-eye-view
```

Any host that runs a container works (Fly.io, a VPS with Docker). Put it
behind Tailscale if you want no public URL at all.
