#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab assigns different regions/zones.
# Override inline: REGION1="europe-west1" ZONE1="europe-west1-b" ./script.sh
# ==============================================================================
_DET_REGION1=$(gcloud config get-value compute/region 2>/dev/null || true)
export REGION1="${REGION1:-${_DET_REGION1:-europe-west1}}"
[ "$REGION1" = "(unset)" ] && export REGION1="europe-west1"
_DET_ZONE1=$(gcloud config get-value compute/zone 2>/dev/null || true)
export ZONE1="${ZONE1:-${_DET_ZONE1:-europe-west1-b}}"
[ "$ZONE1" = "(unset)" ] && export ZONE1="europe-west1-b"
export REGION2="${REGION2:-us-east4}"
export ZONE2="${ZONE2:-us-east4-b}"
export ZONE_ON_PREM="${ZONE_ON_PREM:-europe-west1-c}"
export SHARED_SECRET="${SHARED_SECRET:-gcpsharedsecret}"

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
echo "Project ID     : $PROJECT_ID"
echo "Primary Region : $REGION1 ($ZONE1, $ZONE_ON_PREM)"
echo "Secondary Reg  : $REGION2 ($ZONE2)"
echo "Shared Secret  : $SHARED_SECRET"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION1" --quiet
gcloud config set compute/zone "$ZONE1" --quiet

# Ensure Compute Engine API is active
gcloud services enable compute.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: SET UP A GLOBAL VPC ENVIRONMENT (vpc-demo)
# ==============================================================================
echo "Checking VPC network: vpc-demo..."
if ! gcloud compute networks describe vpc-demo --quiet >/dev/null 2>&1; then
    echo "Creating VPC network vpc-demo (custom subnet mode)..."
    gcloud compute networks create vpc-demo --subnet-mode=custom --quiet
else
    echo "VPC network vpc-demo already exists."
fi

echo "Checking subnet: vpc-demo-subnet1 ($REGION1)..."
if ! gcloud compute networks subnets describe vpc-demo-subnet1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute networks subnets create vpc-demo-subnet1 \
        --network=vpc-demo \
        --range=10.1.1.0/24 \
        --region="$REGION1" --quiet
else
    echo "Subnet vpc-demo-subnet1 already exists."
fi

echo "Checking subnet: vpc-demo-subnet2 ($REGION2)..."
if ! gcloud compute networks subnets describe vpc-demo-subnet2 --region="$REGION2" --quiet >/dev/null 2>&1; then
    gcloud compute networks subnets create vpc-demo-subnet2 \
        --network=vpc-demo \
        --range=10.2.1.0/24 \
        --region="$REGION2" --quiet
else
    echo "Subnet vpc-demo-subnet2 already exists."
fi

echo "Configuring firewall rules for vpc-demo..."
if ! gcloud compute firewall-rules describe vpc-demo-allow-custom --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create vpc-demo-allow-custom \
        --network=vpc-demo \
        --allow=tcp:0-65535,udp:0-65535,icmp \
        --source-ranges=10.0.0.0/8 --quiet
fi

if ! gcloud compute firewall-rules describe vpc-demo-allow-ssh-icmp --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create vpc-demo-allow-ssh-icmp \
        --network=vpc-demo \
        --allow=tcp:22,icmp \
        --source-ranges=0.0.0.0/0 --quiet
fi

echo "Creating compute instances for vpc-demo..."
if ! gcloud compute instances describe vpc-demo-instance1 --zone="$ZONE1" --quiet >/dev/null 2>&1; then
    echo "Creating vpc-demo-instance1 ($ZONE1)..."
    gcloud compute instances create vpc-demo-instance1 \
        --machine-type=e2-medium \
        --zone="$ZONE1" \
        --subnet=vpc-demo-subnet1 --quiet &
    PID_VM1=$!
else
    echo "Instance vpc-demo-instance1 already exists."
    PID_VM1=""
fi

if ! gcloud compute instances describe vpc-demo-instance2 --zone="$ZONE2" --quiet >/dev/null 2>&1; then
    echo "Creating vpc-demo-instance2 ($ZONE2)..."
    gcloud compute instances create vpc-demo-instance2 \
        --machine-type=e2-medium \
        --zone="$ZONE2" \
        --subnet=vpc-demo-subnet2 --quiet &
    PID_VM2=$!
