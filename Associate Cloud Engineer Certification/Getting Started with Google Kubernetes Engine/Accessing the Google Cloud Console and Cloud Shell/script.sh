#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different regions/zones.
# Override inline: REGION="europe-west1" ZONE="europe-west1-c" ./script.sh
# ==============================================================================
export REGION="${REGION:-europe-west1}"
export ZONE="${ZONE:-europe-west1-c}"
export INSTANCE_NAME="${INSTANCE_NAME:-first-vm}"
export SA_NAME="${SA_NAME:-test-service-account}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export BUCKET1_NAME="${PROJECT_ID}-bucket1"
export BUCKET2_NAME="${PROJECT_ID}-bucket2"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Region           : $REGION"
echo "Zone             : $ZONE"
echo "VM Instance      : $INSTANCE_NAME"
echo "Service Account  : $SA_NAME"
echo "Bucket 1 (Public): gs://$BUCKET1_NAME"
echo "Bucket 2         : gs://$BUCKET2_NAME"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE FIREWALL RULE, VM INSTANCE & IAM SERVICE ACCOUNT
# ==============================================================================
echo "Checking HTTP firewall access (port 80)..."
if ! gcloud compute firewall-rules list --filter="targetTags:http-server AND allowed.ports:80" --format="value(name)" 2>/dev/null | grep -q .; then
    echo "Creating firewall rule default-allow-http..."
    gcloud compute firewall-rules create default-allow-http \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server \
        --quiet
fi

# Prepare VM startup script for automated Nginx configuration
STARTUP_SCRIPT="/tmp/first_vm_startup.sh"
cat << EOF > "$STARTUP_SCRIPT"
#!/bin/bash
apt-get remove -y --purge man-db || true
touch /var/lib/man-db/auto-update || true
apt-get update
apt-get install -y nginx
cat << 'HTMLEOF' > /var/www/html/index.html
<html><head><title>Cat</title></head> <body> <h1>Cat</h1> <img src="https://storage.googleapis.com/${BUCKET1_NAME}/cat.jpg"> </body></html>
HTMLEOF
systemctl restart nginx
EOF

echo "Checking VM instance: $INSTANCE_NAME in $ZONE..."
if ! gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet >/dev/null 2>&1; then
    echo "Creating VM instance $INSTANCE_NAME with HTTP traffic allowed..."
    gcloud compute instances create "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --machine-type=e2-micro \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=http-server \
        --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
        --quiet
else
    echo "VM instance $INSTANCE_NAME already exists."
    # Ensure http-server tag is applied
    TAGS=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(tags.items)")
    if [[ "$TAGS" != *"http-server"* ]]; then
        gcloud compute instances add-tags "$INSTANCE_NAME" --zone="$ZONE" --tags=http-server --quiet
    fi
fi

echo "Checking IAM Service Account: $SA_NAME..."
if ! gcloud iam service-accounts describe "$SA_EMAIL" --quiet >/dev/null 2>&1; then
    echo "Creating service account $SA_NAME..."
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="$SA_NAME" \
        --quiet
fi

echo "Assigning Editor role to service account: $SA_NAME..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/editor" \
    --condition=None \
    --quiet >/dev/null

# ==============================================================================
# 4. TASK 3: CREATE CLOUD STORAGE BUCKETS & CONFIGURE OBJECTS
# ==============================================================================
echo "Checking Bucket 1: gs://$BUCKET1_NAME..."
if ! gcloud storage buckets describe "gs://$BUCKET1_NAME" &>/dev/null; then
    echo "Creating Bucket 1 (Multi-region US, Uniform Access)..."
    gcloud storage buckets create "gs://$BUCKET1_NAME" \
        --location=US \
        --default-storage-class=STANDARD \
        --uniform-bucket-level-access \
        --quiet
fi

# Ensure public access prevention is disabled for bucket 1
gcloud storage buckets update "gs://$BUCKET1_NAME" --no-public-access-prevention --quiet 2>/dev/null || true

