#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: REGION="us-east4" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east4}}"
[ "$REGION" = "(unset)" ] && export REGION="us-east4"
export CLUSTER_NAME="${CLUSTER_NAME:-autopilot-cluster-1}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-nginx-1}"

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
echo "Cluster Name     : $CLUSTER_NAME"
echo "Workload Name    : $DEPLOYMENT_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# Ensure Kubernetes Engine API is enabled
echo "Ensuring Kubernetes Engine API is active..."
gcloud services enable container.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: DEPLOY GKE AUTOPILOT CLUSTER
# ==============================================================================
echo "Checking GKE Autopilot cluster: $CLUSTER_NAME in $REGION..."
if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating GKE Autopilot cluster $CLUSTER_NAME in $REGION (this typically takes 5-7 minutes)..."
    gcloud container clusters create-auto "$CLUSTER_NAME" \
        --region="$REGION" \
        --quiet
else
    echo "Cluster $CLUSTER_NAME already exists in $REGION."
fi

echo "Configuring kubectl credentials for $CLUSTER_NAME..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --quiet

# ==============================================================================
# 4. TASK 2: DEPLOY A SAMPLE WORKLOAD (NGINX-1)
# ==============================================================================
echo "Checking Kubernetes deployment: $DEPLOYMENT_NAME..."
if ! kubectl get deployment "$DEPLOYMENT_NAME" >/dev/null 2>&1; then
    echo "Creating deployment $DEPLOYMENT_NAME with container image nginx:latest..."
    kubectl create deployment "$DEPLOYMENT_NAME" --image=nginx:latest
    echo "Scaling $DEPLOYMENT_NAME to 3 replica Pods..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=3
else
    echo "Deployment $DEPLOYMENT_NAME already exists. Ensuring replica count is 3..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=3 || true
fi

echo "Waiting for $DEPLOYMENT_NAME deployment rollout..."
kubectl rollout status deployment/"$DEPLOYMENT_NAME" --timeout=180s || true

# ==============================================================================
# 5. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "Cluster Details:"
gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" --format="yaml(name, status, location, autopilot)"

echo ""
echo "Deployment Status:"
kubectl get deployment "$DEPLOYMENT_NAME" -o wide

echo ""
echo "Pod Instances:"
kubectl get pods -l app="$DEPLOYMENT_NAME" -o wide

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
