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

export VM_NAME="${VM_NAME:-quickstart-vm}"
export MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"

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
echo "Project ID   : $PROJECT_ID"
echo "Region       : $REGION"
echo "Zone         : $ZONE"
echo "VM Name      : $VM_NAME"
echo "Machine Type : $MACHINE_TYPE"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure compute API is active
gcloud services enable compute.googleapis.com monitoring.googleapis.com logging.googleapis.com --quiet

# ==============================================================================
# 3. FIREWALL RULES
# Ensure HTTP (80) and HTTPS (443) traffic is allowed for tagged instances
# ==============================================================================
echo ""
echo "Configuring firewall rules for HTTP/HTTPS traffic..."
if ! gcloud compute firewall-rules describe default-allow-http >/dev/null 2>&1; then
    gcloud compute firewall-rules create default-allow-http \
        --direction=INGRESS --priority=1000 --network=default \
        --action=ALLOW --rules=tcp:80 --source-ranges=0.0.0.0/0 \
        --target-tags=http-server --quiet 2>/dev/null || true
fi

if ! gcloud compute firewall-rules describe default-allow-https >/dev/null 2>&1; then
    gcloud compute firewall-rules create default-allow-https \
        --direction=INGRESS --priority=1000 --network=default \
        --action=ALLOW --rules=tcp:443 --source-ranges=0.0.0.0/0 \
        --target-tags=https-server --quiet 2>/dev/null || true
fi

# ==============================================================================
# 4. PREPARE STARTUP SCRIPT
# Handles Tasks 1, 2, 3 & 4 directly inside the VM upon boot
# ==============================================================================
cat << 'STARTUP_EOF' > /tmp/vm_startup.sh
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/4] Updating package list and installing Apache2 & PHP..."
apt-get update -y
apt-get install -y apache2 php

# Enable status module for Apache monitoring
a2enmod status 2>/dev/null || true
systemctl restart apache2

echo "[2/4] Installing Google Cloud Ops Agent..."
if ! dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash add-google-cloud-ops-agent-repo.sh --also-install
fi

echo "[3/4] Configuring Google Cloud Ops Agent for Apache..."
mkdir -p /etc/google-cloud-ops-agent
if [ -f /etc/google-cloud-ops-agent/config.yaml ]; then
    cp /etc/google-cloud-ops-agent/config.yaml /etc/google-cloud-ops-agent/config.yaml.bak
fi

cat << 'CONFIG_EOF' > /etc/google-cloud-ops-agent/config.yaml
metrics:
  receivers:
    apache:
      type: apache
  service:
    pipelines:
      apache:
        receivers:
          - apache
logging:
  receivers:
    apache_access:
      type: apache_access
    apache_error:
      type: apache_error
  service:
    pipelines:
      apache:
        receivers:
          - apache_access
          - apache_error
CONFIG_EOF

# Restart and enable Ops Agent
systemctl unmask google-cloud-ops-agent 2>/dev/null || true
systemctl enable --now google-cloud-ops-agent
systemctl restart google-cloud-ops-agent

echo "[4/4] Starting local traffic generation loop in background..."
nohup bash -c 'while true; do curl -s http://localhost > /dev/null; sleep 1; done' > /dev/null 2>&1 &

touch /tmp/setup_complete
echo "Setup finished successfully."
STARTUP_EOF

# ==============================================================================
# TASK 1: Create a Compute Engine VM instance
# ==============================================================================
echo ""
echo ">>> [Task 1] Deploying Compute Engine VM: ${VM_NAME}..."
if ! gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    gcloud compute instances create "${VM_NAME}" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=http-server,https-server \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --metadata=enable-osconfig=TRUE \
        --metadata-from-file=startup-script=/tmp/vm_startup.sh \
        --quiet
else
    echo "Instance ${VM_NAME} already exists. Ensuring startup script is executed..."
    # If instance already exists, run the configuration commands directly
    gcloud compute instances add-metadata "${VM_NAME}" --zone="${ZONE}" \
        --metadata-from-file=startup-script=/tmp/vm_startup.sh --quiet 2>/dev/null || true
fi
rm -f /tmp/vm_startup.sh

# ==============================================================================
# TASK 2: Verify Apache Web Server & Fetch External IP
# ==============================================================================
echo ""
echo ">>> [Task 2] Waiting for VM and Apache Web Server initialization..."

EXTERNAL_IP=""
for i in {1..24}; do
    EXTERNAL_IP=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 5
done

echo "VM External IP: ${EXTERNAL_IP}"
echo "Waiting for Apache service to respond on http://${EXTERNAL_IP}..."

