#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
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

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

# Color definitions
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
# TASK 1: Set up Terraform and Cloud Shell
# ==============================================================================
echo ""
echo ">>> [Task 1] Verifying Terraform installation..."
if ! command -v terraform >/dev/null 2>&1; then
    echo "Installing Terraform CLI..."
    cat << 'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
    bash ~/.customize_environment
fi
terraform --version

# ==============================================================================
# TASK 2: Add Google Cloud provider
# ==============================================================================
echo ""
echo ">>> [Task 2] Configuring Google Cloud provider in main.tf..."
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
# TASK 3: Build the infrastructure (e2-micro)
# ==============================================================================
echo ""
echo ">>> [Task 3] Defining and applying initial compute instance (e2-micro)..."
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

terraform apply -auto-approve
echo "Initial instance ${VM_NAME} (e2-micro) provisioned successfully."

# ==============================================================================
# TASK 4: Change the infrastructure
# 1. Add tags: ["web", "dev"]
# 2. Update machine_type: e2-medium with allow_stopping_for_update = true
# ==============================================================================
echo ""
echo ">>> [Task 4 - Step 1] Adding tags ['web', 'dev'] to ${VM_NAME}..."
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

terraform apply -auto-approve
echo "Tags ['web', 'dev'] applied successfully."

echo ""
echo ">>> [Task 4 - Step 2] Scaling machine type to e2-medium with allow_stopping_for_update..."
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

terraform apply -auto-approve
echo "Instance scaled to e2-medium with allow_stopping_for_update = true."

# Verification of current infrastructure
echo ""
echo "=================================================="
echo "CURRENT INFRASTRUCTURE STATUS"
echo "=================================================="
gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="yaml(name, machineType, tags.items, status)" 2>/dev/null || true
echo "=================================================="

# ==============================================================================
# CHECKPOINT CONFIRMATION BEFORE DESTROY
# ==============================================================================
if [ "$AUTO_DESTROY" = "true" ]; then
    echo ""
    echo "AUTO_DESTROY=true is set. Proceeding to tear down infrastructure..."
else
    echo ""
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  [!] ACTION REQUIRED: Check your progress in the lab NOW for:     ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${GREEN}      1. Build the infrastructure                                  ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      2. Adding tags to the compute resource                       ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      3. Change the infrastructure for machine-type                ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  Do NOT press Enter until you have verified the first 3 checks!   ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo ""
    read -p "Once the first 3 checkpoints are green, press [Enter] to run 'terraform destroy' for Task 5..." || true
fi

# ==============================================================================
# TASK 5: Destroy the infrastructure
# ==============================================================================
echo ""
echo ">>> [Task 5] Destroying Terraform-managed infrastructure..."
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
