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
  description = "Docker image tag (Git SHA or version)"
}

############################################
# CLOUD RUN (FRONTEND RUNTIME – LB ONLY)
############################################
resource "google_cloud_run_service" "frontend" {
  name     = var.service_name
  location = var.region

  metadata {
    annotations = {
      # ✅ REQUIRED for Serverless NEG + External HTTPS LB
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

  autogenerate_revision_name = true
}

############################################
# SERVERLESS NEG (LB → CLOUD RUN)
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

  # OWASP SQL Injection
  rule {
    priority = 900
    action   = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  # ✅ MANDATORY DEFAULT RULE
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
  timeout_sec           = 30

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
# GLOBAL STATIC IP
############################################
resource "google_compute_global_address" "lb_ip" {
  name = "frontend-lb-ip"
}

############################################
# MANAGED SSL CERT (DEMO DOMAIN)
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
  ssl_certificates = [
    google_compute_managed_ssl_certificate.cert.id
  ]
}

############################################
# GLOBAL FORWARDING RULE (HTTPS)
############################################
resource "google_compute_global_forwarding_rule" "https_rule" {
  name       = "frontend-https-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "443"
  target     = google_compute_target_https_proxy.https_proxy.id
}
############################################
# HTTP URL MAP (DIRECT TO BACKEND)
############################################
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "frontend-http-proxy"
  url_map = google_compute_url_map.url_map.id
}

############################################
# HTTP FORWARDING RULE (PORT 80)
############################################
resource "google_compute_global_forwarding_rule" "http_rule" {
  name       = "frontend-http-rule"
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"
  target     = google_compute_target_http_proxy.http_proxy.id
}


############################################
# OUTPUTS
############################################
output "load_balancer_ip" {
  description = "Public IP of the HTTPS Load Balancer"
  value       = google_compute_global_address.lb_ip.address
}

output "cloud_run_service" {
  value = google_cloud_run_service.frontend.name
}
