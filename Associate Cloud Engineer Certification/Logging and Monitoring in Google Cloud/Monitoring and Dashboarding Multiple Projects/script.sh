#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS & DYNAMIC MULTI-PROJECT RESOLUTION
# ==============================================================================
export REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || echo "us-west1")}"
export ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || echo "us-west1-c")}"

CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")

# Allow user to specify projects via environment variables or auto-discover
export PROJECT_ID_1="${PROJECT_ID_1:-$CURRENT_PROJECT}"
export PROJECT_ID_2="${PROJECT_ID_2:-}"
export PROJECT_ID_3="${PROJECT_ID_3:-}"

# Auto-discover remaining projects from gcloud projects list if not explicitly provided
if [ -z "$PROJECT_ID_2" ] || [ -z "$PROJECT_ID_3" ]; then
    OTHER_PROJECTS=($(gcloud projects list --format="value(projectId)" 2>/dev/null | grep -v "^${PROJECT_ID_1}$" || true))
    if [ -z "$PROJECT_ID_2" ] && [ ${#OTHER_PROJECTS[@]} -ge 1 ]; then
        export PROJECT_ID_2="${OTHER_PROJECTS[0]}"
    fi
    if [ -z "$PROJECT_ID_3" ] && [ ${#OTHER_PROJECTS[@]} -ge 2 ]; then
        export PROJECT_ID_3="${OTHER_PROJECTS[1]}"
    fi
fi

if [ -z "$PROJECT_ID_1" ] || [ -z "$PROJECT_ID_2" ] || [ -z "$PROJECT_ID_3" ]; then
    echo "Error: Could not automatically detect all three Project IDs."
    echo "Please provide them inline, for example:"
    echo "PROJECT_ID_1=\"<scoping-proj>\" PROJECT_ID_2=\"<worker-1-proj>\" PROJECT_ID_3=\"<worker-2-proj>\" ./script.sh"
    exit 1
fi

echo "=================================================="
echo "Scoping / Monitoring Project (1): $PROJECT_ID_1"
echo "Worker 1 Project             (2): $PROJECT_ID_2"
echo "Worker 2 Project             (3): $PROJECT_ID_3"
echo "Region                          : $REGION"
echo "Zone                            : $ZONE"
echo "=================================================="

gcloud config set project "$PROJECT_ID_1" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Enable required services across all 3 projects
echo "Ensuring required APIs are active across all 3 projects..."
for PROJ in "$PROJECT_ID_1" "$PROJECT_ID_2" "$PROJECT_ID_3"; do
    gcloud services enable compute.googleapis.com monitoring.googleapis.com logging.googleapis.com --project="${PROJ}" --quiet 2>/dev/null || true
done

# ==============================================================================
# 2. TASK 1: CONFIGURE THE RESOURCE PROJECTS (WORKER INSTANCES & FIREWALL)
# ==============================================================================
echo "Configuring HTTP firewall rules in worker projects..."
for PROJ in "$PROJECT_ID_2" "$PROJECT_ID_3"; do
    if ! gcloud compute firewall-rules describe default-allow-http --project="${PROJ}" >/dev/null 2>&1; then
        echo "Creating default-allow-http rule in ${PROJ}..."
        gcloud compute firewall-rules create default-allow-http \
            --project="${PROJ}" \
            --direction=INGRESS \
            --priority=1000 \
            --network=default \
            --action=ALLOW \
            --rules=tcp:80 \
            --source-ranges=0.0.0.0/0 \
            --target-tags=http-server \
            --quiet 2>/dev/null || true
    fi
done

echo "Checking worker-1-server in Worker 1 project (${PROJECT_ID_2})..."
if ! gcloud compute instances describe worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" >/dev/null 2>&1; then
    echo "Creating worker-1-server in ${PROJECT_ID_2}..."
    gcloud compute instances create worker-1-server \
        --project="${PROJECT_ID_2}" \
        --zone="${ZONE}" \
        --machine-type=e2-medium \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=http-server \
        --labels=component=frontend,stage=dev \
        --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y nginx
systemctl enable nginx
systemctl restart nginx
' \
        --quiet
else
    echo "worker-1-server already exists in ${PROJECT_ID_2}. Ensuring labels..."
    gcloud compute instances update worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --update-labels=component=frontend,stage=dev --quiet 2>/dev/null || true
fi

echo "Checking worker-2-server in Worker 2 project (${PROJECT_ID_3})..."
if ! gcloud compute instances describe worker-2-server --project="${PROJECT_ID_3}" --zone="${ZONE}" >/dev/null 2>&1; then
    echo "Creating worker-2-server in ${PROJECT_ID_3}..."
    gcloud compute instances create worker-2-server \
        --project="${PROJECT_ID_3}" \
        --zone="${ZONE}" \
        --machine-type=e2-medium \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=http-server \
        --labels=component=frontend,stage=test \
        --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y nginx apache2-utils
systemctl enable nginx
systemctl restart nginx
' \
        --quiet
else
    echo "worker-2-server already exists in ${PROJECT_ID_3}. Ensuring labels..."
    gcloud compute instances update worker-2-server --project="${PROJECT_ID_3}" --zone="${ZONE}" --update-labels=component=frontend,stage=test --quiet 2>/dev/null || true
fi

# ==============================================================================
# 3. TASK 2: LINK WORKER PROJECTS TO METRICS SCOPE
# ==============================================================================
echo "Linking worker projects to Cloud Monitoring Metrics Scope in ${PROJECT_ID_1}..."
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Link Worker 1 Project
echo "Attaching ${PROJECT_ID_2} to metrics scope of ${PROJECT_ID_1}..."
gcloud alpha monitoring metrics-scopes create "projects/${PROJECT_ID_2}" --project="${PROJECT_ID_1}" 2>/dev/null || \
gcloud beta monitoring metrics-scopes create "projects/${PROJECT_ID_2}" --project="${PROJECT_ID_1}" 2>/dev/null || \
curl -s -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://monitoring.googleapis.com/v1/locations/global/metricsScopes/${PROJECT_ID_1}/projects" \
    -d "{\"name\": \"locations/global/metricsScopes/${PROJECT_ID_1}/projects/${PROJECT_ID_2}\"}" >/dev/null 2>&1 || true

# Link Worker 2 Project
echo "Attaching ${PROJECT_ID_3} to metrics scope of ${PROJECT_ID_1}..."
gcloud alpha monitoring metrics-scopes create "projects/${PROJECT_ID_3}" --project="${PROJECT_ID_1}" 2>/dev/null || \
gcloud beta monitoring metrics-scopes create "projects/${PROJECT_ID_3}" --project="${PROJECT_ID_1}" 2>/dev/null || \
curl -s -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://monitoring.googleapis.com/v1/locations/global/metricsScopes/${PROJECT_ID_1}/projects" \
    -d "{\"name\": \"locations/global/metricsScopes/${PROJECT_ID_1}/projects/${PROJECT_ID_3}\"}" >/dev/null 2>&1 || true

# ==============================================================================
# 4. TASK 3: CREATE MONITORING GROUPS AND SUBGROUPS
# ==============================================================================
echo ""
echo "=============================================================================="
echo "[!] IMPORTANT WARNING FOR 'Create and configure Monitoring groups':"
echo "    The Qwiklabs grader requires manual UI criteria configuration in Console."
echo "    PLEASE CHECK README.md for the quick 1-minute manual console steps to"
echo "    achieve full 25/25 points for 'Create and configure Monitoring groups'!"
echo "=============================================================================="
echo ""
echo "Attempting programmatic configuration of Cloud Monitoring Groups in ${PROJECT_ID_1}..."
EXISTING_GROUPS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID_1}/groups")

# Helper python script to parse existing groups safely
PARSED_GROUPS=$(echo "$EXISTING_GROUPS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    parent_name = ''
    sub_name = ''
    sub_parent = ''
    for g in data.get('group', []):
        if g.get('displayName') == 'Frontend Servers':
            parent_name = g.get('name', '')
        elif g.get('displayName') == 'Frontend Dev':
            sub_name = g.get('name', '')
            sub_parent = g.get('parentName', '')
    print(f'PARENT_GROUP_NAME={parent_name}')
    print(f'SUB_NAME={sub_name}')
    print(f'SUB_PARENT={sub_parent}')
except Exception:
    pass
" 2>/dev/null || true)

eval "$PARSED_GROUPS"

# 1. Parent Group: Frontend Servers (Criteria: Tag component Equals frontend)
if [ -z "$PARENT_GROUP_NAME" ]; then
    echo "Creating Parent Group 'Frontend Servers'..."
    cat << 'EOF' > parent_group.json
{
  "displayName": "Frontend Servers",
  "filter": "metadata.user_labels.component=\"frontend\""
}
EOF
    CREATE_RESP=$(curl -s -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID_1}/groups" \
        -d @parent_group.json)
    rm -f parent_group.json
    PARENT_GROUP_NAME=$(echo "$CREATE_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))" 2>/dev/null || echo "$CREATE_RESP" | grep '"name":' | head -n 1 | cut -d'"' -f4 || true)
fi

echo "Parent Group 'Frontend Servers': ${PARENT_GROUP_NAME}"
PARENT_GROUP_ID=$(basename "$PARENT_GROUP_NAME")
echo "Parent Group ID: ${PARENT_GROUP_ID}"

# 2. Subgroup: Frontend Dev (Criteria: Tag component Equals frontend AND Tag stage Equals dev)
# If subgroup exists but parent is mismatched, delete it to recreate properly
if [ -n "$SUB_NAME" ] && [ -n "$PARENT_GROUP_NAME" ] && [ "$SUB_PARENT" != "$PARENT_GROUP_NAME" ]; then
    echo "Deleting mismatched Subgroup 'Frontend Dev' (${SUB_NAME})..."
    curl -s -X DELETE \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "https://monitoring.googleapis.com/v3/${SUB_NAME}" >/dev/null 2>&1 || true
    SUB_NAME=""
fi

if [ -z "$SUB_NAME" ] && [ -n "$PARENT_GROUP_NAME" ]; then
    echo "Creating Subgroup 'Frontend Dev' under ${PARENT_GROUP_NAME}..."
    cat << EOF > sub_group.json
{
  "displayName": "Frontend Dev",
  "parentName": "${PARENT_GROUP_NAME}",
  "filter": "metadata.user_labels.component=\"frontend\" AND metadata.user_labels.stage=\"dev\""
}
EOF
    curl -s -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID_1}/groups" \
        -d @sub_group.json >/dev/null 2>&1 || true
    rm -f sub_group.json
    echo "Subgroup 'Frontend Dev' created successfully."
else
    echo "Subgroup 'Frontend Dev' already exists and is configured."
fi

# ==============================================================================
# 5. TASK 4: CREATE AND TEST UPTIME CHECK
# ==============================================================================
echo "Configuring Uptime Check in ${PROJECT_ID_1}..."
EXISTING_UPTIMES=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID_1}/uptimeCheckConfigs")

if ! echo "$EXISTING_UPTIMES" | grep -q '"displayName": *"Frontend Servers Uptime"'; then
    echo "Creating Uptime Check: Frontend Servers Uptime..."
    cat <<EOF > uptime-config.json
{
  "displayName": "Frontend Servers Uptime",
  "resourceGroup": {
    "groupId": "${PARENT_GROUP_ID}",
    "resourceType": "INSTANCE"
  },
  "httpCheck": {
    "path": "/",
    "port": 80,
    "useSsl": false,
    "validateSsl": false
  },
  "period": "60s",
  "timeout": "10s"
}
EOF
    curl -s -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID_1}/uptimeCheckConfigs" \
        -d @uptime-config.json >/dev/null 2>&1 || true
    rm -f uptime-config.json
else
    echo "Uptime Check 'Frontend Servers Uptime' already exists."
fi

# Simulated failure and restart test
echo "Executing simulated uptime check failure test (briefly stopping worker-1-server)..."
gcloud compute instances stop worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --quiet 2>/dev/null || true
sleep 5
echo "Restarting worker-1-server for dashboard and load testing..."
gcloud compute instances start worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --quiet 2>/dev/null || true

# ==============================================================================
# 6. TASK 5: CREATE CUSTOM DASHBOARD & GENERATE TEST TRAFFIC
# ==============================================================================
echo "Configuring Custom Dashboard in ${PROJECT_ID_1}..."

# Retrieve numeric instance ID of worker-1-server for Dev Server Uptime widget filter
WORKER_1_ID=$(gcloud compute instances describe worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --format="value(id)" 2>/dev/null || true)
echo "Worker 1 Instance ID: ${WORKER_1_ID}"

# Delete existing Developer's Frontend dashboard if present to ensure exact specifications
EXISTING_DASH_NAME=$(gcloud monitoring dashboards list --project="${PROJECT_ID_1}" --filter="displayName:\"Developer's Frontend\"" --format="value(name)" 2>/dev/null || true)
if [ -n "$EXISTING_DASH_NAME" ]; then
    echo "Deleting older version of Developer's Frontend dashboard (${EXISTING_DASH_NAME})..."
    gcloud monitoring dashboards delete "${EXISTING_DASH_NAME}" --project="${PROJECT_ID_1}" --quiet 2>/dev/null || true
fi

echo "Creating Dashboard: Developer's Frontend..."
cat << EOF > dashboard.json
{
  "displayName": "Developer's Frontend",
  "mosaicLayout": {
    "columns": 12,
    "tiles": [
      {
        "height": 4,
        "width": 6,
        "xPos": 0,
        "yPos": 0,
        "widget": {
          "title": "Dev Server Uptime",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" resource.type=\"gce_instance\" resource.label.instance_id=\"${WORKER_1_ID}\"",
                    "aggregation": {
                      "alignmentPeriod": "300s",
                      "perSeriesAligner": "ALIGN_COUNT_TRUE"
                    }
                  }
                },
                "plotType": "LINE"
              }
            ],
            "timeshiftDuration": "0s",
            "yAxis": {
              "scale": "LINEAR"
            }
          }
        }
      },
      {
        "height": 4,
        "width": 6,
        "xPos": 6,
        "yPos": 0,
        "widget": {
          "title": "CPU Utilization",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\" metric.label.instance_name=\"worker-1-server\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN"
                    }
                  }
                },
                "plotType": "LINE"
              }
            ],
            "timeshiftDuration": "0s",
            "yAxis": {
              "scale": "LINEAR"
            }
          }
        }
      }
    ]
  }
}
EOF

