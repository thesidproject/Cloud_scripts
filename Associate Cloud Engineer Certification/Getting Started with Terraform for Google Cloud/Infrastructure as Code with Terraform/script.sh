#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS & ENVIRONMENT DEFAULTS
# Edit these variables if your lab assigns different values.
# Override inline: REGION="us-west1" ZONE="us-west1-b" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-west1}}"
[ "$REGION" = "(unset)" ] || [ -z "$REGION" ] && export REGION="us-west1"

_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-west1-b}}"
[ "$ZONE" = "(unset)" ] || [ -z "$ZONE" ] && export ZONE="us-west1-b"

export VM_NAME="${VM_NAME:-terraform}"
export IMAGE="${IMAGE:-debian-cloud/debian-12}"
export AUTO_DESTROY="${AUTO_DESTROY:-false}"

_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

# Terminal colors
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "=================================================="
echo "Project ID   : $PROJECT_ID"
echo "Region       : $REGION"
echo "Zone         : $ZONE"
echo "VM Name      : $VM_NAME"
echo "Boot Image   : $IMAGE"
echo "Auto Destroy : $AUTO_DESTROY"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet

# ==============================================================================
# TASK 2: Set up Terraform and Cloud Shell
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 2] Configuring ~/.customize_environment and Terraform CLI..."
echo "=================================================="

# Ensure HashiCorp repository key and source list persist across Cloud Shell sessions
cat << 'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF

# Install Terraform if real binary is not detected (Cloud Shell includes a placeholder stub)
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
# TASK 3: Add Google Cloud provider
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 3] Configuring Google Cloud provider in main.tf..."
echo "=================================================="

cat << EOF > main.tf
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

echo "Initializing Terraform..."
terraform init

# ==============================================================================
# TASK 4: Build the infrastructure
# 1. Define compute instance (e2-micro) with default network
# 2. Run terraform plan
# 3. Run terraform apply
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 4] Defining compute instance ${VM_NAME} (e2-micro)..."
echo "=================================================="

cat << EOF > main.tf
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

resource "google_compute_instance" "terraform" {
  name         = "${VM_NAME}"
  machine_type = "e2-micro"

  boot_disk {
    initialize_params {
      image = "${IMAGE}"
    }
  }

  network_interface {
    network = "default"
    access_config {
    }
  }
}
EOF

echo "Generating execution plan for Task 4..."
terraform plan

echo "Applying Terraform configuration..."
terraform apply -auto-approve

echo "Compute instance ${VM_NAME} (e2-micro) created successfully."

# ==============================================================================
# TASK 5: Change the infrastructure
# Step 1: Adding tags to the compute resource: ["web", "dev"]
# Step 2: Editing the machine type: e2-medium with allow_stopping_for_update = true
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 5 - Step 1] Adding tags ['web', 'dev'] to ${VM_NAME}..."
echo "=================================================="

cat << EOF > main.tf
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

resource "google_compute_instance" "terraform" {
  name         = "${VM_NAME}"
  machine_type = "e2-micro"
  tags         = ["web", "dev"]

  boot_disk {
    initialize_params {
      image = "${IMAGE}"
    }
  }

  network_interface {
    network = "default"
    access_config {
    }
  }
}
EOF

terraform plan
terraform apply -auto-approve
echo "Tags ['web', 'dev'] added successfully."

echo ""
echo "=================================================="
echo ">>> [Task 5 - Step 2] Updating machine type to e2-medium with allow_stopping_for_update..."
echo "=================================================="

cat << EOF > main.tf
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

resource "google_compute_instance" "terraform" {
  name                      = "${VM_NAME}"
  machine_type              = "e2-medium"
  tags                      = ["web", "dev"]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "${IMAGE}"
    }
  }

  network_interface {
    network = "default"
    access_config {
    }
  }
}
EOF

terraform plan
terraform apply -auto-approve
echo "Machine type updated to e2-medium successfully."

# Verify current VM state on Compute Engine
echo ""
echo "=================================================="
echo "CURRENT VM INSTANCE STATE"
echo "=================================================="
gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="yaml(name, machineType, tags.items, status)" 2>/dev/null || true
echo "=================================================="

# ==============================================================================
# CHECKPOINT CONFIRMATION BEFORE TASK 6 (DESTROY)
# ==============================================================================
if [ "$AUTO_DESTROY" = "true" ]; then
    echo ""
    echo "AUTO_DESTROY=true is set. Proceeding directly to Task 6 (destroy)..."
else
    echo ""
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  [!] ACTION REQUIRED: Verify checkpoints in the lab UI now:       ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${GREEN}      1. Build the infrastructure                                  ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      2. Adding tags to the compute resource                       ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      3. Change the infrastructure for machine-type                ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  Do NOT press Enter until checkpoints 1, 2, and 3 are green!       ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo ""
    read -p "Once verified, press [Enter] to run Task 6 (terraform destroy)..." || true
fi

# ==============================================================================
# TASK 6: Destroy the infrastructure
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 6] Destroying Terraform-managed infrastructure..."
echo "=================================================="
terraform destroy -auto-approve
echo "Infrastructure destroyed successfully."

# Calculate execution duration
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL_MINUTES=$((TOTAL_DURATION / 60))
TOTAL_SECONDS=$((TOTAL_DURATION % 60))

TIME_STR="Execution Time: ${TOTAL_MINUTES} min ${TOTAL_SECONDS} sec"

echo -e "\n${CYAN}+-------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}  You can now click 'Check My Progress' for:                       ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      4. Destroy the Infrastructure                                ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
