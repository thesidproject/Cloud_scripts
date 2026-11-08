#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: REGION="us-east4" ./script.sh
# ==============================================================================
export REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-east4")}"
export REPO_NAME="${REPO_NAME:-quickstart-docker-repo}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/quickstart-image:tag1"

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Location/Region  : $REGION"
echo "Repository Name  : $REPO_NAME"
echo "Image Target     : $IMAGE_TAG"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet

# ==============================================================================
# 3. TASK 1: CONFIRM NEEDED APIS ARE ENABLED
# ==============================================================================
echo "Enabling required APIs (Cloud Build & Artifact Registry)..."
gcloud services enable cloudbuild.googleapis.com artifactregistry.googleapis.com --quiet

# ==============================================================================
# 4. TASK 2: BUILD CONTAINERS WITH DOCKERFILE & CLOUD BUILD
# ==============================================================================
echo "Creating application script: quickstart.sh..."
cat << 'EOF' > quickstart.sh
#!/bin/sh
echo "Hello, world! The time is $(date)."
EOF
chmod +x quickstart.sh

echo "Creating Dockerfile..."
cat << 'EOF' > Dockerfile
FROM alpine
COPY quickstart.sh /
CMD [ "/quickstart.sh" ]
EOF

echo "Checking Artifact Registry repository: $REPO_NAME in $REGION..."
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --quiet >/dev/null 2>&1; then
    echo "Creating Artifact Registry repository $REPO_NAME..."
    gcloud artifacts repositories create "$REPO_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --description="Docker repository" \
        --quiet
else
    echo "Repository $REPO_NAME already exists."
fi

echo "Building and submitting initial container image directly to Artifact Registry..."
gcloud builds submit --tag "$IMAGE_TAG" --quiet

# ==============================================================================
# 5. TASK 3: BUILD CONTAINERS WITH A BUILD CONFIGURATION FILE
# ==============================================================================
echo "Creating cloudbuild.yaml..."
cat << EOF > cloudbuild.yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: [ 'build', '-t', '${REGION}-docker.pkg.dev/\$PROJECT_ID/${REPO_NAME}/quickstart-image:tag1', '.' ]
images:
- '${REGION}-docker.pkg.dev/\$PROJECT_ID/${REPO_NAME}/quickstart-image:tag1'
EOF

echo "Submitting build using cloudbuild.yaml..."
gcloud builds submit --config cloudbuild.yaml --quiet

# ==============================================================================
# 6. TASK 4: TEST CONTAINERS USING BUILD CONFIGURATION FILE (INTENTIONAL FAILURE)
# ==============================================================================
echo "Updating quickstart.sh to simulate test failure..."
cat << 'EOF' > quickstart.sh
#!/bin/sh
if [ -z "$1" ]
then
    echo "Hello, world! The time is $(date)."
    exit 0
else
    exit 1
fi
EOF
chmod +x quickstart.sh

echo "Creating cloudbuild2.yaml with container test step..."
cat << EOF > cloudbuild2.yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: [ 'build', '-t', '${REGION}-docker.pkg.dev/\$PROJECT_ID/${REPO_NAME}/quickstart-image:tag1', '.' ]
- name: '${REGION}-docker.pkg.dev/\$PROJECT_ID/${REPO_NAME}/quickstart-image:tag1'
  args: ['fail']
images:
- '${REGION}-docker.pkg.dev/\$PROJECT_ID/${REPO_NAME}/quickstart-image:tag1'
EOF

echo "Submitting build with cloudbuild2.yaml (intentional pipeline test failure)..."
# The test step is expected to return status FAILURE; catch the non-zero exit code to prevent premature script termination
gcloud builds submit --config cloudbuild2.yaml 2>&1 || true

# ==============================================================================
# 7. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="

echo "Artifact Registry Repository Details:"
gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --format="yaml(name, format, description)"

echo ""
echo "Docker Images in Repository:"
gcloud artifacts docker images list "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}" || true

echo ""
echo "Recent Cloud Build Executions:"
gcloud builds list --limit=5 --format="table(id, createTime, status, source.storageSource.object)"

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