else
    echo "Instance vpc-demo-instance2 already exists."
    PID_VM2=""
fi

# ==============================================================================
# 4. TASK 2: SET UP SIMULATED ON-PREMISES ENVIRONMENT (on-prem)
# ==============================================================================
echo "Checking VPC network: on-prem..."
if ! gcloud compute networks describe on-prem --quiet >/dev/null 2>&1; then
    echo "Creating VPC network on-prem (custom subnet mode)..."
    gcloud compute networks create on-prem --subnet-mode=custom --quiet
else
    echo "VPC network on-prem already exists."
fi

echo "Checking subnet: on-prem-subnet1 ($REGION1)..."
if ! gcloud compute networks subnets describe on-prem-subnet1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute networks subnets create on-prem-subnet1 \
        --network=on-prem \
        --range=192.168.1.0/24 \
        --region="$REGION1" --quiet
else
    echo "Subnet on-prem-subnet1 already exists."
fi

echo "Configuring firewall rules for on-prem..."
if ! gcloud compute firewall-rules describe on-prem-allow-custom --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create on-prem-allow-custom \
        --network=on-prem \
        --allow=tcp:0-65535,udp:0-65535,icmp \
        --source-ranges=192.168.0.0/16 --quiet
fi

if ! gcloud compute firewall-rules describe on-prem-allow-ssh-icmp --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create on-prem-allow-ssh-icmp \
        --network=on-prem \
        --allow=tcp:22,icmp \
        --source-ranges=0.0.0.0/0 --quiet
fi

if ! gcloud compute instances describe on-prem-instance1 --zone="$ZONE_ON_PREM" --quiet >/dev/null 2>&1; then
    echo "Creating on-prem-instance1 ($ZONE_ON_PREM)..."
    gcloud compute instances create on-prem-instance1 \
        --machine-type=e2-medium \
        --zone="$ZONE_ON_PREM" \
        --subnet=on-prem-subnet1 --quiet &
    PID_VM3=$!
else
    echo "Instance on-prem-instance1 already exists."
    PID_VM3=""
fi

# Wait for background instance creations to complete
[ -n "$PID_VM1" ] && wait "$PID_VM1" || true
[ -n "$PID_VM2" ] && wait "$PID_VM2" || true
[ -n "$PID_VM3" ] && wait "$PID_VM3" || true
echo "All VM instances created and running."

# ==============================================================================
# 5. TASK 3: SET UP HA VPN GATEWAYS AND CLOUD ROUTERS
# ==============================================================================
echo "Creating HA VPN Gateways in $REGION1..."
if ! gcloud compute vpn-gateways describe vpc-demo-vpn-gw1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-gateways create vpc-demo-vpn-gw1 \
        --network=vpc-demo \
        --region="$REGION1" --quiet &
    PID_GW1=$!
else
    PID_GW1=""
fi

if ! gcloud compute vpn-gateways describe on-prem-vpn-gw1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-gateways create on-prem-vpn-gw1 \
        --network=on-prem \
        --region="$REGION1" --quiet &
    PID_GW2=$!
else
    PID_GW2=""
fi

echo "Creating Cloud Routers in $REGION1..."
if ! gcloud compute routers describe vpc-demo-router1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute routers create vpc-demo-router1 \
        --region="$REGION1" \
        --network=vpc-demo \
        --asn=65001 --quiet &
    PID_R1=$!
else
    PID_R1=""
fi

if ! gcloud compute routers describe on-prem-router1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute routers create on-prem-router1 \
        --region="$REGION1" \
        --network=on-prem \
        --asn=65002 --quiet &
    PID_R2=$!
else
    PID_R2=""
fi

[ -n "$PID_GW1" ] && wait "$PID_GW1" || true
[ -n "$PID_GW2" ] && wait "$PID_GW2" || true
[ -n "$PID_R1" ] && wait "$PID_R1" || true
[ -n "$PID_R2" ] && wait "$PID_R2" || true
echo "HA VPN Gateways and Cloud Routers ready."

# ==============================================================================
# 6. TASK 4: CREATE TWO DUAL-INTERFACE VPN TUNNELS
# ==============================================================================
echo "Creating VPN tunnels between vpc-demo and on-prem..."

