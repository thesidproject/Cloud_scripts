#!/bin/bash
set -eo pipefail
START_TIME=$(date +%s)

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different regions/zones.
# Override inline: REGION1="us-east1" ZONE1="us-east1-d" ./script.sh
# ==============================================================================
export REGION1="${REGION1:-us-east1}"
export ZONE1="${ZONE1:-us-east1-d}"
export REGION2="${REGION2:-asia-south1}"
export ZONE_STRESS="${ZONE_STRESS:-us-east1-b}"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID       : $PROJECT_ID"
echo "Primary Region   : $REGION1 ($ZONE1)"
echo "Secondary Region : $REGION2"
echo "Stress Test Zone : $ZONE_STRESS"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION1" --quiet
gcloud config set compute/zone "$ZONE1" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CONFIGURE A HEALTH CHECK FIREWALL RULE
# ==============================================================================
echo "Checking firewall rule: fw-allow-health-checks..."
if ! gcloud compute firewall-rules describe fw-allow-health-checks --quiet >/dev/null 2>&1; then
    echo "Creating firewall rule fw-allow-health-checks..."
    gcloud compute firewall-rules create fw-allow-health-checks \
        --network=default \
        --action=allow \
        --direction=ingress \
        --source-ranges=130.211.0.0/22,35.191.0.0/16 \
        --target-tags=allow-health-checks \
        --rules=tcp:80 \
        --quiet
    echo "Firewall rule fw-allow-health-checks created."
else
    echo "Firewall rule fw-allow-health-checks already exists."
fi

# ==============================================================================
# 4. TASK 2: CREATE A NAT CONFIGURATION USING CLOUD ROUTER
# ==============================================================================
echo "Checking Cloud Router: nat-router-us1 ($REGION1)..."
if ! gcloud compute routers describe nat-router-us1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    echo "Creating Cloud Router nat-router-us1..."
    gcloud compute routers create nat-router-us1 \
        --network=default \
        --region="$REGION1" \
        --quiet
else
    echo "Cloud Router nat-router-us1 already exists."
fi

echo "Checking Cloud NAT Gateway: nat-config ($REGION1)..."
if ! gcloud compute routers nats describe nat-config --router=nat-router-us1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    echo "Creating Cloud NAT Gateway nat-config..."
    gcloud compute routers nats create nat-config \
        --router=nat-router-us1 \
        --region="$REGION1" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --quiet
    echo "Cloud NAT Gateway nat-config created."
else
    echo "Cloud NAT Gateway nat-config already exists."
fi

# ==============================================================================
# 5. TASK 3: CREATE A CUSTOM IMAGE FOR A WEB SERVER
# ==============================================================================
echo "Checking custom image: mywebserver..."
if ! gcloud compute images describe mywebserver --quiet >/dev/null 2>&1; then
    # Check if persistent disk webserver already exists
    if ! gcloud compute disks describe webserver --zone="$ZONE1" --quiet >/dev/null 2>&1; then
        echo "Creating temporary VM instance 'webserver' with Apache2 startup script..."
        gcloud compute instances create webserver \
            --zone="$ZONE1" \
            --machine-type=e2-micro \
            --network=default \
            --tags=allow-health-checks \
            --no-address \
            --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y apache2
systemctl start apache2
systemctl enable apache2
echo "Apache installed and enabled." > /tmp/startup_done.txt' \
            --quiet

        echo "Waiting for webserver to finish Apache2 installation (~30s)..."
        for i in {1..12}; do
            sleep 5
            STATUS=$(gcloud compute instances describe webserver --zone="$ZONE1" --format="value(status)" 2>/dev/null || true)
            if [ "$STATUS" = "RUNNING" ]; then
                break
            fi
        done
        sleep 25

        echo "Deleting temporary instance 'webserver' while keeping the boot disk..."
        gcloud compute instances delete webserver --zone="$ZONE1" --keep-disks=boot --quiet
    fi

    echo "Creating custom image 'mywebserver' from source disk 'webserver'..."
    gcloud compute images create mywebserver \
        --source-disk=webserver \
        --source-disk-zone="$ZONE1" \
        --quiet
    echo "Custom image 'mywebserver' created successfully."
else
    echo "Custom image 'mywebserver' already exists."
fi

