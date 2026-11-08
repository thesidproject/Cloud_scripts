#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-east1" BUCKET_NAME_1="your-bucket-name" ./script.sh
# ==============================================================================
export REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-east1")}"
export BUCKET_NAME_1="${BUCKET_NAME_1:-}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

if [ -z "$BUCKET_NAME_1" ]; then
    export BUCKET_NAME_1="${PROJECT_ID}"
fi

echo "=================================================="
echo "Project ID  : $PROJECT_ID"
echo "Region      : $REGION"
echo "Bucket Name : $BUCKET_NAME_1"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# Ensure API access (silently continue if student account lacks serviceusage permission)
gcloud services enable storage.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE BUCKET WITH FINE-GRAINED ACCESS & STAGE SAMPLE FILES
# ==============================================================================
echo "Checking Cloud Storage bucket gs://$BUCKET_NAME_1..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME_1" &>/dev/null; then
    echo "Creating Cloud Storage bucket gs://$BUCKET_NAME_1 in $REGION with fine-grained access..."
    gcloud storage buckets create "gs://$BUCKET_NAME_1" \
        --location="$REGION" \
        --default-storage-class=STANDARD \
        --no-uniform-bucket-level-access \
        --quiet
    gcloud storage buckets update "gs://$BUCKET_NAME_1" \
        --no-public-access-prevention \
        --quiet 2>/dev/null || true
else
    echo "Ensuring fine-grained access on existing bucket..."
    gcloud storage buckets update "gs://$BUCKET_NAME_1" \
        --no-uniform-bucket-level-access \
        --no-public-access-prevention \
        --quiet 2>/dev/null || true
fi

echo "Downloading sample HTML file..."
if [ ! -s setup.html ]; then
    curl -sSL "https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html" -o setup.html 2>/dev/null || true
fi

# Fallback if download server is unavailable
if [ ! -s setup.html ]; then
    cat << 'HTML_EOF' > setup.html
<!DOCTYPE html>
<html>
<head><title>Hadoop Cluster Setup</title></head>
<body>
<h1>Hadoop Cluster Setup Documentation</h1>
<p>Sample documentation content for Google Cloud Storage testing.</p>
</body>
</html>
HTML_EOF
fi

cp setup.html setup2.html
cp setup.html setup3.html
echo "Local sample files prepared: setup.html, setup2.html, setup3.html."

# ==============================================================================
# 4. TASK 2: ACCESS CONTROL LISTS (ACLS) & PUBLIC READ PERMISSIONS
# ==============================================================================
echo "Uploading setup.html to gs://$BUCKET_NAME_1/..."
gcloud storage cp setup.html "gs://$BUCKET_NAME_1/setup.html" --quiet

echo "Setting predefined ACL to private on setup.html..."
gcloud storage objects update "gs://$BUCKET_NAME_1/setup.html" --predefined-acl=private --quiet

echo "Granting public read permissions (allUsers) on setup.html..."
gcloud storage objects add-iam-policy-binding "gs://$BUCKET_NAME_1/setup.html" \
    --member="allUsers" \
    --role="roles/storage.legacyObjectReader" \
    --quiet

# Also ensure legacy ACL format is satisfied
gsutil acl ch -u allUsers:R "gs://$BUCKET_NAME_1/setup.html" 2>/dev/null || true

# Test local removal and download
rm -f setup.html
gcloud storage cp "gs://$BUCKET_NAME_1/setup.html" setup.html --quiet
echo "Verified setup.html re-download."

# ==============================================================================
# 5. TASKS 3 & 4: CUSTOMER-SUPPLIED ENCRYPTION KEYS (CSEK) & KEY ROTATION
# ==============================================================================
echo "Generating AES-256 Customer-Supplied Encryption Keys..."
KEY1=$(python3 -c 'import base64, os; print(base64.encodebytes(os.urandom(32)).decode("utf-8").strip())')
KEY2=$(python3 -c 'import base64, os; print(base64.encodebytes(os.urandom(32)).decode("utf-8").strip())')

BOTO_FILE="$HOME/.boto"
echo "Configuring $BOTO_FILE for initial encryption key..."
if [ ! -f "$BOTO_FILE" ]; then
    cat << EOF > "$BOTO_FILE"
[GSUtil]
encryption_key = $KEY1
EOF
else
    sed -i '/^#\?encryption_key/d' "$BOTO_FILE"
    sed -i '/^#\?decryption_key/d' "$BOTO_FILE"
    if ! grep -q "^\[GSUtil\]" "$BOTO_FILE"; then
        echo -e "\n[GSUtil]" >> "$BOTO_FILE"
    fi
    sed -i "/^\[GSUtil\]/a encryption_key = $KEY1" "$BOTO_FILE"
