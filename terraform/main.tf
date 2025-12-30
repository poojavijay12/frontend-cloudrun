############################################
# TERRAFORM (BACKEND + PROVIDERS)
############################################
terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {
    bucket = "testing-474706-terraform-state"
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
  type        = string
  description = "GCP Project ID"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "service_name" {
  type    = string
  default = "frontend-app"
}

variable "image_tag" {
  type        = string
  description = "Docker image tag"
}

############################################
# CLOUD RUN (LB-ONLY INGRESS)
############################################
resource "google_cloud_run_service" "frontend" {
  name     = var.service_name
  location = var.region

  metadata {
    annotations = {
      # 🔒 ONLY reachable via Load Balancer
      "run.googleapis.com/ingress" = "internal-and-cloud-load-balancing"
    }
  }

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
}

############################################
# CLOUD RUN IAM (REQUIRED FOR LB)
############################################
resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_service.frontend.location
  service  = google_cloud_run_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

############################################
# SERVERLESS NEG
############################################
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "frontend-serverless-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_service.frontend.name
  }
}

############################################
# CLOUD ARMOR
############################################
resource "google_compute_security_policy" "cloud_armor" {
  name = "frontend-cloud-armor"

  rule {
    priority = 800
    action   = "deny(403)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
  }

  rule {
    priority = 900
    action   = "deny(403)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  rule {
    priority = 2147483647
    action   = "allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

############################################
# BACKEND SERVICE
############################################
resource "google_compute_backend_service" "backend" {
  name                  = "frontend-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }

  security_policy = google_compute_security_policy.cloud_armor.id
}

############################################
# URL MAP
############################################
resource "google_compute_url_map" "url_map" {
  name            = "frontend-url-map"
  default_service = google_compute_backend_service.backend.id
}

############################################
# GLOBAL IP
############################################
resource "google_compute_global_address" "lb_ip" {
  name = "frontend-lb-ip"
}

############################################
# HTTP PROXY
############################################
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "frontend-http-proxy"
  url_map = google_compute_url_map.url_map.id
}

############################################
# HTTP FORWARDING RULE
############################################
resource "google_compute_global_forwarding_rule" "http_rule" {
  name       = "frontend-http-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"
  target     = google_compute_target_http_proxy.http_proxy.id
}

############################################
# OUTPUT
############################################
output "load_balancer_ip" {
  value = google_compute_global_address.lb_ip.address
}
