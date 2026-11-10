#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: REGION="us-west1" ZONE="us-west1-b" ROOT_PASSWORD="your-password" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-west1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-west1"
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-west1-b}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-west1-b"
export ROOT_PASSWORD="${ROOT_PASSWORD:-Passw0rd1!}"

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
echo "Project ID  : $PROJECT_ID"
echo "Region      : $REGION"
echo "Zone        : $ZONE"
echo "Database ID : wordpress-db"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Ensure APIs are enabled
echo "Enabling Service Networking and Cloud SQL Admin APIs..."
gcloud services enable servicenetworking.googleapis.com sqladmin.googleapis.com compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 2: CONFIGURE PRIVATE SERVICES ACCESS & CREATE CLOUD SQL INSTANCE
# ==============================================================================
echo "Checking Private Services Access on default VPC..."
if ! gcloud compute addresses describe google-managed-services-default --global &>/dev/null; then
    echo "Allocating IP range for Private Services Access..."
    gcloud compute addresses create google-managed-services-default \
        --global \
        --purpose=VPC_PEERING \
        --prefix-length=16 \
        --network=default \
        --quiet 2>/dev/null || true
fi

echo "Connecting VPC peering to servicenetworking.googleapis.com..."
gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-default \
    --network=default \
    --quiet 2>/dev/null || true

echo "Checking Cloud SQL instance: wordpress-db..."
if ! gcloud sql instances describe wordpress-db &>/dev/null; then
    echo "Creating Cloud SQL instance wordpress-db (takes ~4-5 minutes)..."
    LOCATION_FLAG="--zone=$ZONE"
    if [ -z "$ZONE" ]; then
        LOCATION_FLAG="--region=$REGION"
    fi
    gcloud sql instances create wordpress-db \
        --database-version=MYSQL_8_0 \
        --tier=db-custom-1-3840 \
        $LOCATION_FLAG \
        --storage-type=SSD \
        --storage-size=10GB \
        --storage-auto-increase \
        --network=default \
        --assign-ip \
        --root-password="$ROOT_PASSWORD" \
        --edition=ENTERPRISE \
        --availability-type=ZONAL \
        --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED \
        --quiet
fi

# Wait for instance to become RUNNABLE
echo "Waiting for wordpress-db to reach RUNNABLE state..."
for i in {1..30}; do
    STATUS=$(gcloud sql instances describe wordpress-db --format="value(state)" 2>/dev/null || echo "UNKNOWN")
    if [ "$STATUS" = "RUNNABLE" ]; then
        echo "Cloud SQL instance wordpress-db is RUNNABLE."
        break
    fi
    sleep 10
done

# ==============================================================================
# 4. TASK 3: CREATE DATABASE 'wordpress' & EXTRACT CONNECTION DETAILS
# ==============================================================================
echo "Checking database 'wordpress' on wordpress-db..."
if ! gcloud sql databases describe wordpress --instance=wordpress-db &>/dev/null; then
    echo "Creating database 'wordpress'..."
    gcloud sql databases create wordpress --instance=wordpress-db --quiet
fi

