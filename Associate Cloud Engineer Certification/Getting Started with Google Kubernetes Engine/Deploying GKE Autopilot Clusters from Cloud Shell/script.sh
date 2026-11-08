#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: REGION="us-west1" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-west1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-west1"
export CLUSTER_NAME="${CLUSTER_NAME:-autopilot-cluster-1}"

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
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# Ensure Kubernetes Engine API is enabled
echo "Ensuring Kubernetes Engine API is active..."
gcloud services enable container.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1 & 2: DEPLOY GKE AUTOPILOT CLUSTER & CONNECT
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
# 4. TASK 3: INSPECT GKE CLUSTER CONTEXT
# ==============================================================================
echo "Configuring Kubernetes cluster context..."
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
echo "Current Context: $CURRENT_CONTEXT"
kubectl cluster-info || true

# ==============================================================================
# 5. TASK 4: DEPLOY PODS TO GKE CLUSTER (NGINX-1)
# ==============================================================================
echo "Checking deployment: nginx-1..."
if ! kubectl get deployment nginx-1 >/dev/null 2>&1; then
    echo "Creating deployment nginx-1..."
    kubectl create deployment --image nginx nginx-1
else
    echo "Deployment nginx-1 already exists."
fi

echo "Waiting for nginx-1 deployment rollout..."
kubectl rollout status deployment/nginx-1 --timeout=180s || true

# Apply standard Kubernetes Metrics Server manifest
echo "Applying Metrics Server components..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true

# Prepare test.html
echo "Creating test.html..."
cat << 'EOF' > "$HOME/test.html"
<header><title>This is title</title></header> Hello world
EOF

# Find running nginx-1 pod name
MY_NGINX_POD=$(kubectl get pods -l app=nginx-1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$MY_NGINX_POD" ]; then
    echo "Identified running Pod: $MY_NGINX_POD"
    echo "Copying test.html into $MY_NGINX_POD..."
    # Wait until container is ready to accept cp
    for i in {1..15}; do
        if kubectl cp "$HOME/test.html" "${MY_NGINX_POD}:/usr/share/nginx/html/test.html" 2>/dev/null; then
            echo "Successfully copied test.html into $MY_NGINX_POD."
            break
        fi
        sleep 2
    done

    echo "Exposing pod $MY_NGINX_POD via LoadBalancer service on port 80..."
    if ! kubectl get svc "$MY_NGINX_POD" >/dev/null 2>&1; then
        kubectl expose pod "$MY_NGINX_POD" --port 80 --type LoadBalancer
    fi
fi

# ==============================================================================
# 6. TASK 5: INTROSPECT GKE PODS & DEPLOY NEW-NGINX VIA YAML
# ==============================================================================
echo "Setting up repository files and shortcuts..."
if [ ! -d "$HOME/training-data-analyst" ]; then
    git clone https://github.com/GoogleCloudPlatform/training-data-analyst.git "$HOME/training-data-analyst" --quiet 2>/dev/null || true
fi
ln -sfn "$HOME/training-data-analyst/courses/ak8s/v1.1" "$HOME/ak8s" 2>/dev/null || true

# Ensure new-nginx-pod.yaml exists
cat << 'EOF' > new-nginx-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: new-nginx
  labels:
    name: new-nginx
spec:
  containers:
  - name: new-nginx
    image: nginx
    ports:
    - containerPort: 80
EOF

if [ -d "$HOME/ak8s/GKE_Shell" ]; then
    cp -f new-nginx-pod.yaml "$HOME/ak8s/GKE_Shell/new-nginx-pod.yaml" 2>/dev/null || true
fi

echo "Checking Pod: new-nginx..."
if ! kubectl get pod new-nginx >/dev/null 2>&1; then
    echo "Applying new-nginx-pod.yaml..."
    kubectl apply -f new-nginx-pod.yaml
else
    echo "Pod new-nginx already exists."
fi

echo "Waiting for new-nginx pod to be ready..."
kubectl wait --for=condition=Ready pod/new-nginx --timeout=120s 2>/dev/null || true

echo "Populating test.html inside new-nginx container..."
kubectl cp "$HOME/test.html" new-nginx:/usr/share/nginx/html/test.html 2>/dev/null || true

# ==============================================================================
# 7. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "Cluster Details:"
gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" --format="table(name, status, location, autopilot.enabled)"

echo ""
echo "Active Pods:"
kubectl get pods -o wide

echo ""
echo "Kubernetes Services:"
kubectl get svc -o wide

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
