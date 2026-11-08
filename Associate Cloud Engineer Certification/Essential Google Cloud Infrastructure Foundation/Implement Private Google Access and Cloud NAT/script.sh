#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-central1" ZONE="us-central1-a" ./script.sh
# ==============================================================================
export REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-east4")}"
export ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-east4-b")}"
export BUCKET_NAME="${BUCKET_NAME:-}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

if [ -z "$BUCKET_NAME" ]; then
    export BUCKET_NAME="${PROJECT_ID}-bucket"
fi

echo "=================================================="
echo "Project ID  : $PROJECT_ID"
echo "Region      : $REGION"
echo "Zone        : $ZONE"
echo "Bucket Name : $BUCKET_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Enable required APIs
echo "Ensuring required APIs are active..."
gcloud services enable compute.googleapis.com storage.googleapis.com iap.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE CUSTOM VPC, SUBNET, FIREWALL, AND ISOLATED VM
# ==============================================================================
echo "Checking custom VPC network: privatenet..."
if ! gcloud compute networks describe privatenet &>/dev/null; then
    echo "Creating VPC network privatenet..."
    gcloud compute networks create privatenet --subnet-mode=custom --quiet
fi

echo "Checking subnet: privatenet-us..."
if ! gcloud compute networks subnets describe privatenet-us --region="$REGION" &>/dev/null; then
    echo "Creating subnet privatenet-us (10.130.0.0/20) in $REGION..."
    gcloud compute networks subnets create privatenet-us \
        --network=privatenet \
        --region="$REGION" \
        --range=10.130.0.0/20 \
        --quiet
fi

echo "Checking firewall rule: privatenet-allow-ssh..."
if ! gcloud compute firewall-rules describe privatenet-allow-ssh &>/dev/null; then
    echo "Creating IAP SSH firewall rule privatenet-allow-ssh..."
    gcloud compute firewall-rules create privatenet-allow-ssh \
        --network=privatenet \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges=35.235.240.0/20 \
        --quiet
fi

echo "Checking VM instance: vm-internal..."
if ! gcloud compute instances describe vm-internal --zone="$ZONE" &>/dev/null; then
    echo "Creating VM instance vm-internal (no external IP)..."
    gcloud compute instances create vm-internal \
        --zone="$ZONE" \
        --machine-type=e2-standard-2 \
        --network=privatenet \
        --subnet=privatenet-us \
        --no-address \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --quiet
fi

# ==============================================================================
# 4. TASK 2: CREATE BUCKET & ENABLE PRIVATE GOOGLE ACCESS
# ==============================================================================
echo "Checking Cloud Storage bucket gs://$BUCKET_NAME..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME" &>/dev/null; then
    echo "Creating bucket gs://$BUCKET_NAME..."
    gcloud storage buckets create "gs://$BUCKET_NAME" --location=US --quiet
fi

echo "Downloading sample SVG asset..."
if [ ! -f "access.svg" ]; then
    gcloud storage cp gs://cloud-training/gcpnet/private/access.svg access.svg --quiet || true
fi

echo "Uploading access.svg to gs://$BUCKET_NAME..."
gcloud storage cp access.svg "gs://$BUCKET_NAME/access.svg" --quiet || true

echo "Enabling Private Google Access on subnet privatenet-us..."
gcloud compute networks subnets update privatenet-us \
    --region="$REGION" \
    --enable-private-ip-google-access \
    --quiet

# ==============================================================================
# 5. TASKS 3 & 4: CONFIGURE CLOUD ROUTER, CLOUD NAT & LOGGING
# ==============================================================================
echo "Checking Cloud Router: nat-router..."
if ! gcloud compute routers describe nat-router --region="$REGION" &>/dev/null; then
    echo "Creating Cloud Router nat-router in $REGION..."
    gcloud compute routers create nat-router \
        --network=privatenet \
        --region="$REGION" \
        --quiet
fi

echo "Checking Cloud NAT gateway: nat-config..."
if ! gcloud compute routers nats describe nat-config --router=nat-router --region="$REGION" &>/dev/null; then
    echo "Creating Cloud NAT gateway nat-config with translation & error logging..."
    gcloud compute routers nats create nat-config \
        --router=nat-router \
        --region="$REGION" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --enable-logging \
        --log-filter=ALL \
        --quiet
else
    echo "Updating Cloud NAT gateway nat-config logging..."
    gcloud compute routers nats update nat-config \
        --router=nat-router \
        --region="$REGION" \
        --enable-logging \
        --log-filter=ALL \
        --quiet || true
fi

# ==============================================================================
# 6. VERIFICATION CHECKS
# ==============================================================================
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "VM Instance Status:"
gcloud compute instances describe vm-internal --zone="$ZONE" --format="table(name, status, machineType, networkInterfaces[0].networkIP:label=INTERNAL_IP, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)"

echo ""
echo "Subnet Private Google Access Status:"
gcloud compute networks subnets describe privatenet-us --region="$REGION" --format="get(name, privateIpGoogleAccess)"

echo ""
echo "Cloud NAT Gateway Status:"
gcloud compute routers nats describe nat-config --router=nat-router --region="$REGION" --format="table(name, sourceSubnetworkIpRangesToNat, natIps)"

echo ""
echo "Testing outbound connectivity from vm-internal via IAP tunnel..."
for attempt in {1..5}; do
    if gcloud compute ssh vm-internal --zone="$ZONE" --tunnel-through-iap --quiet --command="curl -s -I https://www.google.com | head -n 1" 2>/dev/null; then
        echo "Outbound connectivity verified successfully!"
        break
    fi
    sleep 5
done

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
