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
one always-on instance (it holds the AIS socket, so it does not scale to zero).

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
