#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# You can also override them inline without modifying the script:
# e.g.: REGION="us-east1" ./script.sh
# ==============================================================================
export REGION="${REGION:-us-central1}"
export LOCATION="${LOCATION:-$REGION}"
export REPO_NAME="${REPO_NAME:-my-repository}"
export SERVICE_NAME="${SERVICE_NAME:-helloworld}"
export IMAGE_NAME="${IMAGE_NAME:-helloworld}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
# Auto-detect Google Cloud Project ID
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${GOOGLE_CLOUD_PROJECT:-$DEVSHELL_PROJECT_ID}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID : $PROJECT_ID"
echo "Region     : $REGION"
echo "Location   : $LOCATION"
echo "Repository : $REPO_NAME"
echo "Service    : $SERVICE_NAME"
echo "=================================================="

# Set active project and default compute region
gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet

# ==============================================================================
# 3. TASK 1: ENABLE REQUIRED GOOGLE APIS
# ==============================================================================
echo "Enabling Cloud Run, Artifact Registry, and Cloud Build APIs..."
gcloud services enable run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 4. TASK 2: WRITE SAMPLE APPLICATION
# ==============================================================================
echo "Creating application directory and source files..."
APP_DIR="$HOME/helloworld"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Create package.json
cat <<'EOF' > package.json
{
  "name": "helloworld",
  "description": "Simple hello world sample in Node",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "author": "Google LLC",
  "license": "Apache-2.0",
  "dependencies": {
    "express": "^4.17.1"
  }
}
EOF

# Create index.js
cat <<'EOF' > index.js
const express = require('express');
const app = express();
const port = process.env.PORT || 8080;

app.get('/', (req, res) => {
  const name = process.env.NAME || 'World';
  res.send(`Hello ${name}!`);
});

app.listen(port, () => {
  console.log(`helloworld: listening on port ${port}`);
});
EOF

# ==============================================================================
# 5. TASK 3: CREATE ARTIFACT REGISTRY REPOSITORY
# ==============================================================================
echo "Checking Artifact Registry repository: $REPO_NAME..."
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$LOCATION" &>/dev/null; then
    echo "Creating Docker repository $REPO_NAME in $LOCATION..."
    gcloud artifacts repositories create "$REPO_NAME" \
        --repository-format=docker \
        --location="$LOCATION" \
        --description="Docker repository" \
        --quiet
fi

# Configure docker credential helper for the location
gcloud auth configure-docker "${LOCATION}-docker.pkg.dev" --quiet || true

# ==============================================================================
# 6. TASK 4: CONTAINERIZE APP AND SUBMIT TO CLOUD BUILD
# ==============================================================================
echo "Creating Dockerfile..."
cat <<'EOF' > Dockerfile
FROM node:18-slim
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm install --only=production
COPY . ./
CMD [ "npm", "start" ]
EOF

IMAGE_URI="${LOCATION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"

echo "Building and uploading container image via Cloud Build..."
gcloud builds submit --tag "$IMAGE_URI" --quiet

# ==============================================================================
# 7. TASK 5: DEPLOY TO CLOUD RUN
# ==============================================================================
echo "Deploying service $SERVICE_NAME to Cloud Run..."
gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE_URI" \
    --allow-unauthenticated \
    --region="$LOCATION" \
    --quiet

# ==============================================================================
# 8. VERIFICATION
# ==============================================================================
echo "=================================================="
echo "RUNNING VERIFICATION"
echo "=================================================="
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region="$LOCATION" --format="value(status.url)" 2>/dev/null || true)

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ -n "$SERVICE_URL" ]; then
    echo "Service URL: $SERVICE_URL"
    RESPONSE=$(curl -s "$SERVICE_URL" || true)
    echo "Response: $RESPONSE"
    if echo "$RESPONSE" | grep -q "Hello World!"; then
        echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                                                                   ║${NC}"
        echo -e "${CYAN}║${GREEN}              [✓] LAB COMPLETED SUCCESSFULLY! [✓]                  ${CYAN}║${NC}"
        echo -e "${CYAN}║                                                                   ║${NC}"
        echo -e "${CYAN}║${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}║${NC}"
        echo -e "${CYAN}║                                                                   ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
    fi
else
    echo "Warning: Unable to fetch service URL automatically. Please verify via Cloud Console."
fi