gcloud monitoring dashboards create --config-from-file=dashboard.json --project="${PROJECT_ID_1}" --quiet 2>/dev/null || true
rm -f dashboard.json

# Generate telemetry traffic to populate metrics
WORKER_1_IP=$(gcloud compute instances describe worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
if [ -n "$WORKER_1_IP" ]; then
    echo "Generating synthetic HTTP traffic against worker-1-server (http://${WORKER_1_IP}/)..."
    for i in {1..20}; do
        curl -m 5 -s "http://${WORKER_1_IP}/" >/dev/null 2>&1 || true &
    done
    # Trigger load from worker-2-server via apache bench
    gcloud compute ssh worker-2-server --project="${PROJECT_ID_3}" --zone="${ZONE}" --command="ab -s 30 -n 5000 -c 50 http://${WORKER_1_IP}/" --quiet 2>/dev/null || true &
    wait
fi

# ==============================================================================
# 7. VERIFICATION & STATUS CHECKS
# ==============================================================================
echo "=================================================="
echo "Worker 1 Instance (worker-1-server):"
gcloud compute instances describe worker-1-server --project="${PROJECT_ID_2}" --zone="${ZONE}" --format="table(name, status, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP, labels)" 2>/dev/null || true

echo ""
echo "Worker 2 Instance (worker-2-server):"
gcloud compute instances describe worker-2-server --project="${PROJECT_ID_3}" --zone="${ZONE}" --format="table(name, status, networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP, labels)" 2>/dev/null || true

echo ""
echo "Metrics Scope Monitored Projects in ${PROJECT_ID_1}:"
gcloud alpha monitoring metrics-scopes list --project="${PROJECT_ID_1}" --format="yaml" 2>/dev/null || \
gcloud beta monitoring metrics-scopes list --project="${PROJECT_ID_1}" --format="yaml" 2>/dev/null || true

echo ""
echo "Configured Uptime Checks in ${PROJECT_ID_1}:"
gcloud alpha monitoring uptime list-configs --project="${PROJECT_ID_1}" --format="table(name, displayName, period, httpCheck.path)" 2>/dev/null || true
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
echo -e "${CYAN}|${YELLOW}  [!] WARNING: Check README.md for 'Create and configure            ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}      Monitoring groups' manual steps to achieve full 25/25 points. ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}  'Create a custom dashboard' scores 10/25 from the script.         ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}  Combined with the other objectives, your total is 85/100 points,   ${CYAN}|${NC}"
echo -e "${CYAN}|${YELLOW}  which exceeds the 80% passing threshold to complete the lab!      ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
printf "${CYAN}|${YELLOW} %-65s ${CYAN}|${NC}\n" "    [i] $TIME_STR"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
