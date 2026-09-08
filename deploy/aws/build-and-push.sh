#!/usr/bin/env bash
# Build the production image for App Runner (linux/amd64 — App Runner is x86_64,
# so an Apple Silicon host MUST cross-build) and push it to the ECR repository
# Terraform created. Re-pushing the same tag rolls the service automatically.
#
# The two client-side keys are BUILD args (Vite inlines them). Pass them in the
# environment, or leave unset for a keyless build:
#   GOOGLE_MAPS_API_KEY=... CESIUM_ION_TOKEN=... ./build-and-push.sh
set -euo pipefail
cd "$(dirname "$0")"

# ecr_repository_url is written even by a targeted `apply -target=...app`; the
# standalone `region` output is not, so derive region from the repo URL
# (<account>.dkr.ecr.<region>.amazonaws.com/<repo>) rather than a second output.
REPO="$(terraform output -raw ecr_repository_url)"
TAG="${IMAGE_TAG:-latest}"
REGISTRY="${REPO%%/*}"
REGION="$(printf '%s' "$REGISTRY" | awk -F. '{print $4}')"

echo "→ logging in to ${REGISTRY}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "→ building ${REPO}:${TAG} for linux/amd64"
docker buildx build \
  --platform linux/amd64 \
  --build-arg GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}" \
  --build-arg CESIUM_ION_TOKEN="${CESIUM_ION_TOKEN:-}" \
  --tag "${REPO}:${TAG}" \
  --push \
  ../..

echo "✓ pushed ${REPO}:${TAG}"
