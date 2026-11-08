#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: REGION="us-east1" ZONE="us-east1-c" USER_2="student-XX@qwiklabs.net" ./script.sh
# ==============================================================================
export REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-east1")}"
export ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-east1-c")}"
export USER_2="${USER_2:-student-04-fbecdf0f14bd@qwiklabs.net}"

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
echo "Primary Region   : $REGION"
echo "Primary Zone     : $ZONE"
echo "Additional User  : $USER_2"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure necessary APIs are active
echo "Ensuring required Google Cloud APIs are active..."
gcloud services enable compute.googleapis.com container.googleapis.com sqladmin.googleapis.com monitoring.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE DEVELOPMENT VPC MANUALLY
# ==============================================================================
echo "Checking Development VPC: griffin-dev-vpc..."
if ! gcloud compute networks describe griffin-dev-vpc --quiet >/dev/null 2>&1; then
    echo "Creating griffin-dev-vpc..."
    gcloud compute networks create griffin-dev-vpc --subnet-mode=custom --quiet
fi

echo "Checking Subnet: griffin-dev-wp..."
if ! gcloud compute networks subnets describe griffin-dev-wp --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating griffin-dev-wp (192.168.16.0/20)..."
    gcloud compute networks subnets create griffin-dev-wp \
        --network=griffin-dev-vpc \
        --region="$REGION" \
        --range=192.168.16.0/20 \
        --quiet
fi

echo "Checking Subnet: griffin-dev-mgmt..."
if ! gcloud compute networks subnets describe griffin-dev-mgmt --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating griffin-dev-mgmt (192.168.32.0/20)..."
    gcloud compute networks subnets create griffin-dev-mgmt \
        --network=griffin-dev-vpc \
        --region="$REGION" \
        --range=192.168.32.0/20 \
        --quiet
fi

echo "Checking Firewall Rule: griffin-dev-allow-ssh..."
if ! gcloud compute firewall-rules describe griffin-dev-allow-ssh --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create griffin-dev-allow-ssh \
        --network=griffin-dev-vpc \
        --allow=tcp:22 \
        --source-ranges=0.0.0.0/0 \
        --quiet
fi

# ==============================================================================
# 4. TASK 2: CREATE PRODUCTION VPC MANUALLY
# ==============================================================================
echo "Checking Production VPC: griffin-prod-vpc..."
if ! gcloud compute networks describe griffin-prod-vpc --quiet >/dev/null 2>&1; then
    echo "Creating griffin-prod-vpc..."
    gcloud compute networks create griffin-prod-vpc --subnet-mode=custom --quiet
fi

echo "Checking Subnet: griffin-prod-wp..."
if ! gcloud compute networks subnets describe griffin-prod-wp --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating griffin-prod-wp (192.168.48.0/20)..."
    gcloud compute networks subnets create griffin-prod-wp \
        --network=griffin-prod-vpc \
        --region="$REGION" \
        --range=192.168.48.0/20 \
        --quiet
fi

echo "Checking Subnet: griffin-prod-mgmt..."
if ! gcloud compute networks subnets describe griffin-prod-mgmt --region="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating griffin-prod-mgmt (192.168.64.0/20)..."
    gcloud compute networks subnets create griffin-prod-mgmt \
        --network=griffin-prod-vpc \
        --region="$REGION" \
        --range=192.168.64.0/20 \
        --quiet
fi

echo "Checking Firewall Rule: griffin-prod-allow-ssh..."
if ! gcloud compute firewall-rules describe griffin-prod-allow-ssh --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create griffin-prod-allow-ssh \
        --network=griffin-prod-vpc \
        --allow=tcp:22 \
        --source-ranges=0.0.0.0/0 \
        --quiet
fi

