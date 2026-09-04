output "service_url" {
  description = "Public HTTPS URL of the app (basic auth in front)."
  value       = "https://${aws_apprunner_service.app.service_url}"
}

output "ecr_repository_url" {
  description = "Where build-and-push.sh pushes the image."
  value       = aws_ecr_repository.app.repository_url
}

output "region" {
  value = var.region
}

output "ssm_parameter_prefix" {
  description = "All runtime secrets live under this SSM path."
  value       = "/${var.app_name}/"
}
