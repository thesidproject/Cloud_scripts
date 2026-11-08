#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION_1="us-central1" ZONE_1="us-central1-c" ./script.sh
# ==============================================================================
export REGION_1="${REGION_1:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-east1")}"
export ZONE_1="${ZONE_1:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-east1-c")}"
export REGION_2="${REGION_2:-}"
export ZONE_2="${ZONE_2:-}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

# Auto-detect allowed secondary region from org policy if not explicitly provided
if [ -z "$REGION_2" ]; then
    if gcloud org-policies describe constraints/gcp.resourceLocations --project="$PROJECT_ID" 2>/dev/null | grep -q "in:us-east1-locations"; then
        export REGION_2="us-east1"
        export ZONE_2="us-east1-b"
    else
        export REGION_2="europe-west1"
        export ZONE_2="europe-west1-d"
    fi
fi
if [ -z "$ZONE_2" ]; then
    export ZONE_2="${REGION_2}-b"
fi

echo "=================================================="
echo "Project ID : $PROJECT_ID"
echo "US Region  : $REGION_1 ($ZONE_1)"
echo "EU Region  : $REGION_2 ($ZONE_2)"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet

# Enable required APIs
echo "Enabling IAP and Network Management APIs..."
gcloud services enable iap.googleapis.com networkmanagement.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: EXPLORE AND DELETE DEFAULT NETWORK & FIREWALL RULES
# ==============================================================================
echo "Checking and deleting default firewall rules..."
FIREWALL_RULES=$(gcloud compute firewall-rules list --filter="network=default" --format="value(name)" 2>/dev/null || true)
if [ -n "$FIREWALL_RULES" ]; then
    echo "Deleting default firewall rules..."
    # shellcheck disable=SC2086
    gcloud compute firewall-rules delete $FIREWALL_RULES --quiet
fi

if gcloud compute networks describe default &>/dev/null; then
    echo "Deleting default VPC network..."
    gcloud compute networks delete default --quiet
else
    echo "Default VPC network is already deleted."
fi

# ==============================================================================
# 4. TASK 2: CREATE AUTO MODE NETWORK (mynetwork) AND CONVERT TO CUSTOM
# ==============================================================================
echo "Checking VPC network: mynetwork..."
if ! gcloud compute networks describe mynetwork &>/dev/null; then
    echo "Creating auto-mode network mynetwork (auto-generates subnets across all regions)..."
    gcloud compute networks create mynetwork --subnet-mode=auto --quiet
fi

# Create standard firewall rules for mynetwork in parallel
echo "Configuring firewall rules for mynetwork..."
(
    if ! gcloud compute firewall-rules describe mynetwork-allow-custom &>/dev/null; then
        gcloud compute firewall-rules create mynetwork-allow-custom \
            --network=mynetwork --direction=INGRESS --priority=65534 \
            --action=ALLOW --rules=tcp,udp,icmp --source-ranges=10.128.0.0/9 --quiet || true
    fi
) &
(
    if ! gcloud compute firewall-rules describe mynetwork-allow-icmp &>/dev/null; then
        gcloud compute firewall-rules create mynetwork-allow-icmp \
            --network=mynetwork --direction=INGRESS --priority=65534 \
            --action=ALLOW --rules=icmp --source-ranges=0.0.0.0/0 --quiet || true
    fi
) &
(
    if ! gcloud compute firewall-rules describe mynetwork-allow-rdp &>/dev/null; then
        gcloud compute firewall-rules create mynetwork-allow-rdp \
            --network=mynetwork --direction=INGRESS --priority=65534 \
            --action=ALLOW --rules=tcp:3389 --source-ranges=0.0.0.0/0 --quiet || true
    fi
) &
(
    if ! gcloud compute firewall-rules describe mynetwork-allow-ssh &>/dev/null; then
        gcloud compute firewall-rules create mynetwork-allow-ssh \
            --network=mynetwork --direction=INGRESS --priority=65534 \
            --action=ALLOW --rules=tcp:22 --source-ranges=0.0.0.0/0 --quiet || true
    fi
) &
(
    if ! gcloud compute firewall-rules describe allow-iap-ssh &>/dev/null; then
        gcloud compute firewall-rules create allow-iap-ssh \
            --network=mynetwork --direction=INGRESS --priority=1000 \
            --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 \
            --target-tags=iap-gce --quiet || true
    fi
) &
wait

# Convert mynetwork to custom mode
AUTO_MODE=$(gcloud compute networks describe mynetwork --format="value(autoCreateSubnetworks)" 2>/dev/null || echo "False")
if [ "$AUTO_MODE" = "True" ]; then
    echo "Converting mynetwork to custom subnet mode..."
    gcloud compute networks update mynetwork --switch-to-custom-subnet-mode --quiet
fi

# ==============================================================================
# 5. TASK 3: CREATE CUSTOM MODE NETWORKS (managementnet & privatenet)
# ==============================================================================
# 5.1 managementnet
echo "Checking custom network: managementnet..."
if ! gcloud compute networks describe managementnet &>/dev/null; then
    echo "Creating managementnet..."
    gcloud compute networks create managementnet --subnet-mode=custom --quiet
fi

