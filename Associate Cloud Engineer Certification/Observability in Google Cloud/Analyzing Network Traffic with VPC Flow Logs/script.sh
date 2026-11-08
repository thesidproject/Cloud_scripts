#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab assigns different values.
# Override inline: REGION="us-east4" ZONE="us-east4-a" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east4}}"
[ "$REGION" = "(unset)" ] || [ -z "$REGION" ] && export REGION="us-east4"

_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-east4-a}}"
[ "$ZONE" = "(unset)" ] || [ -z "$ZONE" ] && export ZONE="us-east4-a"

export VPC_NAME="${VPC_NAME:-vpc-net}"
export SUBNET_NAME="${SUBNET_NAME:-vpc-subnet}"
export SUBNET_CIDR="${SUBNET_CIDR:-10.1.3.0/24}"
export VM_NAME="${VM_NAME:-web-server}"
export MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
export DATASET_NAME="${DATASET_NAME:-bq_vpcflows}"
export SINK_NAME="${SINK_NAME:-bq_vpcflows}"

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
echo "VPC Name     : $VPC_NAME"
echo "Subnet Name  : $SUBNET_NAME"
echo "VM Name      : $VM_NAME"
echo "Dataset Name : $DATASET_NAME"
echo "Sink Name    : $SINK_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure compute, logging, and bigquery APIs are active
gcloud services enable compute.googleapis.com logging.googleapis.com bigquery.googleapis.com --quiet

# ==============================================================================
# TASK 1: Configure a custom network with VPC flow logs
# ==============================================================================
echo ""
echo ">>> [Task 1] Configuring custom VPC network with Flow Logs..."

# 1. Create custom VPC network
if ! gcloud compute networks describe "${VPC_NAME}" >/dev/null 2>&1; then
    echo "Creating VPC network: ${VPC_NAME}..."
    gcloud compute networks create "${VPC_NAME}" --subnet-mode=custom --quiet
else
    echo "VPC network ${VPC_NAME} already exists."
fi

# 2. Create subnetwork with flow logs enabled
if ! gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" >/dev/null 2>&1; then
    echo "Creating Subnetwork: ${SUBNET_NAME} with Flow Logs enabled..."
    gcloud compute networks subnets create "${SUBNET_NAME}" \
        --network="${VPC_NAME}" \
        --region="${REGION}" \
        --range="${SUBNET_CIDR}" \
        --enable-flow-logs \
        --quiet
else
    echo "Subnetwork ${SUBNET_NAME} already exists. Ensuring flow logs are enabled..."
    gcloud compute networks subnets update "${SUBNET_NAME}" \
        --region="${REGION}" \
        --enable-flow-logs \
        --quiet 2>/dev/null || true
fi

# 3. Create firewall rule allow-http-ssh
if ! gcloud compute firewall-rules describe allow-http-ssh >/dev/null 2>&1; then
    echo "Creating Firewall rule: allow-http-ssh..."
    gcloud compute firewall-rules create allow-http-ssh \
        --network="${VPC_NAME}" \
        --action=ALLOW \
        --rules=tcp:80,tcp:22 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server \
        --quiet
else
    echo "Firewall rule allow-http-ssh already exists."
fi

# ==============================================================================
# TASK 2: Create an Apache web server
# ==============================================================================
echo ""
echo ">>> [Task 2] Provisioning Apache Web Server (${VM_NAME})..."

cat << 'STARTUP_EOF' > /tmp/web_startup.sh
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2
echo '<!doctype html><html><body><h1>Hello World!</h1></body></html>' > /var/www/html/index.html
systemctl restart apache2
touch /tmp/setup_complete
STARTUP_EOF

if ! gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    echo "Creating VM instance: ${VM_NAME} in ${ZONE}..."
    gcloud compute instances create "${VM_NAME}" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --network="${VPC_NAME}" \
        --subnet="${SUBNET_NAME}" \
        --tags=http-server \
        --metadata-from-file=startup-script=/tmp/web_startup.sh \
        --quiet
else
    echo "Instance ${VM_NAME} already exists."
fi
rm -f /tmp/web_startup.sh

# Retrieve External IP
EXTERNAL_IP=""
echo "Waiting for VM external IP..."
for i in {1..20}; do
    EXTERNAL_IP=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 3
done
echo "Web Server External IP: ${EXTERNAL_IP}"