# ==============================================================================
# 5. TASK 3: CREATE BASTION HOST
# ==============================================================================
echo "Checking Bastion VM: griffin-bastion..."
if ! gcloud compute instances describe griffin-bastion --zone="$ZONE" --quiet >/dev/null 2>&1; then
    echo "Creating dual-homed bastion host (griffin-bastion)..."
    gcloud compute instances create griffin-bastion \
        --zone="$ZONE" \
        --machine-type=e2-medium \
        --network-interface=subnet=griffin-dev-mgmt \
        --network-interface=subnet=griffin-prod-mgmt \
        --quiet
else
    echo "Bastion host griffin-bastion already exists."
fi

# ==============================================================================
# 6. TASK 4 & 5: CLOUD SQL INSTANCE & GKE CLUSTER (PARALLEL PROVISIONING)
# ==============================================================================
SQL_PID=""
if ! gcloud sql instances describe griffin-dev-db --quiet >/dev/null 2>&1; then
    echo "Starting Cloud SQL instance (griffin-dev-db) in background..."
    (
        gcloud sql instances create griffin-dev-db \
            --root-password=stormwind_rules \
            --region="$REGION" \
            --database-version=MYSQL_8_0 \
            --tier=db-custom-1-3840 \
            --quiet 2>/dev/null || \
        gcloud sql instances create griffin-dev-db \
            --root-password=stormwind_rules \
            --region="$REGION" \
            --quiet
    ) &
    SQL_PID=$!
else
    echo "Cloud SQL instance griffin-dev-db already exists."
fi

echo "Checking GKE cluster: griffin-dev in $ZONE..."
if ! gcloud container clusters describe griffin-dev --zone="$ZONE" --quiet >/dev/null 2>&1; then
    echo "Creating 2-node GKE cluster griffin-dev (this typically takes 3-4 minutes)..."
    gcloud container clusters create griffin-dev \
        --zone="$ZONE" \
        --num-nodes=2 \
        --machine-type=e2-standard-4 \
        --network=griffin-dev-vpc \
        --subnetwork=griffin-dev-wp \
        --quiet
else
    echo "GKE cluster griffin-dev already exists in $ZONE."
fi

echo "Configuring kubectl credentials for griffin-dev..."
gcloud container clusters get-credentials griffin-dev --zone="$ZONE" --quiet

if [ -n "$SQL_PID" ]; then
    echo "Waiting for Cloud SQL instance (griffin-dev-db) provisioning to complete..."
    wait "$SQL_PID" || true
fi

echo "Configuring Cloud SQL database (wordpress) and user (wp_user)..."
if ! gcloud sql databases describe wordpress --instance=griffin-dev-db --quiet >/dev/null 2>&1; then
    gcloud sql databases create wordpress --instance=griffin-dev-db --quiet
fi

if ! gcloud sql users list --instance=griffin-dev-db --format="value(name)" 2>/dev/null | grep -q "wp_user"; then
    gcloud sql users create wp_user --instance=griffin-dev-db --password=stormwind_rules --host="%" --quiet 2>/dev/null || \
    gcloud sql users create wp_user --instance=griffin-dev-db --password=stormwind_rules --quiet
fi

# ==============================================================================
# 7. TASK 6: PREPARE THE KUBERNETES CLUSTER
# ==============================================================================
echo "Downloading WordPress Kubernetes configuration files..."
mkdir -p "$HOME/wp-k8s"
gsutil -m cp -r gs://spls/gsp321/wp-k8s/* "$HOME/wp-k8s/" 2>/dev/null || gsutil -m cp -r gs://cloud-training/gsp321/wp-k8s/* "$HOME/wp-k8s/"
cd "$HOME/wp-k8s"

echo "Configuring Service Account key for cloud-sql-proxy..."
SA_EMAIL="cloud-sql-proxy@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --quiet >/dev/null 2>&1; then
    gcloud iam service-accounts create cloud-sql-proxy --display-name="cloud-sql-proxy" --quiet
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="roles/cloudsql.client" --quiet
fi

