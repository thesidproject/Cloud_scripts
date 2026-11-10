#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override them inline: REGION="us-central1" ZONE="us-central1-c" ./script.sh
# ==============================================================================
_DET_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION="${REGION:-${_DET_REGION:-us-central1}}"
[ "$REGION" = "(unset)" ] && export REGION="us-central1"
_DET_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE="${ZONE:-${_DET_ZONE:-us-central1-c}}"
[ "$ZONE" = "(unset)" ] && export ZONE="us-central1-c"
export LOCATION="${LOCATION:-US}"
export DB_INSTANCE_NAME="${DB_INSTANCE_NAME:-blog-db}"
export DB_USER="${DB_USER:-blogdbuser}"
export DB_PASSWORD="${DB_PASSWORD:-Passw0rd1!}"
export DB_TIER="${DB_TIER:-db-custom-1-3840}"
export VM_NAME="${VM_NAME:-bloghost}"
export VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-e2-standard-2}"

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
echo "Project ID : $PROJECT_ID"
echo "Region     : $REGION"
echo "Zone       : $ZONE"
echo "Location   : $LOCATION"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# Enable required Google APIs
echo "Ensuring required APIs are enabled..."
gcloud services enable compute.googleapis.com sqladmin.googleapis.com storage.googleapis.com --quiet 2>/dev/null || true

# Ensure firewall allows HTTP and SSH traffic
echo "Verifying firewall access for HTTP and SSH..."
if ! gcloud compute firewall-rules list --filter="network=default AND allowed.IPProtocol:tcp AND allowed.ports:80" --format="value(name)" 2>/dev/null | grep -q .; then
    gcloud compute firewall-rules create default-allow-http \
        --network=default \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server --quiet || true
fi

if ! gcloud compute firewall-rules list --filter="network=default AND allowed.IPProtocol:tcp AND allowed.ports:22" --format="value(name)" 2>/dev/null | grep -q .; then
    gcloud compute firewall-rules create default-allow-ssh \
        --network=default \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges=0.0.0.0/0 --quiet || true
fi

# ==============================================================================
# 3. TASK 2: DEPLOY WEB SERVER VM INSTANCE (bloghost)
# ==============================================================================
# Exact startup script expected by the Qwiklabs assessment check
STARTUP_SCRIPT='#!/bin/bash
apt-get install apache2 php php-mysql -y
service apache2 restart'

echo "Checking VM instance: $VM_NAME..."
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" &>/dev/null; then
    echo "Creating VM instance $VM_NAME in zone $ZONE..."
    gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --machine-type="$VM_MACHINE_TYPE" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --boot-disk-type=pd-balanced \
        --tags=http-server \
        --metadata=startup-script="$STARTUP_SCRIPT" \
        --quiet
else
    echo "VM $VM_NAME exists. Ensuring exact required tags and startup-script metadata..."
    gcloud compute instances add-tags "$VM_NAME" --zone="$ZONE" --tags=http-server --quiet || true
    gcloud compute instances add-metadata "$VM_NAME" --zone="$ZONE" --metadata=startup-script="$STARTUP_SCRIPT" --quiet || true
fi

# Retrieve VM external IP address
echo "Fetching external IP address for $VM_NAME..."
VM_IP=""
for i in {1..10}; do
    VM_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
    if [ -n "$VM_IP" ]; then
        break
    fi
    sleep 3
done

if [ -z "$VM_IP" ]; then
    echo "Error: Unable to retrieve external IP for $VM_NAME."
    exit 1
fi
echo "VM External IP: $VM_IP"

# ==============================================================================
# 4. TASK 3: CREATE CLOUD STORAGE BUCKET & PUBLISH ASSET
# ==============================================================================
echo "Checking Cloud Storage bucket gs://$PROJECT_ID..."
if ! gcloud storage buckets describe "gs://$PROJECT_ID" &>/dev/null; then
    echo "Creating bucket gs://$PROJECT_ID in location $LOCATION..."
    gcloud storage buckets create -l "$LOCATION" "gs://$PROJECT_ID" --quiet
fi

echo "Downloading sample blog image..."
if [ ! -f "my-excellent-blog.png" ]; then
    gcloud storage cp gs://cloud-training/gcpfci/my-excellent-blog.png my-excellent-blog.png --quiet
fi

echo "Uploading image to gs://$PROJECT_ID/my-excellent-blog.png..."
gcloud storage cp my-excellent-blog.png "gs://$PROJECT_ID/my-excellent-blog.png" --quiet

echo "Configuring public access for image..."
gsutil acl ch -u allUsers:R "gs://$PROJECT_ID/my-excellent-blog.png" || true