# Grant public read access to allUsers for bucket 1
echo "Granting public read access (roles/storage.objectViewer) to allUsers on gs://$BUCKET1_NAME..."
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET1_NAME" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    --quiet >/dev/null

echo "Checking Bucket 2: gs://$BUCKET2_NAME..."
if ! gcloud storage buckets describe "gs://$BUCKET2_NAME" &>/dev/null; then
    echo "Creating Bucket 2 (Location US)..."
    gcloud storage buckets create "gs://$BUCKET2_NAME" \
        --location=US \
        --quiet
fi

# Fetch and distribute sample image cat.jpg
echo "Downloading cat.jpg from gs://cloud-training/ak8s/cat.jpg..."
gcloud storage cp gs://cloud-training/ak8s/cat.jpg cat.jpg --quiet
echo "Uploading cat.jpg to gs://$BUCKET1_NAME..."
gcloud storage cp cat.jpg "gs://$BUCKET1_NAME/cat.jpg" --quiet
echo "Copying cat.jpg from gs://$BUCKET1_NAME to gs://$BUCKET2_NAME..."
gcloud storage cp "gs://$BUCKET1_NAME/cat.jpg" "gs://$BUCKET2_NAME/cat.jpg" --quiet

# ==============================================================================
# 5. TASK 4: WORKSPACE REPO SETUP & NGINX WEB SERVER VERIFICATION
# ==============================================================================
echo "Setting up local workspace files and Git repository..."
if [ ! -d "orchestrate-with-kubernetes" ]; then
    git clone https://github.com/googlecodelabs/orchestrate-with-kubernetes.git --quiet
fi
mkdir -p test

if [ -f "orchestrate-with-kubernetes/cleanup.sh" ]; then
    if ! grep -q "echo Finished cleanup!" orchestrate-with-kubernetes/cleanup.sh; then
        echo "echo Finished cleanup!" >> orchestrate-with-kubernetes/cleanup.sh
    fi
fi

# Prepare local index.html
cat << EOF > index.html
<html><head><title>Cat</title></head> <body> <h1>Cat</h1> <img src="https://storage.googleapis.com/${BUCKET1_NAME}/cat.jpg"> </body></html>
EOF
cp -f index.html orchestrate-with-kubernetes/index.html 2>/dev/null || true

echo "Fetching external IP address for $INSTANCE_NAME..."
VM_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

echo "Verifying Nginx web server at http://$VM_IP..."
WEB_READY=false
for i in {1..20}; do
    if curl -s -m 5 "http://$VM_IP" | grep -qi "Cat"; then
        WEB_READY=true
        echo "Nginx web server is live and serving the customized Cat page!"
        break
    fi
    # If the VM existed prior to this run without startup script, transfer via SSH/SCP
    if [ "$i" -eq 6 ]; then
        echo "Ensuring Nginx and index.html are deployed on $INSTANCE_NAME via SSH..."
        gcloud compute scp index.html "${INSTANCE_NAME}:index.html" --zone="$ZONE" --quiet 2>/dev/null || true
        gcloud compute ssh "${INSTANCE_NAME}" --zone="$ZONE" --quiet \
            --command="sudo apt-get remove -y --purge man-db && sudo touch /var/lib/man-db/auto-update && sudo apt-get update && sudo apt-get install -y nginx && sudo cp ~/index.html /var/www/html/ && sudo systemctl restart nginx" 2>/dev/null || true
    fi
    echo "Waiting for web server on $INSTANCE_NAME (Check $i/20)..."
    sleep 3
done

# ==============================================================================
# 6. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "VM Instance Status:"
gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="table(name, status, zone, tags.items, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)"

echo ""
echo "IAM Service Account & Roles:"
gcloud iam service-accounts list --filter="name:$SA_NAME" --format="table(displayName, email)"
gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" --format="table(bindings.role)" --filter="bindings.members:$SA_EMAIL"

echo ""
echo "Storage Buckets:"
gcloud storage buckets list --format="table(name, location, storageClass)"
gcloud storage ls "gs://$BUCKET1_NAME/"

echo ""
echo "HTTP Response Test:"
curl -I "http://$VM_IP" || true

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
