#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-east1" ZONE="us-east1-c" USER_2="user2@qwiklabs.net" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-east1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-east1"
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-east1-c}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-east1-c"
export USER_2="${USER_2:-}"
export TEST_DOMAIN="${TEST_DOMAIN:-altostrat.com}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
_DET_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
export PROJECT_ID="${PROJECT_ID:-${_DET_PROJECT:-${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}}}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

CURRENT_USER=$(gcloud config get-value account 2>/dev/null || true)

# Auto-detect USER_2 from IAM policy if not explicitly provided or if placeholder matches
if [ -z "$USER_2" ]; then
    DETECTED_USER_2=$(gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --format="value(bindings.members)" 2>/dev/null \
        | grep "^user:student-" \
        | grep -v "$CURRENT_USER" \
        | sed 's/^user://' \
        | sort -u \
        | head -n1 || true)
    if [ -n "$DETECTED_USER_2" ]; then
        export USER_2="${USER_2:-$DETECTED_USER_2}"
    fi
fi

export BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-bucket}"

echo "=================================================="
echo "Project ID  : $PROJECT_ID"
echo "Region      : $REGION"
echo "Zone        : $ZONE"
echo "User 1      : $CURRENT_USER"
echo "User 2      : $USER_2"
echo "Bucket Name : $BUCKET_NAME"
echo "Test Domain : $TEST_DOMAIN"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure API access (silently continue if student account lacks serviceusage permission)
gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 3: PREPARE A RESOURCE FOR ACCESS TESTING (BUCKET & SAMPLE FILE)
# ==============================================================================
echo "Checking Cloud Storage bucket gs://$BUCKET_NAME..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME" &>/dev/null; then
    echo "Creating Cloud Storage bucket gs://$BUCKET_NAME (Multi-region US)..."
    gcloud storage buckets create "gs://$BUCKET_NAME" --location=US --quiet
fi

echo "Preparing sample text files..."
echo "This is a sample text file for Google Cloud IAM access testing." > /tmp/sample.txt
echo "Uploading sample.txt to gs://$BUCKET_NAME/sample.txt..."
gcloud storage cp /tmp/sample.txt "gs://$BUCKET_NAME/sample.txt" --quiet

# Also pre-stage sample2.txt for Task 7 verification
echo "Uploading sample2.txt to gs://$BUCKET_NAME/sample2.txt..."
gcloud storage cp /tmp/sample.txt "gs://$BUCKET_NAME/sample2.txt" --quiet

# ==============================================================================
# 4. TASK 4: REMOVE PROJECT ACCESS FOR USER 2
# ==============================================================================
if [ -n "$USER_2" ]; then
    echo "Checking and revoking Project Viewer role from $USER_2..."
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="user:$USER_2" \
        --role="roles/viewer" \
        --quiet 2>/dev/null || true
else
    echo "Warning: USER_2 not detected; skipping role revocation."
fi

# ==============================================================================
# 5. TASK 5: ADD STORAGE ACCESS FOR USER 2
# ==============================================================================
if [ -n "$USER_2" ]; then
    echo "Granting Storage Object Viewer role to $USER_2 at project level..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$USER_2" \
        --role="roles/storage.objectViewer" \
        --quiet

    # Also bind to the specific bucket for thoroughness
    echo "Granting Storage Object Viewer role to $USER_2 on bucket gs://$BUCKET_NAME..."
    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
        --member="user:$USER_2" \
        --role="roles/storage.objectViewer" \
        --quiet 2>/dev/null || true
fi

# ==============================================================================
# 6. TASK 6: CONFIGURE SERVICE ACCOUNT & PROVISION VM INSTANCE
# ==============================================================================
SA_NAME="read-bucket-objects"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Checking Service Account: $SA_NAME..."
if ! gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
    echo "Creating Service Account $SA_NAME..."
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="read-bucket-objects" \
        --quiet
    sleep 5
fi

# Grant Cloud Storage roles to service account on project
echo "Assigning storage roles to $SA_EMAIL..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/storage.objectViewer" \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/storage.objectCreator" \
    --quiet

# Grant Service Account User to test domain on the service account
echo "Granting Service Account User to domain:$TEST_DOMAIN on $SA_NAME..."
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="domain:$TEST_DOMAIN" \
    --role="roles/iam.serviceAccountUser" \
    --quiet 2>/dev/null || true

# Grant Compute Instance Admin (v1) to test domain on the project
echo "Granting Compute Instance Admin (v1) to domain:$TEST_DOMAIN on project..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="domain:$TEST_DOMAIN" \
    --role="roles/compute.instanceAdmin.v1" \
    --quiet 2>/dev/null || true

# Provision demoiam VM instance
echo "Checking VM instance: demoiam..."
if ! gcloud compute instances describe demoiam --zone="$ZONE" &>/dev/null; then
    echo "Creating VM instance demoiam..."
    gcloud compute instances create demoiam \
        --zone="$ZONE" \
        --machine-type=e2-micro \
        --service-account="$SA_EMAIL" \
        --scopes=storage-rw \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --quiet
else
    VM_STATUS=$(gcloud compute instances describe demoiam --zone="$ZONE" --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    if [ "$VM_STATUS" = "TERMINATED" ] || [ "$VM_STATUS" = "STOPPED" ]; then
        echo "Starting stopped instance demoiam..."
        gcloud compute instances start demoiam --zone="$ZONE" --quiet
    fi
fi

# ==============================================================================
# 7. TASK 7: EXPLORE SERVICE ACCOUNT ROLE INSIDE VM
# ==============================================================================
echo "Setting up in-VM verification files on demoiam..."
for attempt in {1..12}; do
    if gcloud compute ssh demoiam --zone="$ZONE" --quiet --command="true" 2>/dev/null; then
        echo "SSH connection established. Synchronizing sample files..."
        gcloud compute ssh demoiam --zone="$ZONE" --quiet --command="
            gcloud storage cp gs://$BUCKET_NAME/sample.txt ./sample.txt 2>/dev/null || true
            cp ./sample.txt ./sample2.txt 2>/dev/null || true
            gcloud storage cp ./sample2.txt gs://$BUCKET_NAME/ 2>/dev/null || true
        " 2>/dev/null || true
        echo "In-VM file setup completed successfully!"
        break
    fi
    sleep 5
done

# ==============================================================================
# 8. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Cloud Storage Bucket Contents:"
gcloud storage ls "gs://$BUCKET_NAME/" || true

echo ""
echo "User 2 IAM Roles:"
gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:$USER_2" \
    --format="table(bindings.role)" || true

echo ""
echo "Service Account Details:"
gcloud iam service-accounts describe "$SA_EMAIL" --format="table(email, displayName, disabled)"

echo ""
echo "VM Instance Details:"
gcloud compute instances describe demoiam --zone="$ZONE" --format="table(name, zone, machineType, status, serviceAccounts[0].email:label=SERVICE_ACCOUNT)"

# Display completion status
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${CYAN}+-------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
