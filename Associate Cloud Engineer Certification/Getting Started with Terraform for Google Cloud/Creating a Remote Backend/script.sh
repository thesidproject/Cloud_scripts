#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS & ENVIRONMENT DEFAULTS
# Override inline: REGION="us-central1" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-central1}}"
[ "$REGION" = "(unset)" ] || [ -z "$REGION" ] && export REGION="us-central1"

# Dynamic Project ID detection
_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export BUCKET_NAME="${BUCKET_NAME:-$PROJECT_ID}"
export AUTO_DESTROY="${AUTO_DESTROY:-false}"

# Terminal color definitions
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "=================================================="
echo "Project ID     : $PROJECT_ID"
echo "Primary Region : $REGION"
echo "Bucket Name    : $BUCKET_NAME"
echo "Auto Destroy   : $AUTO_DESTROY"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# Ensure Storage API is active
gcloud services enable storage.googleapis.com --quiet

# ==============================================================================
# TASK 2: Set up Terraform and Cloud Shell
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 2] Configuring ~/.customize_environment and installing Terraform..."
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
# TASK 3: Add a local backend
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 3] Configuring main.tf with local backend and provisioning bucket..."
echo "=================================================="

cat << EOF > main.tf
provider "google" {
  project = "${PROJECT_ID}"
  region  = "${REGION}"
}

resource "google_storage_bucket" "test-bucket-for-state" {
  name                        = "${BUCKET_NAME}"
  location                    = "US"
  uniform_bucket_level_access = true
}

terraform {
  backend "local" {
    path = "terraform/state/terraform.tfstate"
  }
}
EOF

echo "Initializing Terraform with local backend..."
terraform init

echo "Applying Terraform configuration to create storage bucket..."
terraform apply -auto-approve

echo "Inspecting state file..."
terraform show

echo "Local backend and Cloud Storage bucket created successfully."

# ==============================================================================
# TASK 4: Add a Cloud Storage backend
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 4] Migrating state to Cloud Storage backend (gcs)..."
echo "=================================================="

cat << EOF > main.tf
provider "google" {
  project = "${PROJECT_ID}"
  region  = "${REGION}"
}

resource "google_storage_bucket" "test-bucket-for-state" {
  name                        = "${BUCKET_NAME}"
  location                    = "US"
  uniform_bucket_level_access = true
}

terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "terraform/state"
  }
}
EOF

echo "Migrating state to GCS backend..."
echo "yes" | terraform init -migrate-state -force-copy || echo "yes" | terraform init -migrate-state

echo "Verifying remote state file in Cloud Storage..."
gcloud storage ls "gs://${BUCKET_NAME}/terraform/state/" || true

echo "Cloud Storage backend migration completed successfully."

# ==============================================================================
# TASK 5: Refresh the state
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 5] Adding custom label to bucket and refreshing state..."
echo "=================================================="

echo "Applying custom labels (key=value, key2=value) to bucket..."
gcloud storage buckets update "gs://${BUCKET_NAME}" --update-labels="key=value,key2=value" 2>/dev/null || \
gcloud storage buckets update "gs://${BUCKET_NAME}" --update-labels="key2=value" 2>/dev/null || true

echo "Executing terraform refresh..."
terraform refresh

echo "Inspecting refreshed state..."
terraform show

# ==============================================================================
# CHECKPOINT CONFIRMATION BEFORE TASK 6 (CLEANUP & DESTROY)
# ==============================================================================
if [ "$AUTO_DESTROY" = "true" ]; then
    echo ""
    echo "AUTO_DESTROY=true is set. Proceeding directly to Task 6 (cleanup & destroy)..."
else
    echo ""
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  [!] ACTION REQUIRED: Verify checkpoints in the lab UI now:       ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${GREEN}      1. Add a local backend                                       ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      2. Add a Cloud Storage backend                               ${CYAN}|${NC}"
    echo -e "${CYAN}|${GREEN}      3. Refresh the state                                         ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}|${YELLOW}  Do NOT press Enter until checkpoints 1, 2, and 3 are green!       ${CYAN}|${NC}"
    echo -e "${CYAN}|                                                                   |${NC}"
    echo -e "${CYAN}+-------------------------------------------------------------------+${NC}"
    echo ""
    read -p "Once verified, press [Enter] to run Task 6 (Clean up the workspace)..." || true
fi

# ==============================================================================
# TASK 6: Clean up the workspace
# ==============================================================================
echo ""
echo "=================================================="
echo ">>> [Task 6] Reverting backend to local and destroying infrastructure..."
echo "=================================================="

cat << EOF > main.tf
provider "google" {
  project = "${PROJECT_ID}"
  region  = "${REGION}"
}

resource "google_storage_bucket" "test-bucket-for-state" {
  name                        = "${BUCKET_NAME}"
  location                    = "US"
  uniform_bucket_level_access = true
  force_destroy               = true
}

terraform {
  backend "local" {
    path = "terraform/state/terraform.tfstate"
  }
}
EOF

echo "Migrating state back to local backend..."
echo "yes" | terraform init -migrate-state -force-copy || echo "yes" | terraform init -migrate-state

echo "Applying force_destroy = true update to bucket..."
terraform apply -auto-approve

echo "Destroying infrastructure via Terraform..."
terraform destroy -auto-approve

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
echo -e "${CYAN}|${YELLOW}  You can now click 'Check My Progress' for:                       ${CYAN}|${NC}"
echo -e "${CYAN}|${GREEN}      4. Clean up the workspace                                    ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
