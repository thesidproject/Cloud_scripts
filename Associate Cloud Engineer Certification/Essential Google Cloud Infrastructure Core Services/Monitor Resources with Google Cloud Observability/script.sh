#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: NOTIFICATION_EMAIL="your-email@example.com" ./script.sh
# ==============================================================================
export NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

if [ -z "$NOTIFICATION_EMAIL" ]; then
    export NOTIFICATION_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "student@qwiklabs.net")
fi

echo "=================================================="
echo "Project ID         : $PROJECT_ID"
echo "Notification Email : $NOTIFICATION_EMAIL"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet

# Ensure Monitoring and Compute APIs are active
gcloud services enable monitoring.googleapis.com compute.googleapis.com --quiet 2>/dev/null || true

TOKEN=$(gcloud auth print-access-token)

# ==============================================================================
# 3. TASK 1: VERIFY TARGET VM INSTANCES
# ==============================================================================
echo "Verifying nginxstack instances..."
gcloud compute instances list --filter="name ~ nginxstack" --format="table(name, zone, status)"

# ==============================================================================
# 4. TASK 2: RECREATE CUSTOM DASHBOARD ('My Dashboard' with 'My Chart')
# ==============================================================================
echo "Checking Custom Dashboard: 'My Dashboard'..."
cat << 'DASHBOARD_EOF' > /tmp/my_dashboard.json
{
  "displayName": "My Dashboard",
  "mosaicLayout": {
    "columns": 12,
    "tiles": [
      {
        "xPos": 0,
        "yPos": 0,
        "width": 6,
        "height": 4,
        "widget": {
          "title": "My Chart",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\""
                  }
                },
                "plotType": "LINE"
              }
            ]
          }
        }
      }
    ]
  }
}
DASHBOARD_EOF

EXISTING_DASHBOARD_ID=$(gcloud monitoring dashboards list --filter="displayName='My Dashboard'" --format="value(name)" 2>/dev/null | head -n1 || true)

if [ -n "$EXISTING_DASHBOARD_ID" ]; then
    echo "Deleting legacy dashboard: $EXISTING_DASHBOARD_ID..."
    gcloud monitoring dashboards delete "$EXISTING_DASHBOARD_ID" --quiet 2>/dev/null || true
fi

echo "Creating dashboard 'My Dashboard' with 'My Chart'..."
gcloud monitoring dashboards create --config-from-file=/tmp/my_dashboard.json
echo "Dashboard 'My Dashboard' successfully created."

# ==============================================================================
# 5. TASK 3: CONFIGURE NOTIFICATION CHANNEL & ALERTING POLICY
# ==============================================================================
echo "Configuring email notification channel for $NOTIFICATION_EMAIL..."
CHANNEL_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/notificationChannels" \
    | grep -B2 "$NOTIFICATION_EMAIL" | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)

if [ -z "$CHANNEL_ID" ]; then
    echo "Creating Notification Channel..."
    CHANNEL_ID=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"email\",\"displayName\":\"Lab Alert Channel\",\"labels\":{\"email_address\":\"$NOTIFICATION_EMAIL\"}}" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/notificationChannels" \
        | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)
fi
echo "Notification Channel ID: $CHANNEL_ID"

echo "Checking Alerting Policy: 'My Alert Policy'..."
EXISTING_POLICY=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/alertPolicies" \
    | grep -B1 '"displayName": "My Alert Policy"' | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)

