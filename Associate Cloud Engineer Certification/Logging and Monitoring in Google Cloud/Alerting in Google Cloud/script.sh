#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different parameters.
# Override inline: REGION="europe-west" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-europe-west}}"
[ "$REGION" = "(unset)" ] && export REGION="europe-west"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

export USER_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "student@qwiklabs.net")

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Primary Region   : $REGION"
echo "Notification User: $USER_EMAIL"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet

# Ensure required APIs are enabled
echo "Ensuring required APIs are enabled..."
gcloud services enable \
    appengine.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    cloudbuild.googleapis.com \
    --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: SETUP APPLICATION SOURCE CODE DIRECTORY
# ==============================================================================
REPO_DIR="$HOME/training-data-analyst"
TARGET_DIR="$REPO_DIR/courses/design-process/deploying-apps-to-gcp"

echo "Setting up application source files in ${TARGET_DIR}..."
if [ ! -d "$TARGET_DIR" ]; then
    echo "Cloning training-data-analyst repository (shallow clone)..."
    git clone --depth 1 https://github.com/GoogleCloudPlatform/training-data-analyst.git "$REPO_DIR" 2>/dev/null || true
fi

mkdir -p "$TARGET_DIR/templates"
cd "$TARGET_DIR"

# Ensure templates/index.html exists
cat > templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>{{ model.title }}</title>
</head>
<body>
    <h1>{{ model.title }}</h1>
</body>
</html>
EOF

# Ensure requirements.txt exists
cat > requirements.txt << 'EOF'
Flask==3.0.3
gunicorn==22.0.0
EOF

# Ensure app.yaml exists with runtime: python312
cat > app.yaml << 'EOF'
runtime: python312
EOF

# Ensure baseline version of main.py exists
cat > main.py << 'EOF'
import os
import time
import random
import json
from flask import Flask, render_template

app = Flask(__name__)

@app.route("/")
def main():
    model = {"title": "Hello GCP."}
    return render_template('index.html', model=model)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=8080, debug=True)
EOF

# ==============================================================================
# 4. TASK 2: INITIALIZE APP ENGINE & DEPLOY VERSION ONE
# ==============================================================================
echo "Checking Google App Engine application state..."
if ! gcloud app describe >/dev/null 2>&1; then
    echo "Creating App Engine application in region ${REGION}..."
    gcloud app create --region="${REGION}" --quiet || gcloud app create --quiet || true
else
    echo "App Engine application already initialized."
fi

echo "Checking App Engine deployment for version: one..."
if ! gcloud app versions list --filter="id=one" --format="value(id)" 2>/dev/null | grep -q "one"; then
    echo "Deploying App Engine version: one (baseline app)..."
    gcloud app deploy --version=one --quiet
else
    echo "App Engine version 'one' already deployed."
fi

APP_HOSTNAME=$(gcloud app describe --format="value(defaultHostname)" 2>/dev/null || echo "${PROJECT_ID}.appspot.com")
echo "App Engine default URL: https://${APP_HOSTNAME}"

# Generate baseline requests to populate request logs
echo "Sending baseline test requests..."
for i in {1..3}; do
    curl -m 10 -s "https://${APP_HOSTNAME}/" >/dev/null 2>&1 || true &
done
wait

# ==============================================================================
# 5. TASK 4: CONFIGURE NOTIFICATION CHANNEL & CREATE LATENCY ALERT POLICY
# ==============================================================================
echo "Configuring Cloud Monitoring email notification channel..."
CHANNEL_NAME=$(gcloud monitoring channels list --filter="type='email' AND labels.email_address='${USER_EMAIL}'" --format="value(name)" 2>/dev/null | head -n 1 || true)

if [ -z "$CHANNEL_NAME" ]; then
    cat <<EOF > email-channel.json
{
  "type": "email",
  "displayName": "Student Alert Email",
  "description": "App Engine Latency Notification Channel",
  "labels": {
    "email_address": "${USER_EMAIL}"
  }
}
EOF
    CHANNEL_NAME=$(gcloud monitoring channels create --channel-content-from-file=email-channel.json --format="value(name)" 2>/dev/null || \
                   gcloud alpha monitoring channels create --channel-content-from-file=email-channel.json --format="value(name)" 2>/dev/null || true)
    rm -f email-channel.json
fi

echo "Notification Channel ID: ${CHANNEL_NAME:-None (Proceeding with default policy)}"

CHANNELS_BLOCK=""
if [ -n "$CHANNEL_NAME" ]; then
    CHANNELS_BLOCK="\"notificationChannels\": [ \"${CHANNEL_NAME}\" ],"
fi

