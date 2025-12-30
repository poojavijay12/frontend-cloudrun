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
  type        = string
  default     = "asia-south1"
}

variable "service_name" {
  type        = string
  default     = "frontend-app"
}



############################################
# ENABLE REQUIRED APIS
############################################
#resource "google_project_service" "apis" {
#  for_each = toset([
#    "run.googleapis.com",
#    "compute.googleapis.com",
#    "iam.googleapis.com",
#    "cloudresourcemanager.googleapis.com"
#  ])
#
#  service = each.value
#}

############################################
# CLOUD RUN (PRIVATE FRONTEND)
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
# CLOUD RUN IAM (ONLY LOAD BALANCER CAN INVOKE)
############################################
resource "google_cloud_run_service_iam_member" "lb_invoker" {
  location = google_cloud_run_service.frontend.location
  service  = google_cloud_run_service.frontend.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${var.project_id}@gcp-sa-cloudrun.iam.gserviceaccount.com"
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

  rule {
    priority = 1000
    action   = "allow"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  rule {
    priority = 900
    action   = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
  }

  rule {
    priority = 800
    action   = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
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
# HTTPS PROXY
############################################
resource "google_compute_target_https_proxy" "https_proxy" {
  name = "frontend-https-proxy"

  url_map = google_compute_url_map.url_map.id

  
}

############################################
# GLOBAL FORWARDING RULE (PUBLIC ENTRY)
############################################
resource "google_compute_global_forwarding_rule" "https_rule" {
  name       = "frontend-https-forwarding-rule"
  port_range = "443"
  target     = google_compute_target_https_proxy.https_proxy.id
}

############################################
# OUTPUTS
############################################
output "load_balancer_ip" {
  value       = google_compute_global_forwarding_rule.https_rule.ip_address
  description = "Public IP of the HTTPS Load Balancer"
}

output "cloud_run_service" {
  value = google_cloud_run_service.frontend.name
}