# ==============================================================================
# 5. TASK 4: CREATE CLOUD SQL INSTANCE & CONFIGURE ACCESS
# ==============================================================================
echo "Checking Cloud SQL instance: $DB_INSTANCE_NAME..."
if ! gcloud sql instances describe "$DB_INSTANCE_NAME" &>/dev/null; then
    echo "Provisioning Cloud SQL instance $DB_INSTANCE_NAME (takes ~3-5 minutes)..."
    gcloud sql instances create "$DB_INSTANCE_NAME" \
        --database-version=MYSQL_8_0 \
        --tier="$DB_TIER" \
        --region="$REGION" \
        --root-password="$DB_PASSWORD" \
        --authorized-networks="$VM_IP/32" \
        --quiet
else
    echo "Cloud SQL instance exists. Updating authorized networks..."
    gcloud sql instances patch "$DB_INSTANCE_NAME" \
        --authorized-networks="$VM_IP/32" \
        --quiet || true
fi

# Ensure authorized network entry carries name 'web front end' for grading
ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
if [ -n "$ACCESS_TOKEN" ]; then
    curl -s -X PATCH \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"settings\":{\"ipConfiguration\":{\"authorizedNetworks\":[{\"name\":\"web front end\",\"value\":\"$VM_IP/32\"}]}}}" \
        "https://sqladmin.googleapis.com/v1/projects/$PROJECT_ID/instances/$DB_INSTANCE_NAME" >/dev/null || true
fi

# Create database user account
echo "Configuring database user: $DB_USER..."
if ! gcloud sql users list --instance="$DB_INSTANCE_NAME" --format="value(name)" 2>/dev/null | grep -qw "$DB_USER"; then
    gcloud sql users create "$DB_USER" \
        --instance="$DB_INSTANCE_NAME" \
        --password="$DB_PASSWORD" \
        --quiet
fi

# Fetch Cloud SQL Public IP
SQL_IP=$(gcloud sql instances describe "$DB_INSTANCE_NAME" --format="get(ipAddresses[0].ipAddress)")
echo "Cloud SQL Public IP: $SQL_IP"

# ==============================================================================
# 6. TASKS 5 & 6: CONFIGURE index.php ON bloghost VM
# ==============================================================================
echo "Deploying index.php and configuring web server on $VM_NAME..."

# Prepare PHP file locally
cat <<EOF > /tmp/index.php
<html>
<head><title>Welcome to my excellent blog</title></head>
<body>
<img src='https://storage.googleapis.com/${PROJECT_ID}/my-excellent-blog.png'>
<h1>Welcome to my excellent blog</h1>
<?php
 \$dbserver = "${SQL_IP}";
 \$dbuser = "${DB_USER}";
 \$dbpassword = "${DB_PASSWORD}";

 try {
  \$conn = new PDO("mysql:host=\$dbserver;dbname=mysql", \$dbuser, \$dbpassword);
  \$conn->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
  echo "Connected successfully";
} catch(PDOException \$e) {
  echo "Database connection failed:: " . \$e->getMessage();
}
?>
</body></html>
EOF

# Deploy index.php via SCP and SSH without modifying VM metadata
SSH_SUCCESS=false
for attempt in {1..12}; do
    echo "Attempt $attempt/12: Connecting to $VM_NAME via SSH..."
    if gcloud compute scp /tmp/index.php "$VM_NAME:/tmp/index.php" --zone="$ZONE" --quiet 2>/dev/null && \
       gcloud compute ssh "$VM_NAME" --zone="$ZONE" --quiet --command="sudo mv /tmp/index.php /var/www/html/index.php && sudo rm -f /var/www/html/index.html && sudo service apache2 restart" 2>/dev/null; then
        SSH_SUCCESS=true
        echo "Successfully deployed index.php to $VM_NAME!"
        break
    fi
    sleep 5
done

# If SSH failed, try piping directly via gcloud compute ssh
if [ "$SSH_SUCCESS" = false ]; then
    echo "Retrying direct pipe to $VM_NAME..."
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --quiet \
        --command="sudo tee /var/www/html/index.php > /dev/null && sudo rm -f /var/www/html/index.html && sudo service apache2 restart" < /tmp/index.php || true
fi

# ==============================================================================
# 7. VERIFICATION
# ==============================================================================
echo "=================================================="
echo "RUNNING VERIFICATION CHECKS"
echo "=================================================="
echo "Probing endpoint: http://$VM_IP/index.php"

HTTP_RESPONSE=""
for i in {1..6}; do
    HTTP_RESPONSE=$(curl -s "http://$VM_IP/index.php" || true)
    if echo "$HTTP_RESPONSE" | grep -q "Connected successfully"; then
        echo "Check passed: Database connection verified!"
        break
    fi
    sleep 5
done

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if echo "$HTTP_RESPONSE" | grep -q "Connected successfully"; then
    echo -e "\n${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}║${GREEN}              [✓] LAB COMPLETED SUCCESSFULLY! [✓]                  ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}║${YELLOW}     You can now safely click 'Check My Progress' for all tasks!   ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
else
    echo "Notice: Output received from http://$VM_IP/index.php:"
    echo "$HTTP_RESPONSE"
fi
