#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS & ENVIRONMENT DEFAULTS
# Override inline: REGION="us-east1" ZONE="us-east1-c" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east1}}"
[ "$REGION" = "(unset)" ] || [ -z "$REGION" ] && export REGION="us-east1"

_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-east1-c}}"
[ "$ZONE" = "(unset)" ] || [ -z "$ZONE" ] && export ZONE="us-east1-c"

export INSTANCE_1_NAME="${INSTANCE_1_NAME:-myinstance}"
export INSTANCE_2_NAME="${INSTANCE_2_NAME:-terraform-instance-2}"

# Dynamic Project ID detection
_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-bucket}"

# Terminal color definitions
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "=================================================="
echo "Project ID     : $PROJECT_ID"
echo "Primary Region : $REGION"
echo "Primary Zone   : $ZONE"
echo "Instance 1     : $INSTANCE_1_NAME"
echo "Instance 2     : $INSTANCE_2_NAME"
echo "Storage Bucket : $BUCKET_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Enable required Google Cloud APIs
echo "Verifying required APIs..."
gcloud services enable compute.googleapis.com storage.googleapis.com --quiet

# ==============================================================================
# TASK 1: Set up Terraform and Cloud Shell
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 1] Configuring ~/.customize_environment and installing Terraform..."
echo "=================================================="

cat << 'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF

# In Google Cloud Shell, a placeholder stub script may exist that prints
# an installation prompt rather than executing real Terraform.
# We must check whether 'terraform version' actually outputs a valid version string.
if ! terraform version 2>&1 | grep -q "Terraform v"; then
    echo "Terraform CLI not found or placeholder stub detected. Installing Terraform..."
    bash ~/.customize_environment
    hash -r
else
    echo "Terraform is already installed: $(terraform version 2>/dev/null | head -n 1)"
fi

echo "Verifying Terraform version:"
terraform version

# ==============================================================================
# TASK 2: Create the configuration files
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 2] Creating working directory tfinfra and provider.tf..."
echo "=================================================="

if [ "$(basename "$PWD")" != "tfinfra" ]; then
    mkdir -p tfinfra
    cd tfinfra
fi

cat << EOF > provider.tf
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

provider "google" {
  project = "${PROJECT_ID}"
  region  = "${REGION}"
  zone    = "${ZONE}"
}
EOF

echo "Initializing Terraform in tfinfra..."
terraform init

# ==============================================================================
# TASK 3: View Implicit Resource Dependency
# 1. Create variables.tf, outputs.tf, instance.tf, terraform.tfvars
# 2. terraform plan & apply
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 3] Defining implicit dependency (static IP and VM)..."
echo "=================================================="

cat << 'EOF' > variables.tf
variable "instance_name" {
  type        = string
  description = "Name for the Google Compute instance"
}

variable "instance_zone" {
  type        = string
  description = "Zone for the Google Compute instance"
}

variable "instance_type" {
  type        = string
  description = "Disk type of the Google Compute instance"
  default     = "e2-medium"
}
EOF

cat << 'EOF' > outputs.tf
output "network_IP" {
  value       = google_compute_instance.vm_instance.instance_id
  description = "The internal ip address of the instance"
}

output "instance_link" {
  value       = google_compute_instance.vm_instance.self_link
  description = "The URI of the created resource."
}
EOF

cat << 'EOF' > instance.tf
resource "google_compute_address" "vm_static_ip" {
  name = "terraform-static-ip"
}

resource "google_compute_instance" "vm_instance" {
  name         = var.instance_name
  zone         = var.instance_zone
  machine_type = var.instance_type

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Allocate a one-to-one NAT IP to the instance
      nat_ip = google_compute_address.vm_static_ip.address
    }
  }
}
EOF

cat << EOF > terraform.tfvars
instance_name = "${INSTANCE_1_NAME}"
instance_zone = "${ZONE}"
EOF

echo "Re-initializing Terraform for new resource providers..."
terraform init

echo "Generating Terraform plan for implicit dependency..."
terraform plan -var="instance_name=${INSTANCE_1_NAME}" -var="instance_zone=${ZONE}"

echo "Applying Terraform configuration for static IP and ${INSTANCE_1_NAME}..."
terraform apply -auto-approve -var="instance_name=${INSTANCE_1_NAME}" -var="instance_zone=${ZONE}"

echo "Implicit dependency resources successfully created."

# ==============================================================================
# TASK 4: Create Explicit Dependency
# 1. Create exp.tf with bucket and VM (depends_on = [google_storage_bucket.example_bucket])
# 2. terraform plan & apply
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 4] Defining explicit dependency (Storage Bucket & ${INSTANCE_2_NAME})..."
echo "=================================================="

cat << EOF > exp.tf
resource "google_compute_instance" "another_instance" {
  name         = "${INSTANCE_2_NAME}"
  machine_type = "e2-micro"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
    access_config {
    }
  }

  # Tells Terraform that this VM instance must be created only after the
  # storage bucket has been created.
  depends_on = [google_storage_bucket.example_bucket]
}

resource "google_storage_bucket" "example_bucket" {
  name          = "${BUCKET_NAME}"
  location      = "US"
  force_destroy = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}
EOF

echo "Generating Terraform plan for explicit dependency..."
terraform plan -var="instance_name=${INSTANCE_1_NAME}" -var="instance_zone=${ZONE}"

echo "Applying Terraform configuration for Storage Bucket and ${INSTANCE_2_NAME}..."
terraform apply -auto-approve -var="instance_name=${INSTANCE_1_NAME}" -var="instance_zone=${ZONE}"

echo "Explicit dependency resources successfully created."

# ==============================================================================
# TASK 5: View Dependency Graph
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 5] Generating resource dependency graph..."
echo "=================================================="

if ! command -v dot >/dev/null 2>&1; then
    echo "Installing graphviz package..."
    sudo apt-get update -y && sudo apt-get install -y graphviz
fi

terraform graph | dot -Tpng > graph.png
echo "Dependency graph saved to: $(pwd)/graph.png"

# ==============================================================================
# VERIFICATION CHECKS
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION"
echo "=================================================="

echo "--- 1. Static IP Address ---"
gcloud compute addresses describe terraform-static-ip --region="$REGION" --format="yaml(name, address, status)" 2>/dev/null || true

echo ""
echo "--- 2. Compute Instances ---"
gcloud compute instances list --filter="name=(${INSTANCE_1_NAME} OR ${INSTANCE_2_NAME})" --format="table(name, zone, machineType, status, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)" 2>/dev/null || true

echo ""
echo "--- 3. Cloud Storage Bucket ---"
gcloud storage buckets describe "gs://${BUCKET_NAME}" --format="yaml(name, location, website)" 2>/dev/null || true

# Execution summary
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL_MINUTES=$((TOTAL_DURATION / 60))
TOTAL_SECONDS=$((TOTAL_DURATION % 60))

TIME_STR="Execution Time: ${TOTAL_MINUTES} min ${TOTAL_SECONDS} sec"

echo -e "\n${CYAN}+-------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}  All 4 checkpoints can now be verified in the lab UI:            ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      1. Create static IP using implicit dependency                ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      2. Create VM instance using implicit dependency              ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      3. Create cloud storage bucket using explicit dependency     ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      4. Create VM instance resource using explicit dependency     ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
