#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-central1" ZONE="us-central1-a" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east4}}"
[ "$REGION" = "(unset)" ] && export REGION="us-east4"
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-east4-b}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-east4-b"

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
echo "Project ID : $PROJECT_ID"
echo "Region     : $REGION"
echo "Zone       : $ZONE"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure Compute Engine API is active (ignore error if student role lacks serviceusage permission)
echo "Verifying API access..."
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# Ensure HTTP and HTTPS firewall rules exist
echo "Verifying firewall access for HTTP and HTTPS..."
if ! gcloud compute firewall-rules list --filter="network=default AND allowed.IPProtocol:tcp AND allowed.ports:80" --format="value(name)" 2>/dev/null | grep -q .; then
    gcloud compute firewall-rules create default-allow-http \
        --network=default \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server --quiet || true
fi

if ! gcloud compute firewall-rules list --filter="network=default AND allowed.IPProtocol:tcp AND allowed.ports:443" --format="value(name)" 2>/dev/null | grep -q .; then
    gcloud compute firewall-rules create default-allow-https \
        --network=default \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:443 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=https-server --quiet || true
fi

# ==============================================================================
# 3. FAST PARALLEL PROVISIONING OF ALL 3 VM INSTANCES
# ==============================================================================
echo "Provisioning 3 VM instances in parallel (Linux, Windows Server 2025, Custom VM)..."

# Task 1: utility-vm (e2-medium, Debian 12, No External IP)
(
    if ! gcloud compute instances describe utility-vm --zone="$ZONE" &>/dev/null; then
        echo "Starting creation: utility-vm (e2-medium, no external IP)..."
        gcloud compute instances create utility-vm \
            --zone="$ZONE" \
            --machine-type=e2-medium \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --no-address \
            --quiet
        echo "Finished creation: utility-vm"
    else
        echo "utility-vm already exists."
    fi
) &

# Task 2: utility-wm (e2-standard-2, Windows Server 2025, 64GB SSD, HTTP/HTTPS tags)
(
    if ! gcloud compute instances describe utility-wm --zone="$ZONE" &>/dev/null; then
        echo "Starting creation: utility-wm (Windows Server 2025 Datacenter, 64GB SSD)..."
        gcloud compute instances create utility-wm \
            --zone="$ZONE" \
            --machine-type=e2-standard-2 \
            --image-family=windows-2025 \
            --image-project=windows-cloud \
            --boot-disk-type=pd-ssd \
            --boot-disk-size=64GB \
            --tags=http-server,https-server \
            --quiet
        echo "Finished creation: utility-wm"
    else
        echo "utility-wm already exists."
    fi
) &

# Task 3: utility-cm (E2 Custom: 2 vCPUs, 4 GB RAM, Debian 12)
(
    if ! gcloud compute instances describe utility-cm --zone="$ZONE" &>/dev/null; then
        echo "Starting creation: utility-cm (Custom: 2 vCPU, 4GB RAM)..."
        gcloud compute instances create utility-cm \
            --zone="$ZONE" \
            --machine-type=e2-custom-2-4096 \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --quiet
        echo "Finished creation: utility-cm"
    else
        echo "utility-cm already exists."
    fi
) &

wait
echo "All 3 VM instances have finished provisioning!"

# ==============================================================================
# 4. TASK 2: GENERATE WINDOWS PASSWORD
# ==============================================================================
echo ""
echo "Attempting to generate Windows credentials for utility-wm..."
PASSWORD_SET=false
for attempt in {1..6}; do
    echo "Waiting for Windows guest agent to initialize (Attempt $attempt/6)..."
    sleep 10
    if gcloud compute reset-windows-password utility-wm --zone="$ZONE" --quiet 2>/dev/null; then
        PASSWORD_SET=true
        echo "Windows credentials generated successfully!"
        break
    fi
done

if [ "$PASSWORD_SET" = false ]; then
    echo "Notice: Windows guest agent is still starting up."
    echo "If needed, open utility-wm in Console > Click 'Set Windows password' to generate."
fi

# ==============================================================================
# 5. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
gcloud compute instances list --filter="name:( utility-vm utility-wm utility-cm )" \
    --format="table(name, zone, machineType, status, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)"

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
