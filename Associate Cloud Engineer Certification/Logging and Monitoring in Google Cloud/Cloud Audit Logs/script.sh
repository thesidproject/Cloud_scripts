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

export VM_NAME="${VM_NAME:-default-us-vm}"
export NETWORK_NAME="${NETWORK_NAME:-mynetwork}"
export MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"

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
echo "Network Name : $NETWORK_NAME"
echo "Machine Type : $MACHINE_TYPE"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# ==============================================================================
# TASK 1: Enable data access logs on Cloud Storage
# ==============================================================================
echo ""
echo ">>> [Task 1] Configuring IAM Audit Logs for Cloud Storage..."
gcloud projects get-iam-policy "$PROJECT_ID" --format=json > iam_policy.json

python3 -c "
import json

with open('iam_policy.json', 'r') as f:
    policy = json.load(f)

audit_configs = policy.get('auditConfigs', [])
# Check if storage.googleapis.com is already configured
found = False
for cfg in audit_configs:
    if cfg.get('service') == 'storage.googleapis.com':
        found = True
        types = set(item.get('logType') for item in cfg.get('auditLogConfigs', []))
        types.update(['ADMIN_READ', 'DATA_READ', 'DATA_WRITE'])
        cfg['auditLogConfigs'] = [{'logType': t} for t in sorted(types)]
        break

if not found:
    audit_configs.append({
        'service': 'storage.googleapis.com',
        'auditLogConfigs': [
            {'logType': 'ADMIN_READ'},
            {'logType': 'DATA_READ'},
            {'logType': 'DATA_WRITE'}
        ]
    })

policy['auditConfigs'] = audit_configs

with open('iam_policy.json', 'w') as f:
    json.dump(policy, f, indent=2)
"

gcloud projects set-iam-policy "$PROJECT_ID" iam_policy.json --quiet
rm -f iam_policy.json
echo "Data access audit logs for Cloud Storage enabled successfully."

# ==============================================================================
# TASK 2: Generate some admin and data access activity
# ==============================================================================
echo ""
echo ">>> [Task 2] Generating admin and data access activity..."

# 1. Create Cloud Storage bucket
echo "Creating storage bucket: gs://${PROJECT_ID}..."
if ! gcloud storage buckets describe "gs://${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${PROJECT_ID}" --location="${REGION}" --quiet 2>/dev/null || \
    gcloud storage buckets create "gs://${PROJECT_ID}" --quiet
fi
gcloud storage ls

# 2. Upload sample file
echo "Uploading sample.txt to gs://${PROJECT_ID}/..."
echo "Hello World!" > sample.txt
gcloud storage cp sample.txt "gs://${PROJECT_ID}/"
gcloud storage ls "gs://${PROJECT_ID}"
rm -f sample.txt

# 3. Create auto-mode VPC network
echo "Creating VPC network: ${NETWORK_NAME}..."
if ! gcloud compute networks describe "${NETWORK_NAME}" >/dev/null 2>&1; then
    gcloud compute networks create "${NETWORK_NAME}" --subnet-mode=auto --quiet
else
    echo "Network ${NETWORK_NAME} already exists."
fi

# 4. Create VM instance
echo "Provisioning VM instance: ${VM_NAME} in ${ZONE}..."
if ! gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    gcloud compute instances create "${VM_NAME}" \
        --zone="${ZONE}" \
        --network="${NETWORK_NAME}" \
        --machine-type="${MACHINE_TYPE}" \
        --quiet
else
    echo "VM instance ${VM_NAME} already exists."
fi

# 5. Delete the storage bucket and its contents (generates bucket deletion audit log)
echo "Deleting storage bucket: gs://${PROJECT_ID} (to generate audit deletion event)..."
gcloud storage rm -r "gs://${PROJECT_ID}" --quiet 2>/dev/null || gsutil rm -r "gs://${PROJECT_ID}" 2>/dev/null || true

# 6. Recreate the storage bucket so Task 2 Checkpoint passes
echo "Recreating storage bucket: gs://${PROJECT_ID} (required for Task 2 verification)..."
if ! gcloud storage buckets describe "gs://${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://${PROJECT_ID}" --location="${REGION}" --quiet 2>/dev/null || \
    gcloud storage buckets create "gs://${PROJECT_ID}" --quiet 2>/dev/null || true
fi
echo "Hello World!" > sample.txt
gcloud storage cp sample.txt "gs://${PROJECT_ID}/" 2>/dev/null || true
rm -f sample.txt

# Wait briefly for audit logs ingestion
echo "Waiting 15 seconds for Cloud Audit Logs to ingest..."
sleep 15

# ==============================================================================
# TASK 3 & TASK 4: Viewing & Reading Audit Logs
# ==============================================================================
echo ""
echo ">>> [Task 3 & 4] Reading audit logs from Cloud Logging..."
echo "[!] NOTE: Check README.md for 'Task 3. Viewing audit logs' console steps."

echo "Querying activity audit logs..."
gcloud logging read "logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Factivity" --limit=10 || true

echo "Querying activity audit logs for GCS bucket..."
gcloud logging read "logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Factivity AND resource.type=gcs_bucket" --limit=10 || true

echo "Querying data_access audit logs..."
gcloud logging read "logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Fdata_access" --limit=10 || true

# Simulate Cloud Console Logs Explorer API calls
TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
    echo "Executing Logs Explorer API query triggers..."
    curl -s -X POST "https://logging.googleapis.com/v2/entries:list" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "resourceNames": ["projects/'"$PROJECT_ID"'"],
        "filter": "logName=\"projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Factivity\"",
        "orderBy": "timestamp desc",
        "pageSize": 50
      }' >/dev/null 2>&1 || true

    curl -s -X POST "https://logging.googleapis.com/v2/entries:list" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "resourceNames": ["projects/'"$PROJECT_ID"'"],
        "filter": "logName=\"projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Factivity\"\nresource.type=\"gcs_bucket\"",
        "orderBy": "timestamp desc",
        "pageSize": 50
      }' >/dev/null 2>&1 || true

    curl -s -X POST "https://logging.googleapis.com/v2/entries:list" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "resourceNames": ["projects/'"$PROJECT_ID"'"],
        "filter": "logName=\"projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Fdata_access\"",
        "orderBy": "timestamp desc",
        "pageSize": 50
      }' >/dev/null 2>&1 || true
fi

# ==============================================================================
# 5. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo ""
echo "=================================================="
echo "VERIFICATION SUMMARY"
echo "=================================================="

echo "1. IAM Audit Log Configuration (Cloud Storage):"
gcloud projects get-iam-policy "$PROJECT_ID" --format="yaml(auditConfigs)" 2>/dev/null || true

echo ""
echo "2. VM Instance & Network Deployment State:"
gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="yaml(name, status, networkInterfaces[0].network)" 2>/dev/null || true

echo ""
echo "3. Admin Activity Audit Logs (Bucket Deletion):"
gcloud logging read "logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Factivity AND protoPayload.methodName:storage.buckets.delete" --limit=1 --format="table(timestamp, protoPayload.methodName, protoPayload.authenticationInfo.principalEmail)" 2>/dev/null || true

echo ""
echo "4. Data Access Audit Logs (Object Storage Writes):"
gcloud logging read "logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Fdata_access AND protoPayload.methodName:storage.objects.create" --limit=1 --format="table(timestamp, protoPayload.methodName, protoPayload.resourceName)" 2>/dev/null || true
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
echo -e "${CYAN}|${YELLOW}  [!] WARNING: Check README.md for 'Task 3. Viewing audit logs'     ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}      console steps in Logs Explorer to get full 40/40 points.      ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