# vpc-demo-tunnel0 (Interface 0)
if ! gcloud compute vpn-tunnels describe vpc-demo-tunnel0 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-tunnels create vpc-demo-tunnel0 \
        --peer-gcp-gateway=on-prem-vpn-gw1 \
        --region="$REGION1" \
        --ike-version=2 \
        --shared-secret="$SHARED_SECRET" \
        --router=vpc-demo-router1 \
        --vpn-gateway=vpc-demo-vpn-gw1 \
        --interface=0 --quiet &
    PID_T1=$!
else
    PID_T1=""
fi

# vpc-demo-tunnel1 (Interface 1)
if ! gcloud compute vpn-tunnels describe vpc-demo-tunnel1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-tunnels create vpc-demo-tunnel1 \
        --peer-gcp-gateway=on-prem-vpn-gw1 \
        --region="$REGION1" \
        --ike-version=2 \
        --shared-secret="$SHARED_SECRET" \
        --router=vpc-demo-router1 \
        --vpn-gateway=vpc-demo-vpn-gw1 \
        --interface=1 --quiet &
    PID_T2=$!
else
    PID_T2=""
fi

# on-prem-tunnel0 (Interface 0)
if ! gcloud compute vpn-tunnels describe on-prem-tunnel0 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-tunnels create on-prem-tunnel0 \
        --peer-gcp-gateway=vpc-demo-vpn-gw1 \
        --region="$REGION1" \
        --ike-version=2 \
        --shared-secret="$SHARED_SECRET" \
        --router=on-prem-router1 \
        --vpn-gateway=on-prem-vpn-gw1 \
        --interface=0 --quiet &
    PID_T3=$!
else
    PID_T3=""
fi

# on-prem-tunnel1 (Interface 1)
if ! gcloud compute vpn-tunnels describe on-prem-tunnel1 --region="$REGION1" --quiet >/dev/null 2>&1; then
    gcloud compute vpn-tunnels create on-prem-tunnel1 \
        --peer-gcp-gateway=vpc-demo-vpn-gw1 \
        --region="$REGION1" \
        --ike-version=2 \
        --shared-secret="$SHARED_SECRET" \
        --router=on-prem-router1 \
        --vpn-gateway=on-prem-vpn-gw1 \
        --interface=1 --quiet &
    PID_T4=$!
else
    PID_T4=""
fi

[ -n "$PID_T1" ] && wait "$PID_T1" || true
[ -n "$PID_T2" ] && wait "$PID_T2" || true
[ -n "$PID_T3" ] && wait "$PID_T3" || true
[ -n "$PID_T4" ] && wait "$PID_T4" || true
echo "All 4 HA VPN tunnels created."

# ==============================================================================
# 7. TASK 5: CONFIGURE BGP PEERING FOR EACH TUNNEL
# ==============================================================================
echo "Configuring BGP interfaces and peers on vpc-demo-router1..."
# vpc-demo Tunnel 0
if ! gcloud compute routers describe vpc-demo-router1 --region="$REGION1" --format="value(interfaces[].name)" | grep -qw "if-tunnel0-to-on-prem"; then
    gcloud compute routers add-interface vpc-demo-router1 \
        --interface-name=if-tunnel0-to-on-prem \
        --ip-address=169.254.0.1 \
        --mask-length=30 \
        --vpn-tunnel=vpc-demo-tunnel0 \
        --region="$REGION1" --quiet
fi

if ! gcloud compute routers describe vpc-demo-router1 --region="$REGION1" --format="value(bgpPeers[].name)" | grep -qw "bgp-on-prem-tunnel0"; then
    gcloud compute routers add-bgp-peer vpc-demo-router1 \
        --peer-name=bgp-on-prem-tunnel0 \
        --interface=if-tunnel0-to-on-prem \
        --peer-ip-address=169.254.0.2 \
        --peer-asn=65002 \
        --region="$REGION1" --quiet
fi

# vpc-demo Tunnel 1
if ! gcloud compute routers describe vpc-demo-router1 --region="$REGION1" --format="value(interfaces[].name)" | grep -qw "if-tunnel1-to-on-prem"; then
    gcloud compute routers add-interface vpc-demo-router1 \
        --interface-name=if-tunnel1-to-on-prem \
        --ip-address=169.254.1.1 \
        --mask-length=30 \
        --vpn-tunnel=vpc-demo-tunnel1 \
        --region="$REGION1" --quiet
fi