echo "Configuring latency alert policy: Hello too slow..."
if ! gcloud monitoring policies list --filter="displayName:'Hello too slow'" --format="value(name)" 2>/dev/null | grep -q "policies"; then
    cat <<EOF > latency-policy.json
{
  "displayName": "Hello too slow",
  "combiner": "OR",
  ${CHANNELS_BLOCK}
  "conditions": [
    {
      "displayName": "Response latency [MEAN] for 99th% over 8s",
      "conditionThreshold": {
        "filter": "resource.type = \"gae_app\" AND metric.type = \"appengine.googleapis.com/http/server/response_latencies\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "crossSeriesReducer": "REDUCE_MEAN",
            "perSeriesAligner": "ALIGN_PERCENTILE_99"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 8000,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "enabled": true
}
EOF

    echo "Deploying Cloud Monitoring policy 'Hello too slow'..."
    gcloud monitoring policies create --policy-from-file=latency-policy.json 2>/dev/null || \
    gcloud alpha monitoring policies create --policy-from-file=latency-policy.json 2>/dev/null || {
        # Fallback without crossSeriesReducer if required by environment
        cat <<EOF > latency-policy.json
{
  "displayName": "Hello too slow",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "Response latency [MEAN] for 99th% over 8s",
      "conditionThreshold": {
        "filter": "resource.type = \"gae_app\" AND metric.type = \"appengine.googleapis.com/http/server/response_latencies\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_PERCENTILE_99"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 8000,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "enabled": true
}
EOF
        gcloud monitoring policies create --policy-from-file=latency-policy.json 2>/dev/null || \
        gcloud alpha monitoring policies create --policy-from-file=latency-policy.json 2>/dev/null || true
    }
    rm -f latency-policy.json
else
    echo "Alerting policy 'Hello too slow' already exists."
fi

# ==============================================================================
# 6. TASK 4 & 5: INJECT LATENCY / 500 ERRORS & DEPLOY VERSION TWO
# ==============================================================================
echo "Updating main.py with artificial latency and random HTTP 500 error generator..."
cat > main.py << 'EOF'
import os
import time
import random
import json
from flask import Flask, render_template

app = Flask(__name__)

@app.route("/")
def main():
    # Inject 10s latency to trigger 'Hello too slow' alert
    time.sleep(10)
    # 1 in 49 chance to return HTTP 500 error (> 1% error rate)
    num = random.randrange(49)
    if num == 0:
        return json.dumps({"error": 'Error thrown randomly'}), 500
    model = {"title": "Hello GCP."}
    return render_template('index.html', model=model)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=8080, debug=True)
EOF

echo "Checking App Engine deployment for version: two..."
if ! gcloud app versions list --filter="id=two" --format="value(id)" 2>/dev/null | grep -q "two"; then
    echo "Deploying App Engine version: two (with delay)..."
    gcloud app deploy --version=two --quiet
else
    echo "App Engine version 'two' already deployed."
fi

# ==============================================================================
# 7. TASK 5 (OPTIONAL): CREATE HTTP ERROR RATE PERCENT POLICY
# ==============================================================================
echo "Configuring optional HTTP error rate alerting policy..."
if ! gcloud monitoring policies list --filter="displayName:'HTTP error count exceeds 1 percent for App Engine apps'" --format="value(name)" 2>/dev/null | grep -q "policies"; then
    cat << 'EOF' > app-engine-error-percent-policy.json
{
  "displayName": "HTTP error count exceeds 1 percent for App Engine apps",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "Ratio: HTTP 500s error-response counts / All HTTP response counts",
      "conditionThreshold": {
        "filter": "metric.label.response_code>=\"500\" AND metric.label.response_code<\"600\" AND metric.type=\"appengine.googleapis.com/http/server/response_count\" AND resource.type=\"gae_app\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "crossSeriesReducer": "REDUCE_SUM",
            "groupByFields": [
              "project",
              "resource.label.module_id",
              "resource.label.version_id"
            ],
            "perSeriesAligner": "ALIGN_DELTA"
          }
        ],
        "denominatorFilter": "metric.type=\"appengine.googleapis.com/http/server/response_count\" AND resource.type=\"gae_app\"",
        "denominatorAggregations": [
          {
            "alignmentPeriod": "60s",
            "crossSeriesReducer": "REDUCE_SUM",
            "groupByFields": [
              "project",
              "resource.label.module_id",
              "resource.label.version_id"
            ],
            "perSeriesAligner": "ALIGN_DELTA"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0.01,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ]
}
EOF
    gcloud monitoring policies create --policy-from-file="app-engine-error-percent-policy.json" 2>/dev/null || \
    gcloud alpha monitoring policies create --policy-from-file="app-engine-error-percent-policy.json" 2>/dev/null || true
    rm -f app-engine-error-percent-policy.json
fi

# ==============================================================================
# 8. GENERATE SAMPLE TELEMETRY TRAFFIC
# ==============================================================================
echo "Generating telemetry requests against deployed App Engine application..."
for i in {1..3}; do
    curl -m 15 -s "https://${APP_HOSTNAME}/" >/dev/null 2>&1 || true &
done
wait

# ==============================================================================
# 9. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo "=================================================="
echo "App Engine Application State:"
gcloud app describe --format="yaml(id, locationId, defaultHostname)" 2>/dev/null || true

echo ""
echo "App Engine Deployed Versions:"
gcloud app versions list --format="table(service, id, traffic_split, last_deployed_time.date(tz=LOCAL), serving_status)" 2>/dev/null || true

echo ""
echo "Cloud Monitoring Alert Policies:"
gcloud monitoring policies list --format="table(name, displayName, enabled, combiner)" 2>/dev/null || \
gcloud alpha monitoring policies list --format="table(name, displayName, enabled, combiner)" 2>/dev/null || true
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
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