if ! gcloud compute networks subnets describe managementsubnet-us --region="$REGION_1" &>/dev/null; then
    echo "Creating subnet managementsubnet-us in $REGION_1 (10.240.0.0/20)..."
    gcloud compute networks subnets create managementsubnet-us \
        --network=managementnet \
        --region="$REGION_1" \
        --range=10.240.0.0/20 --quiet
fi

if ! gcloud compute firewall-rules describe managementnet-allow-icmp-ssh-rdp &>/dev/null; then
    echo "Creating firewall rule managementnet-allow-icmp-ssh-rdp..."
    gcloud compute firewall-rules create managementnet-allow-icmp-ssh-rdp \
        --network=managementnet \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=icmp,tcp:22,tcp:3389 \
        --source-ranges=0.0.0.0/0 --quiet
fi

# 5.2 privatenet
echo "Checking custom network: privatenet..."
if ! gcloud compute networks describe privatenet &>/dev/null; then
    echo "Creating privatenet..."
    gcloud compute networks create privatenet --subnet-mode=custom --quiet
fi

if ! gcloud compute networks subnets describe privatesubnet-us --region="$REGION_1" &>/dev/null; then
    echo "Creating subnet privatesubnet-us in $REGION_1 (172.16.0.0/24)..."
    gcloud compute networks subnets create privatesubnet-us \
        --network=privatenet \
        --region="$REGION_1" \
        --range=172.16.0.0/24 --quiet
fi

if ! gcloud compute networks subnets describe privatesubnet-notus --region="$REGION_2" &>/dev/null; then
    echo "Creating subnet privatesubnet-notus in $REGION_2 (172.20.0.0/20)..."
    gcloud compute networks subnets create privatesubnet-notus \
        --network=privatenet \
        --region="$REGION_2" \
        --range=172.20.0.0/20 --quiet
fi

if ! gcloud compute firewall-rules describe privatenet-allow-icmp-ssh-rdp &>/dev/null; then
    echo "Creating firewall rule privatenet-allow-icmp-ssh-rdp..."
    gcloud compute firewall-rules create privatenet-allow-icmp-ssh-rdp \
        --network=privatenet \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=icmp,tcp:22,tcp:3389 \
        --source-ranges=0.0.0.0/0 --quiet
fi

# ==============================================================================
# 6. FAST PARALLEL PROVISIONING OF ALL 4 VM INSTANCES
# ==============================================================================
echo "Launching all 4 VM instances in parallel..."

(
    if ! gcloud compute instances describe mynet-us-vm --zone="$ZONE_1" &>/dev/null; then
        echo "Starting creation: mynet-us-vm ($ZONE_1)..."
        gcloud compute instances create mynet-us-vm \
            --zone="$ZONE_1" \
            --machine-type=e2-medium \
            --network=mynetwork \
            --tags=iap-gce \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --quiet
        echo "Finished creation: mynet-us-vm"
    fi
) &

(
    if ! gcloud compute instances describe mynet-notus-vm --zone="$ZONE_2" &>/dev/null; then
        echo "Starting creation: mynet-notus-vm ($ZONE_2)..."
        gcloud compute instances create mynet-notus-vm \
            --zone="$ZONE_2" \
            --machine-type=e2-medium \
            --network=mynetwork \
            --tags=iap-gce \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --quiet
        echo "Finished creation: mynet-notus-vm"
    fi
) &

(
    if ! gcloud compute instances describe managementnet-us-vm --zone="$ZONE_1" &>/dev/null; then
        echo "Starting creation: managementnet-us-vm ($ZONE_1)..."
        gcloud compute instances create managementnet-us-vm \
            --zone="$ZONE_1" \
            --machine-type=e2-micro \
            --network=managementnet \
            --subnet=managementsubnet-us \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --quiet
        echo "Finished creation: managementnet-us-vm"
    fi
) &

(
    if ! gcloud compute instances describe privatenet-us-vm --zone="$ZONE_1" &>/dev/null; then
        echo "Starting creation: privatenet-us-vm ($ZONE_1)..."
        gcloud compute instances create privatenet-us-vm \
            --zone="$ZONE_1" \
            --machine-type=e2-micro \
            --subnet=privatesubnet-us \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --boot-disk-size=10GB \
            --boot-disk-type=pd-standard \
            --boot-disk-device-name=privatenet-us-vm \
            --quiet
        echo "Finished creation: privatenet-us-vm"
    fi
) &

wait
echo "All 4 VM instances have finished provisioning!"

# ==============================================================================
# 7. VERIFICATION SUMMARY
# ==============================================================================
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "VPC Networks:"
gcloud compute networks list

echo ""
echo "Custom Subnets:"
gcloud compute networks subnets list --sort-by=NETWORK --filter="network:( mynetwork managementnet privatenet )"

echo ""
echo "VM Instances:"
gcloud compute instances list --sort-by=ZONE

# Display completion status
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                                   ║${NC}"
echo -e "${CYAN}║${GREEN}              [✓] LAB COMPLETED SUCCESSFULLY! [✓]                  ${CYAN}║${NC}"
echo -e "${CYAN}║                                                                   ║${NC}"
echo -e "${CYAN}║${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}║${NC}"
echo -e "${CYAN}║                                                                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
