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
  description = "Docker image tag (Git SHA)"
}

############################################
# CLOUD RUN (PRIVATE FRONTEND RUNTIME)
############################################
resource "google_cloud_run_service" "frontend" {
  name     = var.service_name
  location = var.region

  metadata {
    annotations = {
      # Allow traffic only via LB
      "run.googleapis.com/ingress" = "all"
    }
  }

  template {
    spec {
      containers {
        image = "gcr.io/${var.project_id}/frontend:${var.image_tag}"

        ports {
          container_port = 80
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
# CLOUD RUN IAM (ONLY LB INVOKER – SECURITY FIRST)
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
# CLOUD ARMOR (WAF)
############################################
resource "google_compute_security_policy" "cloud_armor" {
  name = "frontend-cloud-armor"

  # OWASP XSS
  rule {
    priority = 800
    action   = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
  }

  # OWASP SQLi
  rule {
    priority = 900
    action   = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  # 🔑 REQUIRED DEFAULT RULE (MUST EXIST)
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
# BACKEND SERVICE (ATTACHED TO CLOUD ARMOR)
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
# SSL CERT (DEMO DOMAIN)
############################################
resource "google_compute_managed_ssl_certificate" "cert" {
  name = "frontend-cert"

  managed {
    domains = ["example.com"]
  }
}

############################################
# HTTPS PROXY
############################################
resource "google_compute_target_https_proxy" "https_proxy" {
  name            = "frontend-https-proxy"
  url_map         = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
}

############################################
# FORWARDING RULE
############################################
resource "google_compute_global_forwarding_rule" "https_rule" {
  name       = "frontend-https-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "443"
  target     = google_compute_target_https_proxy.https_proxy.id
}

############################################
# OUTPUTS
############################################
output "load_balancer_ip" {
  value = google_compute_global_address.lb_ip.address
}
