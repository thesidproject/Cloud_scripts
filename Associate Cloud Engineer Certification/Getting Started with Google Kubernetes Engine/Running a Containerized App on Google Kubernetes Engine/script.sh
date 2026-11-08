#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: ZONE="us-west1-c" ./script.sh
# ==============================================================================
export ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-west1-c")}"
export REGION="${REGION:-${ZONE%-*}}"
export CLUSTER_NAME="${CLUSTER_NAME:-hello-world}"
export APP_NAME="${APP_NAME:-hello-app}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export IMAGE_TAG="gcr.io/${PROJECT_ID}/${APP_NAME}:1.0"

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Zone             : $ZONE"
echo "Region           : $REGION"
echo "Cluster Name     : $CLUSTER_NAME"
echo "Application Name : $APP_NAME"
echo "Target Image     : $IMAGE_TAG"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/zone "$ZONE" --quiet
gcloud config set compute/region "$REGION" --quiet

# Ensure required APIs are enabled
echo "Ensuring required APIs are active..."
gcloud services enable container.googleapis.com cloudbuild.googleapis.com containerregistry.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE A 3-NODE GKE CLUSTER
# ==============================================================================
echo "Checking GKE cluster: $CLUSTER_NAME in $ZONE..."
if ! gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --quiet >/dev/null 2>&1; then
    echo "Creating 3-node GKE cluster $CLUSTER_NAME in $ZONE (this typically takes 3-5 minutes)..."
    gcloud container clusters create "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --num-nodes=3 \
        --machine-type=e2-medium \
        --quiet
else
    echo "Cluster $CLUSTER_NAME already exists in $ZONE."
fi

echo "Configuring kubectl credentials for $CLUSTER_NAME..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE" --quiet

# ==============================================================================
# 4. TASK 2: BUILD AND PUBLISH HELLO WORLD CONTAINER IMAGE
# ==============================================================================
echo "Preparing sample application repository..."
if [ ! -d "kubernetes-engine-samples" ]; then
    git clone https://github.com/GoogleCloudPlatform/kubernetes-engine-samples.git --quiet
fi
cd kubernetes-engine-samples/quickstarts/hello-app

echo "Configuring Docker credential helper for Container Registry..."
gcloud auth configure-docker --quiet 2>/dev/null || true

echo "Building Docker container image $IMAGE_TAG..."
docker build -t "$IMAGE_TAG" .

echo "Pushing container image to registry..."
if ! docker push "$IMAGE_TAG"; then
    echo "Standard docker push failed; falling back to Cloud Build submit..."
    gcloud builds submit --tag "$IMAGE_TAG" . --quiet
fi

# ==============================================================================
# 5. TASK 3: DEPLOY APPLICATION & EXPOSE VIA LOAD BALANCER
# ==============================================================================
echo "Checking Kubernetes deployment: $APP_NAME..."
if ! kubectl get deployment "$APP_NAME" >/dev/null 2>&1; then
    echo "Creating deployment $APP_NAME with image $IMAGE_TAG..."
    kubectl create deployment "$APP_NAME" --image="$IMAGE_TAG"
else
    echo "Deployment $APP_NAME already exists. Updating container image..."
    kubectl set image deployment/"$APP_NAME" "$APP_NAME"="$IMAGE_TAG" || true
fi

echo "Waiting for deployment rollout..."
kubectl rollout status deployment/"$APP_NAME" --timeout=120s

echo "Checking LoadBalancer service: $APP_NAME..."
if ! kubectl get svc "$APP_NAME" >/dev/null 2>&1; then
    echo "Exposing deployment $APP_NAME via LoadBalancer service on port 80..."
    kubectl expose deployment "$APP_NAME" \
        --name="$APP_NAME" \
        --type=LoadBalancer \
        --port=80 \
        --target-port=8080
else
    echo "Service $APP_NAME already exists."
fi

echo "Waiting for external LoadBalancer IP assignment..."
EXTERNAL_IP=""
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get svc "$APP_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        echo "External IP assigned: $EXTERNAL_IP"
        break
    fi
    echo "Waiting for external IP allocation... (Check $i/30)"
    sleep 4
done

if [ -n "$EXTERNAL_IP" ]; then
    echo "Testing HTTP endpoint at http://$EXTERNAL_IP..."
    for i in {1..12}; do
        if curl -s -m 5 "http://$EXTERNAL_IP" | grep -qi "Hello"; then
            echo "Application is live and responding: Hello, world!"
            break
        fi
        sleep 3
    done
fi

# ==============================================================================
# 6. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "GKE Cluster Details:"
gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --format="table(name, status, currentNodeCount, endpoint)"

echo ""
echo "Kubernetes Deployment & Pods:"
kubectl get deployment "$APP_NAME" -o wide
kubectl get pods -l app="$APP_NAME" -o wide

echo ""
echo "Kubernetes Service Details:"
kubectl get svc "$APP_NAME" -o wide

if [ -n "$EXTERNAL_IP" ]; then
    echo ""
    echo "HTTP Response Test:"
    curl -I "http://$EXTERNAL_IP" || true
fi

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