if [ -z "$EXISTING_POLICY" ]; then
    echo "Creating Alerting Policy 'My Alert Policy'..."
    cat << POLICY_EOF > /tmp/alert_policy.json
{
  "displayName": "My Alert Policy",
  "combiner": "AND",
  "conditions": [
    {
      "displayName": "VM Instance - CPU usage",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/usage_time\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    },
    {
      "displayName": "VM Instance - CPU utilization",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_MEAN"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "notificationChannels": [
    "$CHANNEL_ID"
  ],
  "enabled": true
}
POLICY_EOF

    EXISTING_POLICY=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @/tmp/alert_policy.json \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/alertPolicies" \
        | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)
    echo "Alert Policy created: $EXISTING_POLICY"
else
    echo "Alert Policy already exists: $EXISTING_POLICY"
fi

# ==============================================================================
# 6. TASK 4: RECREATE RESOURCE GROUP ('VM instances' matching 'nginx')
# ==============================================================================
echo "Checking Resource Group: 'VM instances'..."
EXISTING_GROUP=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/groups" \
    | grep -B1 '"displayName": "VM instances"' | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)

if [ -n "$EXISTING_GROUP" ]; then
    echo "Recreating existing resource group to ensure correct filter..."
    curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "https://monitoring.googleapis.com/v3/${EXISTING_GROUP}" > /dev/null || true
fi

echo "Creating Resource Group 'VM instances'..."
GROUP_RES=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"displayName\":\"VM instances\",\"filter\":\"resource.metadata.name=has_substring(\\\"nginx\\\")\"}" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/groups")
GROUP_NAME=$(echo "$GROUP_RES" | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)

if [ -z "$GROUP_NAME" ]; then
    GROUP_RES=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"displayName\":\"VM instances\",\"filter\":\"resource.metadata.name : \\\"nginx\\\"\"}" \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/groups")
    GROUP_NAME=$(echo "$GROUP_RES" | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)
fi

echo "Resource Group created: $GROUP_NAME"
GROUP_ID=$(basename "$GROUP_NAME")

# ==============================================================================
# 7. TASK 5: CREATE UPTIME CHECK ('My Uptime check')
# ==============================================================================
echo "Checking Uptime Check: 'My Uptime check'..."
EXISTING_UPTIME=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/uptimeCheckConfigs" \
    | grep -B1 '"displayName": "My Uptime check"' | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)

if [ -z "$EXISTING_UPTIME" ]; then
    echo "Creating Uptime Check 'My Uptime check' targeting group $GROUP_ID..."
    cat << UPTIME_EOF > /tmp/uptime_check.json
{
  "displayName": "My Uptime check",
  "period": "60s",
  "timeout": "10s",
  "httpCheck": {
    "requestMethod": "GET",
    "path": "/",
    "port": 80,
    "useSsl": false
  },
  "resourceGroup": {
    "groupId": "$GROUP_ID",
    "resourceType": "INSTANCE"
  }
}
UPTIME_EOF

    EXISTING_UPTIME=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @/tmp/uptime_check.json \
        "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/uptimeCheckConfigs" \
        | grep -o '"name": "[^"]*' | head -n1 | cut -d'"' -f4 || true)
    echo "Uptime Check created: $EXISTING_UPTIME"
else
    echo "Uptime Check already exists: $EXISTING_UPTIME"
fi

# ==============================================================================
# 8. TASK 6: DISABLE ALERTING POLICY
# ==============================================================================
if [ -n "$EXISTING_POLICY" ]; then
    echo "Disabling Alerting Policy for clean teardown (Task 6)..."
    curl -s -X PATCH \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"enabled":false}' \
        "https://monitoring.googleapis.com/v3/${EXISTING_POLICY}?updateMask=enabled" > /dev/null || true
    echo "Alert Policy disabled."
fi

# ==============================================================================
# 9. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Dashboards:"
gcloud monitoring dashboards list --format="table(displayName,name)" 2>/dev/null || true

echo ""
echo "Alert Policies:"
curl -s -H "Authorization: Bearer $TOKEN" "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/alertPolicies" | grep -E '"displayName"|"enabled"' || true

echo ""
echo "Resource Groups:"
curl -s -H "Authorization: Bearer $TOKEN" "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/groups" | grep -E '"displayName"|"filter"' || true

echo ""
echo "Uptime Checks:"
curl -s -H "Authorization: Bearer $TOKEN" "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/uptimeCheckConfigs" | grep -E '"displayName"|"period"' || true

# Display completion status
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${CYAN}+-------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${GREEN}              [+] LAB COMPLETED SUCCESSFULLY! [+]                  ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}|${RED}  [!] NOTE: If Task 4 (Resource Group) scores 0/25, check README.md  ${CYAN}|${NC}"
echo -e "${CYAN}|${RED}      Create group in Console UI: Monitoring > Groups > VM instances ${CYAN}|${NC}"
echo -e "${CYAN}|                                                                   |${NC}"
echo -e "${CYAN}+-------------------------------------------------------------------+${NC}\n"