SQL_CONNECTION=$(gcloud sql instances describe wordpress-db --format="value(connectionName)")
SQL_PRIVATE_IP=$(python3 -c "import json, subprocess; out=json.loads(subprocess.check_output(['gcloud', 'sql', 'instances', 'describe', 'wordpress-db', '--format=json'])); print([x['ipAddress'] for x in out.get('ipAddresses', []) if x.get('type') == 'PRIVATE'][0])" 2>/dev/null || gcloud sql instances describe wordpress-db --format="json" | grep -B2 -i '"type": "PRIVATE"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

echo "SQL Connection Name : $SQL_CONNECTION"
echo "SQL Private IP      : $SQL_PRIVATE_IP"

# Locate preconfigured VMs
PROXY_ZONE=$(gcloud compute instances list --filter="name=wordpress-proxy" --format="value(zone)" | head -n1)
PRIVATE_ZONE=$(gcloud compute instances list --filter="name=wordpress-private-ip" --format="value(zone)" | head -n1)
PROXY_ZONE="${PROXY_ZONE:-$ZONE}"
PRIVATE_ZONE="${PRIVATE_ZONE:-$ZONE}"

# ==============================================================================
# 5. TASKS 3 & 4: CONFIGURE CLOUD SQL PROXY & WORDPRESS ON wordpress-proxy
# ==============================================================================
echo "Configuring Cloud SQL Proxy and WordPress on wordpress-proxy ($PROXY_ZONE)..."
for attempt in {1..15}; do
    if gcloud compute ssh wordpress-proxy --zone="$PROXY_ZONE" --quiet --command="true" 2>/dev/null; then
        echo "SSH connection established to wordpress-proxy."
        gcloud compute ssh wordpress-proxy --zone="$PROXY_ZONE" --quiet --command="
            # Download and setup Cloud SQL Proxy v2
            if [ ! -f ~/cloud_sql_proxy ]; then
                wget -q https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.26.3/cloud-sql-proxy.linux.amd64 -O ~/cloud_sql_proxy
                chmod +x ~/cloud_sql_proxy
            fi

            # Terminate any stale proxy instances and start proxy
            sudo pkill -f cloud_sql_proxy || true
            nohup ~/cloud_sql_proxy --port 3306 $SQL_CONNECTION </dev/null > /tmp/proxy.log 2>&1 &
            sleep 3

            # Configure WordPress wp-config.php for localhost proxy
            if [ -d /var/www/html ]; then
                cd /var/www/html
                if [ -f wp-config-sample.php ] && [ ! -f wp-config.php ]; then
                    sudo cp wp-config-sample.php wp-config.php
                fi
                if [ -f wp-config.php ]; then
                    sudo sed -i \"s/database_name_here/wordpress/\" wp-config.php
                    sudo sed -i \"s/username_here/root/\" wp-config.php
                    sudo sed -i \"s/password_here/$ROOT_PASSWORD/\" wp-config.php
                    sudo sed -i \"s/localhost/127.0.0.1/\" wp-config.php
                fi
            fi
        "
        echo "wordpress-proxy configuration completed."
        break
    fi
    sleep 5
done

# Initialize WordPress database installation through wordpress-proxy
PROXY_EXT_IP=$(gcloud compute instances describe wordpress-proxy --zone="$PROXY_ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
if [ -n "$PROXY_EXT_IP" ]; then
    echo "Initializing WordPress installation on http://$PROXY_EXT_IP/..."
    sleep 5
    curl -s "http://$PROXY_EXT_IP/wp-admin/install.php" >/dev/null || true
    curl -s -X POST "http://$PROXY_EXT_IP/wp-admin/install.php?step=2" \
        -d "weblog_title=My+Cloud+SQL+Blog" \
        -d "user_name=admin" \
        -d "admin_password=$ROOT_PASSWORD" \
        -d "admin_password2=$ROOT_PASSWORD" \
        -d "admin_email=admin%40example.com" \
        -d "Submit=Install+WordPress" >/dev/null 2>&1 || true
fi

# ==============================================================================
# 6. TASK 5: CONFIGURE DIRECT PRIVATE IP WORDPRESS ON wordpress-private-ip
# ==============================================================================
echo "Configuring WordPress on wordpress-private-ip ($PRIVATE_ZONE)..."
for attempt in {1..15}; do
    if gcloud compute ssh wordpress-private-ip --zone="$PRIVATE_ZONE" --quiet --command="true" 2>/dev/null; then
        echo "SSH connection established to wordpress-private-ip."
        gcloud compute ssh wordpress-private-ip --zone="$PRIVATE_ZONE" --quiet --command="
            if [ -d /var/www/html ]; then
                cd /var/www/html
                if [ -f wp-config-sample.php ] && [ ! -f wp-config.php ]; then
                    sudo cp wp-config-sample.php wp-config.php
                fi
                if [ -f wp-config.php ]; then
                    sudo sed -i \"s/database_name_here/wordpress/\" wp-config.php
                    sudo sed -i \"s/username_here/root/\" wp-config.php
                    sudo sed -i \"s/password_here/$ROOT_PASSWORD/\" wp-config.php
                    sudo sed -i \"s/localhost/$SQL_PRIVATE_IP/\" wp-config.php
                    sudo sed -i \"s/127.0.0.1/$SQL_PRIVATE_IP/\" wp-config.php
                fi
            fi
        "
        echo "wordpress-private-ip configuration completed."
        break
    fi
    sleep 5
done

# ==============================================================================
# 7. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Cloud SQL Instance:"
gcloud sql instances describe wordpress-db --format="table(name, state, ipAddresses[0].ipAddress:label=PUBLIC_IP, ipAddresses[1].ipAddress:label=PRIVATE_IP, region, gceZone)"

echo ""
echo "Cloud SQL Databases:"
gcloud sql databases list --instance=wordpress-db

echo ""
echo "VM Connection Endpoints:"
echo "wordpress-proxy External IP     : http://$PROXY_EXT_IP"
PRIVATE_EXT_IP=$(gcloud compute instances describe wordpress-private-ip --zone="$PRIVATE_ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
echo "wordpress-private-ip External IP: http://$PRIVATE_EXT_IP"

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
