#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different regions/zones.
# Override inline: ZONE_1="europe-west4-c" ZONE_2="europe-west1-b" ./script.sh
# ==============================================================================
_DET_REGION_1=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION_1="${REGION_1:-${_DET_REGION_1:-europe-west4}}"
[ "$REGION_1" = "(unset)" ] && export REGION_1="europe-west4"
_DET_ZONE_1=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE_1="${ZONE_1:-${_DET_ZONE_1:-europe-west4-c}}"
[ "$ZONE_1" = "(unset)" ] && export ZONE_1="europe-west4-c"
export REGION_2="${REGION_2:-europe-west1}"
export ZONE_2="${ZONE_2:-europe-west1-b}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Primary Region   : $REGION_1 (Zone: $ZONE_1)"
echo "Secondary Region : $REGION_2 (Zone: $ZONE_2)"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION_1" --quiet
gcloud config set compute/zone "$ZONE_1" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: SET UP TERRAFORM AND CLOUD SHELL ENVIRONMENT
# ==============================================================================
echo "Configuring persistent Cloud Shell environment (~/.customize_environment)..."
cat << 'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -qO - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF

# Detect real Terraform binary vs Cloud Shell placeholder stub
if ! terraform version 2>&1 | grep -qi "Terraform v"; then
    echo "Terraform binary not found (Cloud Shell placeholder stub detected)."
    echo "Installing Terraform CLI via HashiCorp repository..."
    bash ~/.customize_environment
fi

# Verify Terraform binary is genuinely installed
if ! terraform version 2>&1 | grep -qi "Terraform v"; then
    echo "Error: Terraform installation failed. Please check network/apt access."
    exit 1
fi
echo "Terraform CLI is ready: $(terraform --version | head -n 1)"

WORKSPACE_DIR="$HOME/tfinfra"
echo "Setting up Terraform workspace in $WORKSPACE_DIR..."
mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

echo "Creating provider.tf..."
cat << 'EOF' > provider.tf
provider "google" {}
EOF

echo "Initializing Terraform provider..."
terraform init -upgrade

# ==============================================================================
# 4. TASK 2: CREATE MYNETWORK AND ITS RESOURCES
# ==============================================================================
echo "Creating reusable instance module..."
mkdir -p "$WORKSPACE_DIR/instance"

cat << 'EOF' > "$WORKSPACE_DIR/instance/variables.tf"
variable "instance_name" {}
variable "instance_zone" {}
variable "instance_type" {
  default = "e2-micro"
}
variable "instance_network" {}
EOF

cat << 'EOF' > "$WORKSPACE_DIR/instance/main.tf"
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
    network = var.instance_network
    access_config {
      # Allocate a one-to-one NAT IP to the instance
    }
  }
}
EOF

echo "Creating mynetwork.tf configuration..."
cat << EOF > "$WORKSPACE_DIR/mynetwork.tf"
# Create the mynetwork network
resource "google_compute_network" "mynetwork" {
  name                    = "mynetwork"
  auto_create_subnetworks = "true"
}

# Add a firewall rule to allow HTTP, SSH, RDP and ICMP traffic on mynetwork
resource "google_compute_firewall" "mynetwork-allow-http-ssh-rdp-icmp" {
  name    = "mynetwork-allow-http-ssh-rdp-icmp"
  network = google_compute_network.mynetwork.self_link
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "3389"]
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
}

# Create the mynet-vm-1 instance
module "mynet-vm-1" {
  source           = "./instance"
  instance_name    = "mynet-vm-1"
  instance_zone    = "${ZONE_1}"
  instance_network = google_compute_network.mynetwork.self_link
}

# Create the mynet-vm-2 instance
module "mynet-vm-2" {
  source           = "./instance"
  instance_name    = "mynet-vm-2"
  instance_zone    = "${ZONE_2}"
  instance_network = google_compute_network.mynetwork.self_link
}
EOF

echo "Formatting Terraform configuration files..."
terraform fmt

echo "Re-initializing Terraform workspace modules..."
terraform init

echo "Applying Terraform configuration..."
terraform apply -auto-approve

# ==============================================================================
# 5. TASK 3: VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "VPC Network Details:"
gcloud compute networks describe mynetwork --format="yaml(name, autoCreateSubnetworks, subnetworks)"

echo ""
echo "Firewall Rule Details:"
gcloud compute firewall-rules describe mynetwork-allow-http-ssh-rdp-icmp --format="yaml(name, network, allowed, sourceRanges)"

echo ""
echo "Compute Engine Instances:"
gcloud compute instances list --filter="networkInterfaces.network ~ mynetwork" --format="table(name, zone, status, networkInterfaces[0].networkIP, networkInterfaces[0].accessConfigs[0].natIP)"

# Calculate execution duration
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL_MINUTES=$((TOTAL_DURATION / 60))
TOTAL_SECONDS=$((TOTAL_DURATION % 60))

# Display completion status
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TIME_STR="Execution Time: ${TOTAL_MINUTES} min ${TOTAL_SECONDS} sec"

echo -e "\n${CYAN}+-------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
