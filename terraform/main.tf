############################################
# TERRAFORM & PROVIDER
############################################
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

############################################
# VARIABLES
############################################
variable "project_id" {
  type        = string
  description = "GCP Project ID"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "service_name" {
  type    = string
  default = "frontend-app-v2"
}

############################################
# CLOUD RUN (FRONTEND V2)
############################################
resource "google_cloud_run_service" "frontend" {
  name     = var.service_name
  location = var.region

  template {
    spec {
      containers {
        image = "gcr.io/${var.project_id}/frontend:latest"

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
# CLOUD RUN IAM (INVOKED VIA LOAD BALANCER)
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
# BACKEND SERVICE (NO CLOUD ARMOR FOR NOW)
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

  # Cloud Armor disabled due to quota = 0
  # security_policy = google_compute_security_policy.cloud_armor.id
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
  value       = google_compute_global_forwarding_rule.https_rule.ip_address
  description = "Public IP of HTTPS Load Balancer"
}

output "cloud_run_service" {
  value = google_cloud_run_service.frontend.name
}
