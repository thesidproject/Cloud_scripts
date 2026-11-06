#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-east1" ./script.sh
# ==============================================================================
export REGION="${REGION:-us-central1}"
export BUCKET_NAME_1="${BUCKET_NAME_1:-}"
export BUCKET_NAME_2="${BUCKET_NAME_2:-}"
export MY_FILE="${MY_FILE:-sample.txt}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
# Auto-detect Project ID
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# Check if a bucket was already created manually in Console (Task 1)
EXISTING_BUCKETS=$(gcloud storage buckets list --format="value(name)" 2>/dev/null || true)
FIRST_EXISTING=$(echo "$EXISTING_BUCKETS" | head -n 1)

if [ -z "$BUCKET_NAME_1" ]; then
    if [ -n "$FIRST_EXISTING" ]; then
        export BUCKET_NAME_1="$FIRST_EXISTING"
        echo "Detected bucket created via Console: gs://$BUCKET_NAME_1"
    else
        export BUCKET_NAME_1="${PROJECT_ID}-console-bucket"
    fi
fi

if [ -z "$BUCKET_NAME_2" ]; then
    export BUCKET_NAME_2="${PROJECT_ID}-shell-bucket"
fi

# Ensure bucket 2 has a distinct name from bucket 1
if [ "$BUCKET_NAME_2" = "$BUCKET_NAME_1" ]; then
    export BUCKET_NAME_2="${PROJECT_ID}-shell-bucket-2"
fi

echo "=================================================="
echo "Project ID : $PROJECT_ID"
echo "Region     : $REGION"
echo "Bucket 1   : $BUCKET_NAME_1"
echo "Bucket 2   : $BUCKET_NAME_2"
echo "=================================================="

# ==============================================================================
# 3. TASK 1: CREATE FIRST BUCKET (MATCHING CONSOLE DEFAULTS)
# ==============================================================================
echo "Checking first bucket gs://$BUCKET_NAME_1..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME_1" &>/dev/null; then
    echo "Creating bucket gs://$BUCKET_NAME_1 using console default specifications..."
    gcloud storage buckets create "gs://$BUCKET_NAME_1" \
        --default-storage-class=STANDARD \
        --location=US \
        --uniform-bucket-level-access \
        --public-access-prevention \
        --quiet
else
    echo "First bucket gs://$BUCKET_NAME_1 is ready."
fi

# ==============================================================================
# 4. TASK 3: CREATE SECOND BUCKET (VIA CLOUD SHELL)
# ==============================================================================
echo "Checking second bucket gs://$BUCKET_NAME_2..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME_2" &>/dev/null; then
    echo "Creating second bucket gs://$BUCKET_NAME_2 in $REGION..."
    gcloud storage buckets create "gs://$BUCKET_NAME_2" \
        --location="$REGION" \
        --quiet
else
    echo "Second bucket gs://$BUCKET_NAME_2 already exists."
fi

# ==============================================================================
# 5. TASK 4: UPLOAD FILE AND TRANSFER TO BUCKET
# ==============================================================================
echo "Preparing sample file to upload..."
if [ ! -f "$MY_FILE" ]; then
    echo "Welcome to Google Cloud Storage" > "$MY_FILE"
fi

echo "Copying $MY_FILE to gs://$BUCKET_NAME_1..."
gcloud storage cp "$MY_FILE" "gs://$BUCKET_NAME_1/$MY_FILE" --quiet

# ==============================================================================
# 6. TASK 5: CREATE PERSISTENT STATE IN CLOUD SHELL
# ==============================================================================
echo "Configuring persistent environment variables..."
INFRACLASS_REGION="$REGION"
INFRACLASS_PROJECT_ID="$PROJECT_ID"

mkdir -p "$HOME/infraclass"
echo "export INFRACLASS_REGION=$INFRACLASS_REGION" > "$HOME/infraclass/config"
echo "export INFRACLASS_PROJECT_ID=$INFRACLASS_PROJECT_ID" >> "$HOME/infraclass/config"

if ! grep -q "source ~/infraclass/config" "$HOME/.profile" 2>/dev/null; then
    echo "source ~/infraclass/config" >> "$HOME/.profile"
fi

# Reload profile in current shell
# shellcheck source=/dev/null
source "$HOME/.profile"

# ==============================================================================
# 7. VERIFICATION
# ==============================================================================
echo "=================================================="
echo "RUNNING VERIFICATION"
echo "=================================================="
echo "Listing all storage buckets in the project:"
gcloud storage buckets list

echo "Listing contents of gs://$BUCKET_NAME_1:"
gcloud storage ls "gs://$BUCKET_NAME_1"

echo "Persistent Environment Variables:"
echo "INFRACLASS_PROJECT_ID : $INFRACLASS_PROJECT_ID"
echo "INFRACLASS_REGION     : $INFRACLASS_REGION"

echo "SUCCESS: All lab requirements are satisfied! Click 'Check My Progress'."