# ==============================================================================
# 6. TASK 4: CONFIGURE INSTANCE TEMPLATE AND MANAGED INSTANCE GROUPS
# ==============================================================================
echo "Checking instance template: mywebserver-template..."
if ! gcloud compute instance-templates describe mywebserver-template --quiet >/dev/null 2>&1; then
    echo "Creating instance template mywebserver-template..."
    gcloud compute instance-templates create mywebserver-template \
        --machine-type=e2-micro \
        --image=mywebserver \
        --network=default \
        --tags=allow-health-checks \
        --no-address \
        --quiet
    echo "Instance template mywebserver-template created."
else
    echo "Instance template mywebserver-template already exists."
fi

echo "Checking health check: http-health-check..."
if ! gcloud compute health-checks describe http-health-check --quiet >/dev/null 2>&1; then
    echo "Creating health check http-health-check..."
    gcloud compute health-checks create http http-health-check \
        --port=80 \
        --check-interval=5s \
        --timeout=5s \
        --unhealthy-threshold=2 \
        --healthy-threshold=2 \
        --quiet
else
    echo "Health check http-health-check already exists."
fi

echo "Checking Managed Instance Group: us-1-mig ($REGION1)..."
if ! gcloud compute instance-groups managed describe us-1-mig --region="$REGION1" --quiet >/dev/null 2>&1; then
    echo "Creating regional MIG us-1-mig in $REGION1..."
    gcloud compute instance-groups managed create us-1-mig \
        --template=mywebserver-template \
        --size=1 \
        --region="$REGION1" \
        --health-check=http-health-check \
        --initial-delay=60 \
        --quiet

    gcloud compute instance-groups managed set-named-ports us-1-mig \
        --named-ports=http:80 \
        --region="$REGION1" \
        --quiet

    echo "Configuring autoscaling for us-1-mig..."
    gcloud compute instance-groups managed set-autoscaling us-1-mig \
        --region="$REGION1" \
        --min-num-replicas=1 \
        --max-num-replicas=2 \
        --target-load-balancing-utilization=0.8 \
        --cool-down-period=60 \
        --quiet
else
    echo "MIG us-1-mig already exists."
fi

echo "Checking Managed Instance Group: notus-1-mig ($REGION2)..."
if ! gcloud compute instance-groups managed describe notus-1-mig --region="$REGION2" --quiet >/dev/null 2>&1; then
    echo "Creating regional MIG notus-1-mig in $REGION2..."
    gcloud compute instance-groups managed create notus-1-mig \
        --template=mywebserver-template \
        --size=1 \
        --region="$REGION2" \
        --health-check=http-health-check \
        --initial-delay=60 \
        --quiet

    gcloud compute instance-groups managed set-named-ports notus-1-mig \
        --named-ports=http:80 \
        --region="$REGION2" \
        --quiet

    echo "Configuring autoscaling for notus-1-mig..."
    gcloud compute instance-groups managed set-autoscaling notus-1-mig \
        --region="$REGION2" \
        --min-num-replicas=1 \
        --max-num-replicas=2 \
        --target-load-balancing-utilization=0.8 \
        --cool-down-period=60 \
        --quiet
else
    echo "MIG notus-1-mig already exists."
fi

# ==============================================================================
# 7. TASK 5: CONFIGURE THE APPLICATION LOAD BALANCER (HTTP)
# ==============================================================================
echo "Checking backend service: http-backend..."
if ! gcloud compute backend-services describe http-backend --global --quiet >/dev/null 2>&1; then
    echo "Creating backend service http-backend..."
    gcloud compute backend-services create http-backend \
        --protocol=HTTP \
        --port-name=http \
        --health-checks=http-health-check \
        --enable-logging \
        --logging-sample-rate=1.0 \
        --global \
        --quiet
else
    echo "Backend service http-backend already exists."
fi

echo "Attaching backends to http-backend..."
EXISTING_BACKENDS=$(gcloud compute backend-services describe http-backend --global --format="value(backends[].group)" 2>/dev/null || true)

if ! echo "$EXISTING_BACKENDS" | grep -q "us-1-mig"; then
    echo "Adding us-1-mig backend (Rate mode, max RPS 50)..."
    gcloud compute backend-services add-backend http-backend \
        --instance-group=us-1-mig \
        --instance-group-region="$REGION1" \
        --balancing-mode=RATE \
        --max-rate-per-instance=50 \
        --capacity-scaler=1.0 \
        --global \
        --quiet
fi

if ! echo "$EXISTING_BACKENDS" | grep -q "notus-1-mig"; then
    echo "Adding notus-1-mig backend (Utilization mode, max utilization 80%)..."
    gcloud compute backend-services add-backend http-backend \
        --instance-group=notus-1-mig \
        --instance-group-region="$REGION2" \
        --balancing-mode=UTILIZATION \
        --max-utilization=0.8 \
        --capacity-scaler=1.0 \
        --global \
        --quiet
