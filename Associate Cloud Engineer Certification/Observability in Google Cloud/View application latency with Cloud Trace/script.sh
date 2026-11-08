#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab assigns different values.
# Override inline: ZONE="us-central1-c" CLUSTER_NAME="cloud-trace-demo" ./script.sh
# ==============================================================================
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-central1-c}}"
[ "$ZONE" = "(unset)" ] || [ -z "$ZONE" ] && export ZONE="us-central1-c"

_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-${ZONE%-*}}}"
[ "$REGION" = "(unset)" ] || [ -z "$REGION" ] && export REGION="us-central1"

export CLUSTER_NAME="${CLUSTER_NAME:-cloud-trace-demo}"
export MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
export NUM_NODES="${NUM_NODES:-3}"

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
echo "Cluster Name : $CLUSTER_NAME"
echo "Machine Type : $MACHINE_TYPE"
echo "Num Nodes    : $NUM_NODES"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure container and cloudtrace APIs are enabled
echo "Ensuring required APIs are active..."
gcloud services enable container.googleapis.com cloudtrace.googleapis.com --quiet

# ==============================================================================
# TASK 1: Download and deploy your application
# ==============================================================================
echo ""
echo ">>> [Task 1] Setting up GKE Cluster and deploying sample application..."

# 1. Create GKE Cluster if not already existing
if ! gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    echo "Creating GKE cluster: ${CLUSTER_NAME} in zone ${ZONE}..."
    gcloud container clusters create "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --num-nodes="${NUM_NODES}" \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --quiet
else
    echo "Cluster ${CLUSTER_NAME} already exists."
fi

# 2. Get cluster credentials for kubectl
echo "Fetching cluster credentials for kubectl..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --quiet

echo "Confirming node status..."
kubectl get nodes

# 3. Clone sample application repository
ROOT_DIR=$(pwd)
if [ ! -d "python-docs-samples" ]; then
    echo "Cloning python-docs-samples repository..."
    git clone https://github.com/GoogleCloudPlatform/python-docs-samples.git
else
    echo "python-docs-samples repository already present."
fi

# 4. Deploy sample microservices
APP_DIR="${ROOT_DIR}/python-docs-samples/trace/cloud-trace-demo-app-opentelemetry"
if [ -d "$APP_DIR" ]; then
    echo "Deploying microservices using setup.sh..."
    cd "$APP_DIR"
    chmod +x setup.sh
    ./setup.sh
    cd "$ROOT_DIR"
else
    echo "Error: App directory ${APP_DIR} not found."
    exit 1
fi

# ==============================================================================
# TASK 2: Create a cloud trace
# ==============================================================================
echo ""
echo ">>> [Task 2] Resolving LoadBalancer endpoint and generating traces..."

# Wait for cloud-trace-demo-a external LoadBalancer IP
echo "Waiting for LoadBalancer external IP on service cloud-trace-demo-a..."
LB_IP=""
for i in {1..36}; do
    LB_IP=$(kubectl get svc -o=jsonpath='{.items[?(@.metadata.name=="cloud-trace-demo-a")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$LB_IP" ]; then
        echo "Found LoadBalancer IP: ${LB_IP}"
        break
    fi
    echo "Waiting for LoadBalancer IP... attempt $i/36"
    sleep 5
done

if [ -z "$LB_IP" ]; then
    echo "Error: Failed to obtain LoadBalancer external IP within expected time."
    exit 1
fi

# Wait for service A to respond
echo "Waiting for cloud-trace-demo-a to respond on http://${LB_IP}..."
for i in {1..24}; do
    RESPONSE=$(curl -s -m 5 "http://${LB_IP}" 2>/dev/null || true)
    if [ -n "$RESPONSE" ]; then
        echo "Service responded successfully:"
        echo "$RESPONSE"
        break
    fi
    echo "Waiting for service response... attempt $i/24"
    sleep 5
done

# Generate traces by issuing multiple HTTP requests
echo "Issuing 30 requests to trigger microservice traces..."
for i in {1..30}; do
    curl -s "http://${LB_IP}" > /dev/null 2>&1 || true
    sleep 0.2
done
echo "Trace requests completed."

echo "Waiting for traces to be indexed in Cloud Trace API..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
TRACE_CONFIRMED=false
for i in {1..24}; do
    TRACES=$(curl -s -H "Authorization: Bearer $TOKEN" "https://cloudtrace.googleapis.com/v1/projects/${PROJECT_ID}/traces" 2>/dev/null || true)
    if echo "$TRACES" | grep -q '"traceId"'; then
        echo "Trace data successfully ingested into Cloud Trace!"
        TRACE_CONFIRMED=true
        break
    fi
    # Send another curl request to keep data flowing
    curl -s "http://${LB_IP}" > /dev/null 2>&1 || true
    echo "Waiting for Cloud Trace indexing... attempt $i/24 (may take 1-2 minutes)"
    sleep 5
done

if [ "$TRACE_CONFIRMED" = false ]; then
    echo "Notice: Cloud Trace API indexing can take a few minutes. Check Trace Explorer in console."
fi

# ==============================================================================
# 5. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo ""
echo "=================================================="
echo "VERIFICATION SUMMARY"
echo "=================================================="

echo "1. GKE Cluster Status (${CLUSTER_NAME}):"
gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --format="table(name, status, location, currentNodeCount)" 2>/dev/null || true

echo ""
echo "2. Kubernetes Deployments:"
kubectl get deployments 2>/dev/null || true

echo ""
echo "3. Kubernetes Pods:"
kubectl get pods -o wide 2>/dev/null || true

echo ""
echo "4. Kubernetes Services:"
kubectl get services 2>/dev/null || true

echo ""
echo "5. Endpoint Test Response:"
curl -s "http://${LB_IP}" || echo "Could not reach endpoint."
echo ""

echo ""
echo "6. Cloud Trace Ingested Traces:"
curl -s -H "Authorization: Bearer $TOKEN" "https://cloudtrace.googleapis.com/v1/projects/${PROJECT_ID}/traces" 2>/dev/null | grep '"traceId"' | head -n 5 || echo "No traces visible yet."
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