fi

echo "Uploading CSEK-encrypted objects setup2.html and setup3.html..."
gsutil kms encryption -d "gs://$BUCKET_NAME_1" 2>/dev/null || true
gsutil cp setup2.html "gs://$BUCKET_NAME_1/"
gsutil cp setup3.html "gs://$BUCKET_NAME_1/"

# Task 4: Rotate keys in .boto
echo "Rotating CSEK keys in $BOTO_FILE..."
sed -i '/^#\?encryption_key/d' "$BOTO_FILE"
sed -i '/^#\?decryption_key1/d' "$BOTO_FILE"
sed -i "/^\[GSUtil\]/a encryption_key = $KEY2\ndecryption_key1 = $KEY1" "$BOTO_FILE"

echo "Rewriting setup2.html with new encryption key..."
gsutil rewrite -k "gs://$BUCKET_NAME_1/setup2.html"

echo "Disabling decryption_key1 in $BOTO_FILE..."
sed -i 's/^decryption_key1/#decryption_key1/' "$BOTO_FILE"

# Test recovery
gsutil cp "gs://$BUCKET_NAME_1/setup2.html" recover2.html 2>/dev/null || true
rm -f recover2.html

# ==============================================================================
# 6. TASK 5: ENABLE LIFECYCLE MANAGEMENT
# ==============================================================================
echo "Creating lifecycle policy configuration life.json..."
cat << 'JSON_EOF' > life.json
{
  "rule": [
    {
      "action": { "type": "Delete" },
      "condition": { "age": 31 }
    }
  ]
}
JSON_EOF

echo "Applying lifecycle policy to gs://$BUCKET_NAME_1..."
gcloud storage buckets update "gs://$BUCKET_NAME_1" --lifecycle-file=life.json --quiet
gsutil lifecycle set life.json "gs://$BUCKET_NAME_1" 2>/dev/null || true

# ==============================================================================
# 7. TASK 6: ENABLE VERSIONING & RESTORE HISTORICAL VERSION
# ==============================================================================
echo "Enabling object versioning on gs://$BUCKET_NAME_1..."
gcloud storage buckets update "gs://$BUCKET_NAME_1" --versioning --quiet

echo "Creating additional versions of setup.html..."
echo "<p>Modified content for version 2</p>" >> setup.html
gcloud storage cp -v setup.html "gs://$BUCKET_NAME_1" --quiet
sleep 2

echo "<p>Modified content for version 3</p>" >> setup.html
gcloud storage cp -v setup.html "gs://$BUCKET_NAME_1" --quiet
sleep 2

echo "Listing all version generations for setup.html..."
gcloud storage ls -a "gs://$BUCKET_NAME_1/setup.html"

OLDEST_GENERATION=$(gcloud storage ls -a "gs://$BUCKET_NAME_1/setup.html" | sort | head -n1)
if [ -n "$OLDEST_GENERATION" ]; then
    echo "Restoring oldest generation ($OLDEST_GENERATION) to recovered.txt..."
    gcloud storage cp "$OLDEST_GENERATION" recovered.txt --quiet
fi

# ==============================================================================
# 8. TASK 7: RECURSIVE DIRECTORY SYNCHRONIZATION
# ==============================================================================
echo "Creating nested directory structure for synchronization..."
mkdir -p firstlevel/secondlevel
cp setup.html firstlevel/
cp setup.html firstlevel/secondlevel/

echo "Synchronizing directory recursively to gs://$BUCKET_NAME_1/firstlevel..."
gcloud storage rsync ./firstlevel "gs://$BUCKET_NAME_1/firstlevel" --recursive --quiet
gsutil -m rsync -r ./firstlevel "gs://$BUCKET_NAME_1/firstlevel" 2>/dev/null || true

# ==============================================================================
# 9. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Bucket Configuration:"
gcloud storage buckets describe "gs://$BUCKET_NAME_1" --format="yaml(name, location, iamConfiguration.uniformBucketLevelAccess, versioning)"

echo ""
echo "Lifecycle Configuration:"
gcloud storage buckets describe "gs://$BUCKET_NAME_1" --format="json(lifecycle_config)"

echo ""
echo "Public Access on setup.html:"
gcloud storage objects get-iam-policy "gs://$BUCKET_NAME_1/setup.html" \
    --flatten="bindings[].members" \
    --filter="bindings.members:allUsers" \
    --format="table(bindings.role)" || true

echo ""
echo "Object Version Generations:"
gcloud storage ls -a "gs://$BUCKET_NAME_1/setup.html"

echo ""
echo "Synchronized Directory Objects:"
gcloud storage ls -r "gs://$BUCKET_NAME_1/firstlevel"

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
