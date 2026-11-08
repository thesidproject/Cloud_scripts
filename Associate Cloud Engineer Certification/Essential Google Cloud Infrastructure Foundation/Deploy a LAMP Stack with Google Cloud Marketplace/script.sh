#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: ZONE="us-central1-a" ./script.sh
# ==============================================================================
export ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-central1-b")}"
export REGION="${REGION:-${ZONE%-*}}"
export INSTANCE_NAME="${INSTANCE_NAME:-lamp-1-vm}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-lamp-1}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
# Automatically detect Project ID
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID      : $PROJECT_ID"
echo "Zone            : $ZONE"
echo "Deployment Name : $DEPLOYMENT_NAME"
echo "Instance Name   : $INSTANCE_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure Compute Engine API is active
echo "Ensuring Compute Engine API is active..."
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# Ensure HTTP firewall rule exists
echo "Verifying HTTP firewall access (port 80)..."
if ! gcloud compute firewall-rules list --filter="allowed.IPProtocol:tcp AND allowed.ports:80" --format="value(name)" 2>/dev/null | grep -q .; then
    gcloud compute firewall-rules create allow-http-80 \
        --network=default \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server --quiet || true
fi

# ==============================================================================
# 3. TASK 1: MARKETPLACE DEPLOYMENT (CONSOLE ACTION REQUIRED)
# ==============================================================================
# Display instructions upfront BEFORE polling starts
echo ""
echo "=================================================================="
echo "ACTION REQUIRED: Deploy LAMP Stack in the Google Cloud Console"
echo "=================================================================="
echo "1. In Google Cloud Console, open Navigation menu (☰) > Marketplace."
echo "2. Search for: LAMP Stack on Debian12 (Apps4Rent LLC)."
echo "3. Click 'Get Started' -> 'Deploy'."
echo "   - Zone         : $ZONE"
echo "   - Machine Type : E2 series, e2-medium"
echo "4. Click 'Deploy'."
echo "=================================================================="
echo "Now polling for $INSTANCE_NAME to be RUNNING..."
echo ""

VM_READY=false
for i in {1..40}; do
    STATUS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="get(status)" 2>/dev/null || true)
    if [ "$STATUS" = "RUNNING" ]; then
        VM_READY=true
        echo ""
        echo "Detected running VM instance: $INSTANCE_NAME!"
        break
    fi
    echo "Waiting for Marketplace deployment ($INSTANCE_NAME)... (Attempt $i/40)"
    sleep 5
done

if [ "$VM_READY" = false ]; then
    echo ""
    echo "Error: Timed out waiting for $INSTANCE_NAME. Please ensure it was deployed in zone $ZONE and re-run."
    exit 1
fi

# ==============================================================================
# 4. TASK 2: VERIFY DEPLOYMENT & HTTP WEB SERVER
# ==============================================================================
echo "Fetching external IP address for $INSTANCE_NAME..."
VM_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

if [ -z "$VM_IP" ]; then
    echo "Error: Unable to fetch external IP for $INSTANCE_NAME."
    exit 1
fi

echo "VM External IP: $VM_IP"
echo "Testing HTTP response from http://$VM_IP..."

HTTP_OK=false
for i in {1..12}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$VM_IP" || true)
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        HTTP_OK=true
        echo "HTTP check passed! Server responded with status code: $HTTP_CODE"
        break
    fi
    echo "Attempt $i/12: Web server initializing, retrying in 5 seconds..."
    sleep 5
done

# ==============================================================================
# 5. VERIFICATION SUMMARY
# ==============================================================================
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="table(name, status, machineType, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)"

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$HTTP_OK" = true ]; then
    echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}║${GREEN}              [✓] LAB COMPLETED SUCCESSFULLY! [✓]                  ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}║${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
else
    echo ""
    echo "Notice: Web server is still starting up. Please verify http://$VM_IP in your browser."
fi
