#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different regions/zones.
# Override inline: REGION="us-east4" ZONE_A="us-east4-a" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east4}}"
[ "$REGION" = "(unset)" ] && export REGION="us-east4"
export ZONE_A="${ZONE_A:-${REGION}-a}"
export ZONE_B="${ZONE_B:-${REGION}-b}"
export ZONE_C="${ZONE_C:-${REGION}-c}"
export NETWORK="${NETWORK:-my-internal-app}"
export SUBNET_A="${SUBNET_A:-subnet-a}"
export SUBNET_B="${SUBNET_B:-subnet-b}"
export ILB_STATIC_IP="${ILB_STATIC_IP:-10.10.30.5}"
export UTILITY_IP="${UTILITY_IP:-10.10.20.50}"

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
echo "Primary Region   : $REGION"
echo "Zones            : $ZONE_A (Utility), $ZONE_B (IG1), $ZONE_C (IG2)"
echo "Network / Subnets: $NETWORK ($SUBNET_A, $SUBNET_B)"
echo "ILB Static IP    : $ILB_STATIC_IP"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE_A" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CONFIGURE INTERNAL TRAFFIC AND HEALTH CHECK FIREWALL RULES
# ==============================================================================
echo "Checking firewall rule: fw-allow-lb-access..."
if ! gcloud compute firewall-rules describe fw-allow-lb-access --quiet >/dev/null 2>&1; then
    echo "Creating firewall rule fw-allow-lb-access..."
    gcloud compute firewall-rules create fw-allow-lb-access \
        --network="$NETWORK" \
        --action=ALLOW \
        --direction=INGRESS \
        --source-ranges=10.10.0.0/16 \
        --target-tags=backend-service \
        --rules=all \
        --quiet
    echo "Firewall rule fw-allow-lb-access created."
else
    echo "Firewall rule fw-allow-lb-access already exists."
fi

echo "Checking firewall rule: fw-allow-health-checks..."
if ! gcloud compute firewall-rules describe fw-allow-health-checks --quiet >/dev/null 2>&1; then
    echo "Creating firewall rule fw-allow-health-checks..."
    gcloud compute firewall-rules create fw-allow-health-checks \
        --network="$NETWORK" \
        --action=ALLOW \
        --direction=INGRESS \
        --source-ranges=130.211.0.0/22,35.191.0.0/16 \
        --target-tags=backend-service \
        --rules=tcp:80 \
        --quiet
    echo "Firewall rule fw-allow-health-checks created."
else
    echo "Firewall rule fw-allow-health-checks already exists."
fi

# ==============================================================================
# 4. TASK 2: CREATE A NAT CONFIGURATION USING CLOUD ROUTER
# ==============================================================================
ROUTER_NAME="nat-router-${REGION}"
echo "Checking Cloud Router: $ROUTER_NAME ($REGION)..."
if ! gcloud compute routers describe "$ROUTER_NAME" --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating Cloud Router $ROUTER_NAME..."
    gcloud compute routers create "$ROUTER_NAME" \
        --network="$NETWORK" \
        --region="$REGION" \
        --quiet
else
    echo "Cloud Router $ROUTER_NAME already exists."
fi

echo "Checking Cloud NAT Gateway: nat-config ($REGION)..."
if ! gcloud compute routers nats describe nat-config --router="$ROUTER_NAME" --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating Cloud NAT Gateway nat-config..."
    gcloud compute routers nats create nat-config \
        --router="$ROUTER_NAME" \
        --region="$REGION" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --quiet
    echo "Cloud NAT Gateway nat-config created."
else
    echo "Cloud NAT Gateway nat-config already exists."
fi

# ==============================================================================
# 5. TASK 3: RE-RUN STARTUP SCRIPTS & CREATE UTILITY TEST VM
# ==============================================================================
echo "Triggering startup script on backend instances via rolling restart..."
gcloud compute instance-groups managed rolling-action restart instance-group-1 --zone="$ZONE_B" --quiet 2>/dev/null || true
gcloud compute instance-groups managed rolling-action restart instance-group-2 --zone="$ZONE_C" --quiet 2>/dev/null || true

echo "Checking utility testing VM: utility-vm ($ZONE_A)..."
if ! gcloud compute instances describe utility-vm --zone="$ZONE_A" --quiet >/dev/null 2>&1; then
    echo "Creating utility-vm in $ZONE_A (IP: $UTILITY_IP)..."
    gcloud compute instances create utility-vm \
        --zone="$ZONE_A" \
        --machine-type=e2-medium \
        --network="$NETWORK" \
        --subnet="$SUBNET_A" \
        --private-network-ip="$UTILITY_IP" \
        --no-address \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --quiet
    echo "Instance utility-vm created."
