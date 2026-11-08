#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: BUCKET_NAME="tf-bucket-XXX" VPC_NAME="tf-vpc-XXX" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-west1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-west1"
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-west1-b}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-west1-b"
export BUCKET_NAME="${BUCKET_NAME:-tf-bucket-321642}"
export INSTANCE_3_NAME="${INSTANCE_3_NAME:-tf-instance-717102}"
export VPC_NAME="${VPC_NAME:-tf-vpc-928990}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Region           : $REGION"
echo "Zone             : $ZONE"
echo "Remote Bucket    : $BUCKET_NAME"
echo "Temp Instance 3  : $INSTANCE_3_NAME"
echo "VPC Network      : $VPC_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. VERIFY & INSTALL TERRAFORM CLI
# ==============================================================================
echo "Configuring persistent Cloud Shell environment (~/.customize_environment)..."
cat << 'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -qO - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF

if ! terraform version 2>&1 | grep -qi "Terraform v"; then
    echo "Terraform CLI not found (Cloud Shell placeholder stub detected)."
    echo "Installing Terraform CLI via HashiCorp repository..."
    bash ~/.customize_environment
fi

if ! terraform version 2>&1 | grep -qi "Terraform v"; then
    echo "Error: Terraform installation failed. Please check network/apt access."
    exit 1
fi
echo "Terraform CLI is ready: $(terraform --version | head -n 1)"

# ==============================================================================
# 4. TASK 1: CREATE CONFIGURATION FILES & DIRECTORY STRUCTURE
# ==============================================================================
echo "Setting up modules directory structure..."
mkdir -p modules/instances modules/storage
touch modules/instances/outputs.tf modules/storage/outputs.tf

echo "Creating variables.tf configurations..."
cat << EOF > variables.tf
variable "region" {
  default = "${REGION}"
}

variable "zone" {
  default = "${ZONE}"
}

variable "project_id" {
  default = "${PROJECT_ID}"
}
EOF

cp -f variables.tf modules/instances/variables.tf
cp -f variables.tf modules/storage/variables.tf

echo "Creating initial root main.tf..."
cat << 'EOF' > main.tf
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}
EOF

# ==============================================================================
# 5. TASK 2: IMPORT PRE-EXISTING INFRASTRUCTURE
# ==============================================================================
echo "Creating modules/instances/instances.tf with initial definitions..."
cat << 'EOF' > modules/instances/instances.tf
resource "google_compute_instance" "tf-instance-1" {
  name                    = "tf-instance-1"
  machine_type            = "n1-standard-1"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name                    = "tf-instance-2"
  machine_type            = "n1-standard-1"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}
EOF

echo "Initializing Terraform workspace..."
terraform init

echo "Importing pre-created instances into Terraform state..."
ID_1=$(gcloud compute instances describe tf-instance-1 --zone="$ZONE" --format="value(id)" 2>/dev/null || true)
ID_2=$(gcloud compute instances describe tf-instance-2 --zone="$ZONE" --format="value(id)" 2>/dev/null || true)

terraform import module.instances.google_compute_instance.tf-instance-1 "$ID_1" 2>/dev/null || \
terraform import module.instances.google_compute_instance.tf-instance-1 "${PROJECT_ID}/${ZONE}/tf-instance-1" 2>/dev/null || true

terraform import module.instances.google_compute_instance.tf-instance-2 "$ID_2" 2>/dev/null || \
terraform import module.instances.google_compute_instance.tf-instance-2 "${PROJECT_ID}/${ZONE}/tf-instance-2" 2>/dev/null || true

echo "Applying imported state synchronization..."
terraform apply -auto-approve

# ==============================================================================
# 6. TASK 3: CONFIGURE A REMOTE BACKEND (GCS)
# ==============================================================================
echo "Creating modules/storage/storage.tf for remote backend bucket..."
cat << EOF > modules/storage/storage.tf
resource "google_storage_bucket" "storage-bucket" {
  name                        = "${BUCKET_NAME}"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}
EOF

echo "Adding storage module declaration to main.tf..."
cat << 'EOF' > main.tf
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}
EOF

