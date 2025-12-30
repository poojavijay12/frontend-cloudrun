############################################
# TERRAFORM (BACKEND + PROVIDERS)
############################################
terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {
    bucket  = "testing-474706-terraform-state"
    prefix = "frontend-cloudrun"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

############################################
# PROVIDER
############################################
provider "google" {
  project = var.project_id
  region  = var.region
}

############################################
# VARIABLES
############################################
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "Deployment region"
  type        = string
  default     = "asia-south1"
}

variable "service_name" {
  description = "Cloud Run service name"
  type        = string
  default     = "frontend-app-v2"
}

variable "image_tag" {
  description = "Immutable Docker image tag (Git SHA)"
  type        = string
}

############################################
# CLOUD RUN (FRONTEND)
############################################
resource "google_cloud_run_service" "frontend" {
  name     = var.service_name
  location = var.region

  template {
    spec {
      containers {
        image = "gcr.io/${var.project_id}/frontend:${var.image_tag}"

        ports {
          container_port = 8080
        }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  autogenerate_revision_name = true
}

############################################
# CLOUD RUN IAM (PUBLIC FOR DEMO)
# ⚠️ Replace with LB service account in prod
############################################
resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_service.frontend.location
  service  = google_cloud_run_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

############################################
# SERVERLESS NEG (LB → CLOUD RUN)
############################################
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "frontend-serverless-neg-v2"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_service.frontend.name
  }
}

############################################
# BACKEND SERVICE
############################################
resource "google_compute_backend_service" "backend" {
  name                  = "frontend-backend-v2"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 30

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
}

############################################
# URL MAP
############################################
resource "google_compute_url_map" "url_map" {
  name            = "frontend-url-map-v2"
  default_service = google_compute_backend_service.backend.id
}

############################################
# HTTPS PROXY
############################################
resource "google_compute_target_https_proxy" "https_proxy" {
  name    = "frontend-https-proxy-v2"
  url_map = google_compute_url_map.url_map.id
}

############################################
# GLOBAL FORWARDING RULE
############################################
resource "google_compute_global_forwarding_rule" "https_rule" {
  name       = "frontend-https-forwarding-rule-v2"
  port_range = "443"
  target     = google_compute_target_https_proxy.https_proxy.id
}

############################################
# OUTPUTS
############################################
output "load_balancer_ip" {
  description = "Public IP of HTTPS Load Balancer"
  value       = google_compute_global_forwarding_rule.https_rule.ip_address
}

output "cloud_run_service" {
  value = google_cloud_run_service.frontend.name
}