else
    echo "Instance utility-vm already exists."
fi

# ==============================================================================
# 6. TASK 4: CONFIGURE THE INTERNAL NETWORK LOAD BALANCER (my-ilb)
# ==============================================================================
echo "Checking TCP health check: my-ilb-health-check..."
if ! gcloud compute health-checks describe my-ilb-health-check --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating regional health check my-ilb-health-check..."
    gcloud compute health-checks create tcp my-ilb-health-check \
        --region="$REGION" \
        --port=80 \
        --check-interval=10s \
        --timeout=5s \
        --healthy-threshold=2 \
        --unhealthy-threshold=3 \
        --quiet
else
    echo "Health check my-ilb-health-check already exists."
fi

echo "Checking static internal IP reservation: my-ilb-ip ($ILB_STATIC_IP)..."
if ! gcloud compute addresses describe my-ilb-ip --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Reserving static internal IP $ILB_STATIC_IP in $SUBNET_B..."
    gcloud compute addresses create my-ilb-ip \
        --region="$REGION" \
        --subnet="$SUBNET_B" \
        --addresses="$ILB_STATIC_IP" \
        --quiet
else
    echo "Static internal IP my-ilb-ip already exists."
fi

echo "Checking regional backend service: my-ilb..."
if ! gcloud compute backend-services describe my-ilb --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating backend service my-ilb..."
    gcloud compute backend-services create my-ilb \
        --region="$REGION" \
        --load-balancing-scheme=INTERNAL \
        --protocol=TCP \
        --health-checks=my-ilb-health-check \
        --health-checks-region="$REGION" \
        --quiet
else
    echo "Backend service my-ilb already exists."
fi

echo "Attaching backend instance groups to my-ilb..."
EXISTING_BACKENDS=$(gcloud compute backend-services describe my-ilb --region="$REGION" --format="value(backends[].group)" 2>/dev/null || true)

if ! echo "$EXISTING_BACKENDS" | grep -q "instance-group-1"; then
    echo "Adding instance-group-1 backend ($ZONE_B)..."
    gcloud compute backend-services add-backend my-ilb \
        --region="$REGION" \
        --instance-group=instance-group-1 \
        --instance-group-zone="$ZONE_B" \
        --quiet
fi

if ! echo "$EXISTING_BACKENDS" | grep -q "instance-group-2"; then
    echo "Adding instance-group-2 backend ($ZONE_C)..."
    gcloud compute backend-services add-backend my-ilb \
        --region="$REGION" \
        --instance-group=instance-group-2 \
        --instance-group-zone="$ZONE_C" \
        --quiet
fi

echo "Checking internal forwarding rule: my-ilb-forwarding-rule..."
if ! gcloud compute forwarding-rules describe my-ilb-forwarding-rule --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating forwarding rule my-ilb-forwarding-rule..."
    gcloud compute forwarding-rules create my-ilb-forwarding-rule \
        --region="$REGION" \
        --network="$NETWORK" \
        --subnet="$SUBNET_B" \
        --load-balancing-scheme=INTERNAL \
        --backend-service=my-ilb \
        --address=my-ilb-ip \
        --ports=80 \
        --quiet
    echo "Forwarding rule my-ilb-forwarding-rule created."
else
    echo "Forwarding rule my-ilb-forwarding-rule already exists."
fi

# ==============================================================================
# 7. TASK 5: VERIFICATION SUMMARY & TEST CONNECTIVITY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Firewall Rules:"
gcloud compute firewall-rules list --filter="network:$NETWORK" --format="table(name,targetTags,sourceRanges,allowed)"

echo ""
echo "Cloud NAT:"
gcloud compute routers nats list --router="$ROUTER_NAME" --region="$REGION" --format="table(name,router)"

echo ""
echo "Reserved Static IP:"
gcloud compute addresses describe my-ilb-ip --region="$REGION" --format="table(name,address,subnetwork,status)"

echo ""
echo "Load Balancer Forwarding Rule:"
gcloud compute forwarding-rules list --regions="$REGION" --filter="name:my-ilb" --format="table(name,IPAddress,backendService,loadBalancingScheme)"

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