if ! gcloud compute routers describe vpc-demo-router1 --region="$REGION1" --format="value(bgpPeers[].name)" | grep -qw "bgp-on-prem-tunnel1"; then
    gcloud compute routers add-bgp-peer vpc-demo-router1 \
        --peer-name=bgp-on-prem-tunnel1 \
        --interface=if-tunnel1-to-on-prem \
        --peer-ip-address=169.254.1.2 \
        --peer-asn=65002 \
        --region="$REGION1" --quiet
fi

echo "Configuring BGP interfaces and peers on on-prem-router1..."
# on-prem Tunnel 0
if ! gcloud compute routers describe on-prem-router1 --region="$REGION1" --format="value(interfaces[].name)" | grep -qw "if-tunnel0-to-vpc-demo"; then
    gcloud compute routers add-interface on-prem-router1 \
        --interface-name=if-tunnel0-to-vpc-demo \
        --ip-address=169.254.0.2 \
        --mask-length=30 \
        --vpn-tunnel=on-prem-tunnel0 \
        --region="$REGION1" --quiet
fi

if ! gcloud compute routers describe on-prem-router1 --region="$REGION1" --format="value(bgpPeers[].name)" | grep -qw "bgp-vpc-demo-tunnel0"; then
    gcloud compute routers add-bgp-peer on-prem-router1 \
        --peer-name=bgp-vpc-demo-tunnel0 \
        --interface=if-tunnel0-to-vpc-demo \
        --peer-ip-address=169.254.0.1 \
        --peer-asn=65001 \
        --region="$REGION1" --quiet
fi

# on-prem Tunnel 1
if ! gcloud compute routers describe on-prem-router1 --region="$REGION1" --format="value(interfaces[].name)" | grep -qw "if-tunnel1-to-vpc-demo"; then
    gcloud compute routers add-interface on-prem-router1 \
        --interface-name=if-tunnel1-to-vpc-demo \
        --ip-address=169.254.1.2 \
        --mask-length=30 \
        --vpn-tunnel=on-prem-tunnel1 \
        --region="$REGION1" --quiet
fi

if ! gcloud compute routers describe on-prem-router1 --region="$REGION1" --format="value(bgpPeers[].name)" | grep -qw "bgp-vpc-demo-tunnel1"; then
    gcloud compute routers add-bgp-peer on-prem-router1 \
        --peer-name=bgp-vpc-demo-tunnel1 \
        --interface=if-tunnel1-to-vpc-demo \
        --peer-ip-address=169.254.1.1 \
        --peer-asn=65001 \
        --region="$REGION1" --quiet
fi

echo "BGP routing established on both routers."

# ==============================================================================
# 8. TASK 6: FIREWALL RULES & GLOBAL DYNAMIC ROUTING
# ==============================================================================
echo "Creating cross-VPC ingress firewall rules..."
if ! gcloud compute firewall-rules describe vpc-demo-allow-subnets-from-on-prem --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create vpc-demo-allow-subnets-from-on-prem \
        --network=vpc-demo \
        --allow=tcp,udp,icmp \
        --source-ranges=192.168.1.0/24 --quiet
fi

if ! gcloud compute firewall-rules describe on-prem-allow-subnets-from-vpc-demo --quiet >/dev/null 2>&1; then
    gcloud compute firewall-rules create on-prem-allow-subnets-from-vpc-demo \
        --network=on-prem \
        --allow=tcp,udp,icmp \
        --source-ranges=10.1.1.0/24,10.2.1.0/24 --quiet
fi

echo "Updating vpc-demo BGP dynamic routing mode to GLOBAL..."
gcloud compute networks update vpc-demo --bgp-routing-mode=GLOBAL --quiet

# ==============================================================================
# 9. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "HA VPN Gateways:"
gcloud compute vpn-gateways list --regions="$REGION1" --format="table(name,network,region)"

echo ""
echo "HA VPN Tunnels:"
gcloud compute vpn-tunnels list --filter="region:$REGION1" --format="table(name,vpnGateway,status,detailedStatus)"

echo ""
echo "Dynamic Routing Mode (vpc-demo):"
gcloud compute networks describe vpc-demo --format="value(routingConfig.routingMode)"

echo ""
echo "VM Instances:"
gcloud compute instances list --format="table(name,zone,networkInterfaces[0].networkIP,status)"

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