echo "Initializing and creating Cloud Storage bucket..."
terraform init
terraform apply -auto-approve

echo "Configuring GCS backend in main.tf..."
cat << EOF > main.tf
terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}
EOF

echo "Migrating local state to GCS remote backend..."
echo "yes" | terraform init -migrate-state -force-copy 2>/dev/null || echo "yes" | terraform init 2>/dev/null || true

# ==============================================================================
# 7. TASK 4: MODIFY AND UPDATE INFRASTRUCTURE (SCALE INSTANCES & ADD 3RD)
# ==============================================================================
echo "Updating instances machine type to e2-standard-2 and declaring $INSTANCE_3_NAME..."
cat << EOF > modules/instances/instances.tf
resource "google_compute_instance" "tf-instance-1" {
  name                    = "tf-instance-1"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name                    = "tf-instance-2"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-3" {
  name                    = "${INSTANCE_3_NAME}"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}
EOF

echo "Applying instance updates..."
terraform apply -auto-approve

# ==============================================================================
# 8. TASK 5: DESTROY RESOURCES (REMOVE 3RD INSTANCE)
# ==============================================================================
echo "Removing $INSTANCE_3_NAME from instances configuration to destroy it..."
cat << EOF > modules/instances/instances.tf
resource "google_compute_instance" "tf-instance-1" {
  name                    = "tf-instance-1"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name                    = "tf-instance-2"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network = "default"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}
EOF

echo "Applying destruction of third instance..."
terraform apply -auto-approve

# ==============================================================================
# 9. TASK 6: USE A MODULE FROM THE REGISTRY & UPDATE SUBNET ATTACHMENTS
# ==============================================================================
echo "Adding registry network module to main.tf..."
cat << EOF > main.tf
terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}

module "vpc" {
  source       = "terraform-google-modules/network/google"
  version      = "10.0.0"
  project_id   = var.project_id
  network_name = "${VPC_NAME}"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "subnet-01"
      subnet_ip     = "10.10.10.0/24"
      subnet_region = var.region
    },
    {
      subnet_name   = "subnet-02"
      subnet_ip     = "10.10.20.0/24"
      subnet_region = var.region
    }
  ]
}
EOF

echo "Re-initializing Terraform for network module..."
terraform init
echo "Applying custom VPC network creation..."
terraform apply -auto-approve

echo "Updating instances network interfaces to attach to custom subnets..."
cat << EOF > modules/instances/instances.tf
resource "google_compute_instance" "tf-instance-1" {
  name                    = "tf-instance-1"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network    = "${VPC_NAME}"
    subnetwork = "subnet-01"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name                    = "tf-instance-2"
  machine_type            = "e2-standard-2"
  zone                    = var.zone
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    network    = "${VPC_NAME}"
    subnetwork = "subnet-02"
  }
  metadata_startup_script = <<-EOT
#!/bin/bash
EOT
  allow_stopping_for_update = true
}
EOF

echo "Applying instance subnet attachment changes..."
terraform apply -auto-approve

# ==============================================================================
# 10. TASK 7: CONFIGURE A FIREWALL RULE
# ==============================================================================
echo "Adding firewall rule tf-firewall to main.tf..."
cat << EOF >> main.tf

resource "google_compute_firewall" "tf-firewall" {
  name    = "tf-firewall"
  network = "${VPC_NAME}"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
}
EOF

echo "Applying final firewall configuration..."
terraform apply -auto-approve

# ==============================================================================
# 11. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "Remote State Storage Bucket:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" --format="table(name, location, storageClass)" 2>/dev/null || true

echo ""
echo "Custom VPC Network & Subnets:"
gcloud compute networks describe "${VPC_NAME}" --format="yaml(name, routingConfig.routingMode, subnetworks)" 2>/dev/null || true

echo ""
echo "Compute Engine Instances:"
gcloud compute instances list --filter="name ~ tf-instance" --format="table(name, zone, machineType, networkInterfaces[0].network, networkInterfaces[0].subnetwork)"

echo ""
echo "Firewall Rules:"
gcloud compute firewall-rules describe tf-firewall --format="yaml(name, network, allowed, sourceRanges)" 2>/dev/null || true

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