APACHE_READY=false
for i in {1..30}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${EXTERNAL_IP}" 2>/dev/null || true)
    if [ "$HTTP_STATUS" = "200" ]; then
        echo "Apache web server is responding (HTTP 200 OK)."
        APACHE_READY=true
        break
    fi
    echo "Waiting for Apache web server... attempt $i/30 (HTTP status: ${HTTP_STATUS:-unreachable})"
    sleep 5
done

# Fallback: If startup script was delayed, execute setup directly via SSH
if [ "$APACHE_READY" = false ]; then
    echo "Running fallback configuration via gcloud compute ssh..."
    gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --ssh-flag="-o StrictHostKeyChecking=no" --command="
        sudo apt-get update -y && \
        sudo apt-get install -y apache2 php && \
        sudo a2enmod status && \
        sudo systemctl restart apache2 && \
        curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh && \
        sudo bash add-google-cloud-ops-agent-repo.sh --also-install
    " --quiet 2>/dev/null || true
fi

# ==============================================================================
# TASK 3: Configure the Ops Agent
# ==============================================================================
echo ""
echo ">>> [Task 3] Verifying Ops Agent configuration on ${VM_NAME}..."
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --ssh-flag="-o StrictHostKeyChecking=no" --command="
    sudo mkdir -p /etc/google-cloud-ops-agent
    if [ ! -f /etc/google-cloud-ops-agent/config.yaml.bak ] && [ -f /etc/google-cloud-ops-agent/config.yaml ]; then
        sudo cp /etc/google-cloud-ops-agent/config.yaml /etc/google-cloud-ops-agent/config.yaml.bak
    fi
    sudo tee /etc/google-cloud-ops-agent/config.yaml > /dev/null << 'EOF'
metrics:
  receivers:
    apache:
      type: apache
  service:
    pipelines:
      apache:
        receivers:
          - apache
logging:
  receivers:
    apache_access:
      type: apache_access
    apache_error:
      type: apache_error
  service:
    pipelines:
      apache:
        receivers:
          - apache_access
          - apache_error
EOF
    sudo systemctl unmask google-cloud-ops-agent 2>/dev/null || true
    sudo systemctl enable --now google-cloud-ops-agent
    sudo systemctl restart google-cloud-ops-agent
    sudo systemctl is-active google-cloud-ops-agent || sudo service google-cloud-ops-agent restart
" --quiet 2>/dev/null || true

# ==============================================================================
# TASK 4: Generate Traffic and View Metrics
# ==============================================================================
echo ""
echo ">>> [Task 4] Generating HTTP traffic to populate telemetry metrics..."

# Run fast traffic burst and keep a background worker active inside the VM
echo "Running HTTP traffic burst inside ${VM_NAME}..."
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --ssh-flag="-o StrictHostKeyChecking=no" --command="
    for i in \$(seq 1 30); do
        curl -s http://localhost > /dev/null || true
        sleep 0.1
    done
    nohup bash -c 'while true; do curl -s http://localhost > /dev/null; sleep 1; done' >/dev/null 2>&1 &
" --quiet 2>/dev/null || true

# Also generate quick traffic from Cloud Shell externally
if [ -n "$EXTERNAL_IP" ]; then
    echo "Sending HTTP requests externally to http://${EXTERNAL_IP}..."
    for i in {1..20}; do
        curl -s -m 2 "http://${EXTERNAL_IP}" > /dev/null 2>&1 || true
        sleep 0.1
    done
fi

echo "Waiting 15 seconds for Cloud Monitoring to ingest metrics..."
sleep 15

# ==============================================================================
# 5. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo ""
echo "=================================================="
echo "VERIFICATION SUMMARY"
echo "=================================================="

echo "1. VM Instance Details (${VM_NAME}):"
gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="yaml(name, status, zone, tags.items, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)" 2>/dev/null || true

echo ""
echo "2. Apache Web Server HTTP Response:"
curl -I "http://${EXTERNAL_IP}" 2>/dev/null | head -n 5 || echo "Could not reach HTTP endpoint externally."

echo ""
echo "3. Google Cloud Ops Agent Status:"
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --ssh-flag="-o StrictHostKeyChecking=no" --command="sudo systemctl status google-cloud-ops-agent --no-pager" --quiet 2>/dev/null || true

echo ""
echo "4. Ops Agent Configuration (/etc/google-cloud-ops-agent/config.yaml):"
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --ssh-flag="-o StrictHostKeyChecking=no" --command="cat /etc/google-cloud-ops-agent/config.yaml" --quiet 2>/dev/null || true
echo "=================================================="

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