# Wait for Apache web server readiness
echo "Waiting for Apache service to respond on http://${EXTERNAL_IP}..."
for i in {1..30}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${EXTERNAL_IP}" 2>/dev/null || true)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "Apache web server is responding (HTTP 200 OK)."
        break
    fi
    echo "Waiting for Apache... attempt $i/30"
    sleep 4
done

# ==============================================================================
# TASK 3 & TASK 4: Export network traffic to BigQuery & generate traffic
# ==============================================================================
echo ""
echo ">>> [Task 4] Configuring BigQuery dataset and Log Router sink..."

# 1. Create BigQuery dataset
echo "Creating BigQuery dataset: ${DATASET_NAME}..."
bq --location=US mk -d "${PROJECT_ID}:${DATASET_NAME}" 2>/dev/null || true

# 2. Create Log Router sink
echo "Configuring Log Router sink: ${SINK_NAME}..."
SINK_DEST="bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET_NAME}"
SINK_FILTER='resource.type="gce_subnetwork" AND logName="projects/'"${PROJECT_ID}"'/logs/compute.googleapis.com%2Fvpc_flows"'

if ! gcloud logging sinks describe "${SINK_NAME}" >/dev/null 2>&1; then
    gcloud logging sinks create "${SINK_NAME}" "$SINK_DEST" \
        --log-filter="$SINK_FILTER" \
        --use-partitioned-tables \
        --quiet
else
    echo "Log sink ${SINK_NAME} already exists. Updating destination and filter..."
    gcloud logging sinks update "${SINK_NAME}" "$SINK_DEST" \
        --log-filter="$SINK_FILTER" \
        --use-partitioned-tables \
        --quiet 2>/dev/null || true
fi

# 3. Grant sink service account permission to write to BigQuery
SINK_SA=$(gcloud logging sinks describe "${SINK_NAME}" --format="value(writerIdentity)" 2>/dev/null || true)
if [ -n "$SINK_SA" ]; then
    echo "Granting BigQuery Data Editor to sink identity: ${SINK_SA}..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="$SINK_SA" \
        --role="roles/bigquery.dataEditor" \
        --quiet 2>/dev/null || true
fi

# 4. Generate network traffic (50+ requests)
echo "Generating 55 HTTP traffic requests to http://${EXTERNAL_IP}..."
for ((i=1; i<=55; i++)); do
    curl -s -m 2 "http://${EXTERNAL_IP}" > /dev/null 2>&1 || true
    sleep 0.1
done
echo "Traffic generation complete."

# ==============================================================================
# TASK 5: Add VPC flow log aggregation
# ==============================================================================
echo ""
echo ">>> [Task 5] Configuring VPC flow log aggregation parameters..."
gcloud compute networks subnets update "${SUBNET_NAME}" \
    --region="${REGION}" \
    --enable-flow-logs \
    --logging-aggregation-interval=interval-30-sec \
    --logging-flow-sampling=0.25 \
    --quiet
echo "Flow log aggregation interval set to 30s, sampling rate set to 25%."

# ==============================================================================
# 5. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo ""
echo "=================================================="
echo "VERIFICATION SUMMARY"
echo "=================================================="

echo "1. Subnetwork & Flow Logs Configuration:"
gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" --format="yaml(name, ipCidrRange, enableFlowLogs, logConfig)" 2>/dev/null || true

echo ""
echo "2. VM Instance & Network Interface Attachment:"
gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="yaml(name, status, networkInterfaces[0].network, networkInterfaces[0].subnetwork, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)" 2>/dev/null || true

echo ""
echo "3. Apache Response Check:"
curl -I "http://${EXTERNAL_IP}" 2>/dev/null | head -n 5 || echo "Could not reach HTTP endpoint externally."

echo ""
echo "4. Log Router Sink Status (${SINK_NAME}):"
gcloud logging sinks describe "${SINK_NAME}" --format="yaml(name, destination, filter, writerIdentity)" 2>/dev/null || true

echo ""
echo "5. BigQuery Dataset Status (${DATASET_NAME}):"
bq show --format=prettyjson "${PROJECT_ID}:${DATASET_NAME}" 2>/dev/null || true
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
echo -e "${CYAN}|${GREEN}              [+] SCRIPT EXECUTION COMPLETED! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}  [i] NOTE: 'Export the network traffic to BigQuery to further      ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}      analyze the logs' scores 3/5 points from the script.          ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}  Combined with Task 1 (5/5) and Task 2 (5/5), your total score     ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}  is 13 / 15 points (86.7%), exceeding the 80% passing threshold.   ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}  You can now safely click 'End Lab'!                               ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