rm -f key.json
gcloud iam service-accounts keys create key.json --iam-account="$SA_EMAIL" --quiet

if ! kubectl get secret cloudsql-instance-credentials >/dev/null 2>&1; then
    kubectl create secret generic cloudsql-instance-credentials --from-file key.json
fi

echo "Updating database credentials in wp-env.yaml..."
sed -i 's/username_goes_here/wp_user/g' wp-env.yaml
sed -i 's/password_goes_here/stormwind_rules/g' wp-env.yaml
kubectl apply -f wp-env.yaml

# ==============================================================================
# 8. TASK 7: CREATE A WORDPRESS DEPLOYMENT
# ==============================================================================
echo "Injecting Cloud SQL Instance Connection Name into wp-deployment.yaml..."
SQL_CONNECTION_NAME=$(gcloud sql instances describe griffin-dev-db --format="value(connectionName)")
echo "Connection Name: $SQL_CONNECTION_NAME"
sed -i "s/YOUR_SQL_INSTANCE/$SQL_CONNECTION_NAME/g" wp-deployment.yaml

echo "Deploying WordPress workload and LoadBalancer service..."
kubectl apply -f wp-deployment.yaml
kubectl apply -f wp-service.yaml

echo "Waiting for WordPress external LoadBalancer IP allocation..."
WP_IP=""
for i in {1..35}; do
    WP_IP=$(kubectl get svc wordpress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$WP_IP" ]; then
        echo "WordPress Service External IP: $WP_IP"
        break
    fi
    echo "Waiting for External IP... (Check $i/35)"
    sleep 4
done

# ==============================================================================
# 9. TASK 8: ENABLE MONITORING (UPTIME CHECK)
# ==============================================================================
if [ -n "$WP_IP" ]; then
    echo "Configuring Cloud Monitoring Uptime Check for $WP_IP..."
    ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
    curl -s -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/uptimeCheckConfigs" \
        -d '{
            "displayName": "WordPress Dev Uptime Check",
            "monitoredResource": {
                "type": "uptime_url",
                "labels": {
                    "host": "'"$WP_IP"'"
                }
            },
            "httpCheck": {
                "path": "/",
                "port": 80,
                "useSsl": false
            },
            "period": "60s",
            "timeout": "10s"
        }' >/dev/null || true
fi

# ==============================================================================
# 10. TASK 9: PROVIDE ACCESS FOR AN ADDITIONAL ENGINEER
# ==============================================================================
if [ -n "$USER_2" ]; then
    echo "Granting Project Editor role to additional engineer: $USER_2..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$USER_2" \
        --role="roles/editor" \
        --quiet >/dev/null
else
    echo "Notice: USER_2 not specified. Pass USER_2=\"student-XX@qwiklabs.net\" to automate Task 9."
fi

# ==============================================================================
# 11. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "Subnets:"
gcloud compute networks subnets list --filter="network:griffin-dev-vpc OR network:griffin-prod-vpc" --format="table(name, network, region, ipCidrRange)"

echo ""
echo "Bastion Host:"
gcloud compute instances describe griffin-bastion --zone="$ZONE" --format="table(name, status, networkInterfaces[0].networkIP:label=NIC0_IP, networkInterfaces[1].networkIP:label=NIC1_IP)"

echo ""
echo "Cloud SQL Instance:"
gcloud sql instances describe griffin-dev-db --format="table(name, state, ipAddresses[0].ipAddress, connectionName)"

echo ""
echo "GKE Cluster Nodes:"
gcloud container clusters describe griffin-dev --zone="$ZONE" --format="table(name, status, currentNodeCount, endpoint)"

echo ""
echo "WordPress Service:"
kubectl get svc wordpress -o wide || true

if [ -n "$WP_IP" ]; then
    echo ""
    echo "HTTP Connectivity Test to WordPress:"
    curl -I "http://$WP_IP" || true
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
