variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name used for the App Runner service, ECR repository, IAM roles, and the SSM parameter prefix."
  type        = string
  default     = "gods-eye-view"
}

variable "image_tag" {
  description = "ECR image tag App Runner deploys. With auto-deploy on, pushing this tag again rolls the service."
  type        = string
  default     = "latest"
}

variable "basic_auth_user" {
  description = "Username Caddy requires in front of the app."
  type        = string
}

variable "basic_auth_hash" {
  description = "bcrypt hash of the password. Generate: docker run --rm caddy:2 caddy hash-password --plaintext 'your-password'"
  type        = string
  sensitive   = true
}

variable "provider_secrets" {
  description = <<-EOT
    Server-side provider keys, by the env var name the app reads
    (OPENAI_API_KEY, AISSTREAM_API_KEY, OPENSKY_CLIENT_ID, OPENSKY_CLIENT_SECRET,
    FIRMS_MAP_KEY, TOMTOM_API_KEY, LL2_API_TOKEN, GEV_RATELIMIT_*). Each becomes
    an SSM SecureString injected at runtime. Never the two client-side keys —
    those are image build args.
  EOT
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "cpu" {
  description = "App Runner vCPU units. 1024 = 1 vCPU."
  type        = string
  default     = "1024"
}

variable "memory" {
  description = "App Runner memory in MB. Cesium-sized JSON packs and the AIS cache want headroom."
  type        = string
  default     = "2048"
}
