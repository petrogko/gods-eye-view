# God's Eye View on AWS App Runner.
#
# One container, one HTTPS URL, no VPC/ALB/Cognito. The image (see the repo
# Dockerfile) runs Caddy with basic auth in front of `vite preview`; App Runner
# terminates TLS and probes /healthz. Every server-side secret is an SSM
# SecureString injected at runtime — nothing sensitive is in the image.
#
# First apply needs an image in ECR before the service can be created:
#   terraform apply -target=aws_ecr_repository.app
#   ./build-and-push.sh
#   terraform apply

locals {
  name = var.app_name

  # Every runtime secret under one SSM prefix; App Runner reads them by ARN.
  secrets = merge(var.provider_secrets, {
    BASIC_AUTH_USER = var.basic_auth_user
    BASIC_AUTH_HASH = var.basic_auth_hash
  })
}

data "aws_caller_identity" "current" {}

# SecureString parameters use the account's AWS-managed SSM key by default;
# the instance role must be allowed to decrypt with it.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# ---------- image registry ----------

resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "MUTABLE" # `latest` is re-pushed on every deploy
  force_delete         = true      # `terraform destroy` removes images too

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---------- secrets ----------

resource "aws_ssm_parameter" "secret" {
  # for_each keys are env-var NAMES (BASIC_AUTH_HASH, OPENAI_API_KEY, ...), not
  # secret — but the merged map's values are, and Terraform taints keys derived
  # from a sensitive map. nonsensitive() asserts the names are safe to expose as
  # instance keys; the value below stays sensitive.
  for_each = toset(nonsensitive(keys(local.secrets)))

  name  = "/${local.name}/${each.key}"
  type  = "SecureString"
  value = local.secrets[each.key]
  tier  = "Standard"
}

# ---------- IAM: pull the image ----------

data "aws_iam_policy_document" "access_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["build.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "access" {
  name               = "${local.name}-apprunner-access"
  assume_role_policy = data.aws_iam_policy_document.access_trust.json
}

resource "aws_iam_role_policy_attachment" "access_ecr" {
  role       = aws_iam_role.access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# ---------- IAM: read the secrets at runtime ----------

data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-apprunner-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
}

data "aws_iam_policy_document" "instance_secrets" {
  statement {
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [for p in aws_ssm_parameter.secret : p.arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }
}

resource "aws_iam_role_policy" "instance_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_secrets.json
}

# ---------- App Runner ----------

# Exactly one instance: the process holds the AISStream websocket and the
# in-memory caches, and one is all a personal instance needs. Also caps spend.
resource "aws_apprunner_auto_scaling_configuration_version" "app" {
  auto_scaling_configuration_name = local.name
  min_size                        = 1
  max_size                        = 1
}

resource "aws_apprunner_service" "app" {
  service_name = local.name

  source_configuration {
    # Re-pushing the configured tag rolls the service; no second apply needed.
    auto_deployments_enabled = true

    authentication_configuration {
      access_role_arn = aws_iam_role.access.arn
    }

    image_repository {
      image_repository_type = "ECR"
      image_identifier      = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"

      image_configuration {
        port = "8080" # Caddy's public listener; Node stays on loopback inside

        runtime_environment_variables = {
          NODE_ENV    = "production"
          HOST        = "127.0.0.1" # Node on loopback; Caddy owns the public port
          PORT        = "4173"
          PUBLIC_PORT = "8080"
          # App-level per-IP throttles on the cost-bearing endpoints. Switched on
          # from the first deploy so they are already enforced the day a provider
          # key is added — not a billing cap; provider-side limits remain the backstop.
          GEV_RATELIMIT_OPENAI_PER_MIN = var.ratelimit_openai_per_min
          GEV_RATELIMIT_GOOGLE_PER_MIN = var.ratelimit_google_per_min
        }

        runtime_environment_secrets = { for k, p in aws_ssm_parameter.secret : k => p.arn }
      }
    }
  }

  instance_configuration {
    cpu               = var.cpu
    memory            = var.memory
    instance_role_arn = aws_iam_role.instance.arn
  }

  # /healthz is unauthenticated in the Caddyfile and proxies to the real app,
  # so a dead Node process fails the probe instead of hiding behind Caddy.
  health_check_configuration {
    protocol            = "HTTP"
    path                = "/healthz"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 1
    unhealthy_threshold = 5
  }

  auto_scaling_configuration_arn = aws_apprunner_auto_scaling_configuration_version.app.arn

  depends_on = [aws_iam_role_policy_attachment.access_ecr]
}

# ---------- guardrail: cost alert ----------

# Account-wide: a personal account's spend IS this project's spend, and a
# tag-scoped budget needs cost-allocation tags activated in the Billing console
# with a 24 h lag before they filter anything. Two notifications: 80% of the
# ceiling actually spent, and a forecast that the month will cross 100%.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ---------- guardrail: WAF ----------

# Attached straight to the App Runner service (no CloudFront needed). Three
# rules, chosen for low false-positive risk: a per-IP rate limit, Amazon's
# IP-reputation list, and the known-bad-inputs set (log4j-class payloads).
# The Common Rule Set is deliberately NOT included — its SQLi/XSS heuristics
# would block legitimate Overpass QL bodies such as ["name"~"..."].
resource "aws_wafv2_web_acl" "app" {
  count = var.enable_waf ? 1 : 0

  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "app" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_apprunner_service.app.arn
  web_acl_arn  = aws_wafv2_web_acl.app[0].arn
}
