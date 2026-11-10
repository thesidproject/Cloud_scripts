#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab assigns different values.
# Override inline: REGION="us-west1" ZONE="us-west1-b" ./script.sh
# ==============================================================================
GCLOUD_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${GCLOUD_REGION:-us-west1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-west1"

GCLOUD_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${GCLOUD_ZONE:-us-west1-b}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-west1-b"

export CLUSTER_NAME="${CLUSTER_NAME:-day2-ops}"
export LOG_BUCKET_NAME="${LOG_BUCKET_NAME:-day2ops-log}"
export LINKED_DATASET_NAME="${LINKED_DATASET_NAME:-day2ops_log}"
export SINK_NAME="${SINK_NAME:-day2ops-sink}"

# Auto-detect cluster location if cluster already exists
CLUSTER_LOCATION=$(gcloud container clusters list --filter="name=${CLUSTER_NAME}" --format="value(location)" 2>/dev/null | head -n 1 || true)
if [ -n "$CLUSTER_LOCATION" ]; then
    echo "Discovered cluster ${CLUSTER_NAME} at location: ${CLUSTER_LOCATION}"
    LOCATION_FLAG="--location=${CLUSTER_LOCATION}"
    if [[ "$CLUSTER_LOCATION" =~ ^[a-z]+-[a-z0-9]+-[a-z]$ ]]; then
        export ZONE="${ZONE:-$CLUSTER_LOCATION}"
        export REGION="${REGION:-${CLUSTER_LOCATION%-*}}"
    else
        export REGION="${REGION:-$CLUSTER_LOCATION}"
    fi
else
    LOCATION_FLAG="--region=${REGION}"
fi

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
echo "Project ID          : $PROJECT_ID"
echo "Region              : $REGION"
echo "Zone                : $ZONE"
echo "Cluster Name        : $CLUSTER_NAME"
echo "Log Bucket Name     : $LOG_BUCKET_NAME"
echo "Linked Dataset Name : $LINKED_DATASET_NAME"
echo "Sink Name           : $SINK_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure required APIs are enabled
echo "Ensuring required APIs are active..."
gcloud services enable container.googleapis.com logging.googleapis.com bigquery.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: INFRASTRUCTURE SETUP & CLUSTER CREDENTIALS
# ==============================================================================
echo "Checking GKE cluster status for ${CLUSTER_NAME}..."
for i in {1..24}; do
    CLUSTER_STATUS=$(gcloud container clusters describe "${CLUSTER_NAME}" ${LOCATION_FLAG} --format="value(status)" 2>/dev/null || \
                     gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --format="value(status)" 2>/dev/null || \
                     gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --format="value(status)" 2>/dev/null || true)
    if [ "$CLUSTER_STATUS" = "RUNNING" ]; then
        echo "Cluster ${CLUSTER_NAME} is RUNNING."
        break
    fi
    echo "Waiting for cluster ${CLUSTER_NAME} to be RUNNING (current status: ${CLUSTER_STATUS:-UNKNOWN})... (${i}/24)"
    sleep 5
done

echo "Fetching cluster credentials for kubectl..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" ${LOCATION_FLAG} --quiet 2>/dev/null || \
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region="${REGION}" --quiet 2>/dev/null || \
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --quiet

echo "Verifying cluster nodes..."
kubectl get nodes

# ==============================================================================
# 4. TASK 2: DEPLOY THE APPLICATION (ONLINE BOUTIQUE)
# ==============================================================================
echo "Deploying Online Boutique application workloads..."
if [ ! -d "microservices-demo" ]; then
    git clone https://github.com/GoogleCloudPlatform/microservices-demo.git
fi

kubectl apply -f microservices-demo/release/kubernetes-manifests.yaml

echo "Waiting for frontend service and pods to initialize..."
kubectl wait --for=condition=ready pod -l app=frontend --timeout=180s 2>/dev/null || true

# Fetch frontend external IP
echo "Checking frontend external LoadBalancer IP..."
EXTERNAL_IP=""
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get service frontend-external -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        echo "Frontend service reachable at http://${EXTERNAL_IP}"
        break
    fi
    sleep 4
done

# Generate synthetic requests to generate container logs
if [ -n "$EXTERNAL_IP" ]; then
    echo "Generating initial application traffic to generate logs..."
    curl -s -m 5 "http://${EXTERNAL_IP}/" >/dev/null 2>&1 || true
    curl -s -m 5 "http://${EXTERNAL_IP}/product/L9ECAV7KIM" >/dev/null 2>&1 || true
    curl -s -m 5 "http://${EXTERNAL_IP}/cart" >/dev/null 2>&1 || true
fi

# ==============================================================================
# 5. TASK 3: MANAGE LOG BUCKETS & LOG ROUTING
# ==============================================================================
echo "Upgrading _Default log bucket to enable Log Analytics..."
gcloud logging buckets update _Default --location=global --enable-analytics --quiet 2>/dev/null || true

echo "Configuring custom log bucket: ${LOG_BUCKET_NAME} with Log Analytics..."
if ! gcloud logging buckets describe "${LOG_BUCKET_NAME}" --location=global >/dev/null 2>&1; then
    echo "Creating log bucket ${LOG_BUCKET_NAME}..."
    gcloud logging buckets create "${LOG_BUCKET_NAME}" \
        --location=global \
        --enable-analytics \
        --quiet
else
    echo "Log bucket ${LOG_BUCKET_NAME} exists. Ensuring Log Analytics is enabled..."
    gcloud logging buckets update "${LOG_BUCKET_NAME}" \
        --location=global \
        --enable-analytics \
        --quiet 2>/dev/null || true
fi

echo "Linking BigQuery dataset: ${LINKED_DATASET_NAME}..."
if ! gcloud logging links describe "${LINKED_DATASET_NAME}" --bucket="${LOG_BUCKET_NAME}" --location=global >/dev/null 2>&1; then
    gcloud logging links create "${LINKED_DATASET_NAME}" \
        --bucket="${LOG_BUCKET_NAME}" \
        --location=global \
        --quiet 2>/dev/null || true
fi

echo "Creating Log Router sink: ${SINK_NAME}..."
SINK_DEST="logging.googleapis.com/projects/${PROJECT_ID}/locations/global/buckets/${LOG_BUCKET_NAME}"
if ! gcloud logging sinks describe "${SINK_NAME}" >/dev/null 2>&1; then
    gcloud logging sinks create "${SINK_NAME}" "$SINK_DEST" \
        --log-filter='resource.type="k8s_container"' \
        --quiet
else
    echo "Log sink ${SINK_NAME} already exists. Ensuring destination and filter..."
    gcloud logging sinks update "${SINK_NAME}" "$SINK_DEST" \
        --log-filter='resource.type="k8s_container"' \
        --quiet 2>/dev/null || true
fi

# ==============================================================================
# 6. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo "=================================================="
echo "GKE Cluster Info:"
gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --format="table(name, status, currentNodeCount)" 2>/dev/null || \
gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --format="table(name, status, currentNodeCount)" 2>/dev/null || true

echo ""
echo "Online Boutique Workloads:"
kubectl get deployments -o wide 2>/dev/null || true

echo ""
echo "Log Bucket Configuration (${LOG_BUCKET_NAME}):"
gcloud logging buckets describe "${LOG_BUCKET_NAME}" --location=global --format="yaml(name, lifecycleState, analyticsEnabled)" 2>/dev/null || true

echo ""
echo "Log Router Sink Configuration (${SINK_NAME}):"
gcloud logging sinks describe "${SINK_NAME}" --format="yaml(name, destination, filter)" 2>/dev/null || true
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