fi

echo "Checking URL map: http-lb..."
if ! gcloud compute url-maps describe http-lb --global --quiet >/dev/null 2>&1; then
    echo "Creating URL map http-lb..."
    gcloud compute url-maps create http-lb \
        --default-service=http-backend \
        --global \
        --quiet
else
    echo "URL map http-lb already exists."
fi

echo "Checking target HTTP proxy: http-lb-target-proxy..."
if ! gcloud compute target-http-proxies describe http-lb-target-proxy --global --quiet >/dev/null 2>&1; then
    echo "Creating target HTTP proxy http-lb-target-proxy..."
    gcloud compute target-http-proxies create http-lb-target-proxy \
        --url-map=http-lb \
        --global \
        --quiet
else
    echo "Target HTTP proxy http-lb-target-proxy already exists."
fi

echo "Checking frontend IPv4 forwarding rule..."
if ! gcloud compute forwarding-rules describe http-lb-forwarding-rule --global --quiet >/dev/null 2>&1; then
    echo "Creating global IPv4 forwarding rule..."
    gcloud compute forwarding-rules create http-lb-forwarding-rule \
        --load-balancing-scheme=EXTERNAL \
        --network-tier=PREMIUM \
        --target-http-proxy=http-lb-target-proxy \
        --ports=80 \
        --ip-version=IPV4 \
        --global \
        --quiet
else
    echo "IPv4 forwarding rule already exists."
fi

echo "Checking frontend IPv6 forwarding rule..."
if ! gcloud compute forwarding-rules describe http-lb-forwarding-rule-ipv6 --global --quiet >/dev/null 2>&1; then
    echo "Creating global IPv6 forwarding rule..."
    gcloud compute forwarding-rules create http-lb-forwarding-rule-ipv6 \
        --load-balancing-scheme=EXTERNAL \
        --network-tier=PREMIUM \
        --target-http-proxy=http-lb-target-proxy \
        --ports=80 \
        --ip-version=IPV6 \
        --global \
        --quiet
else
    echo "IPv6 forwarding rule already exists."
fi

LB_IP_V4=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule --global --format="value(IPAddress)" 2>/dev/null || true)
LB_IP_V6=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule-ipv6 --global --format="value(IPAddress)" 2>/dev/null || true)
echo "Load Balancer IPv4: $LB_IP_V4"
echo "Load Balancer IPv6: $LB_IP_V6"

# ==============================================================================
# 8. TASK 6: PROVISION STRESS TEST INSTANCE
# ==============================================================================
echo "Checking stress-test instance ($ZONE_STRESS)..."
if ! gcloud compute instances describe stress-test --zone="$ZONE_STRESS" --quiet >/dev/null 2>&1; then
    echo "Creating stress-test instance in $ZONE_STRESS..."
    gcloud compute instances create stress-test \
        --zone="$ZONE_STRESS" \
        --machine-type=e2-micro \
        --image=mywebserver \
        --metadata=startup-script="#!/bin/bash
sleep 15
if [ -n \"$LB_IP_V4\" ]; then
    ab -n 500000 -c 1000 http://${LB_IP_V4}/ > /tmp/ab.log 2>&1 &
fi" \
        --quiet
    echo "Instance stress-test created."
else
    echo "Instance stress-test already exists."
fi

# ==============================================================================
# 9. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Firewall Rules:"
gcloud compute firewall-rules list --filter="name:fw-allow-health-checks" --format="table(name,network,targetTags,sourceRanges)"

echo ""
echo "Cloud NAT:"
gcloud compute routers nats list --router=nat-router-us1 --region="$REGION1" --format="table(name,router)"

echo ""
echo "Custom Image:"
gcloud compute images list --filter="name:mywebserver" --format="table(name,status,diskSizeGb)"

echo ""
echo "Managed Instance Groups:"
gcloud compute instance-groups managed list --format="table(name,location,targetSize,baseInstanceName)"

echo ""
echo "Load Balancer Components:"
echo "URL Map        : $(gcloud compute url-maps list --filter="name:http-lb" --format="value(name)" 2>/dev/null)"
echo "Backend Service: $(gcloud compute backend-services list --filter="name:http-backend" --format="value(name)" 2>/dev/null)"
echo "IPv4 Frontend  : $LB_IP_V4"
echo "IPv6 Frontend  : $LB_IP_V6"

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
