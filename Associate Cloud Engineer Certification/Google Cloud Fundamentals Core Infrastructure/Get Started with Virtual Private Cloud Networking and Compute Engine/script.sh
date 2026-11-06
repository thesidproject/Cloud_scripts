#!/bin/bash
set -e

# Automatically set project ID
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: GCP Project ID not found."
    exit 1
fi
echo "Using Project ID: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" --quiet

# Dynamically set regions/zones based on lab parameters
REGION_1="us-east1"
ZONE_1="${REGION_1}-c"
REGION_2="us-east4"
ZONE_2="${REGION_2}-a"

# 1. Clean up default firewall rules and default network
FIREWALL_RULES=$(gcloud compute firewall-rules list --filter="network=default" --format="value(name)" 2>/dev/null || true)
if [ -n "$FIREWALL_RULES" ]; then
    echo "Deleting default firewall rules..."
    gcloud compute firewall-rules delete $FIREWALL_RULES --quiet
fi

if gcloud compute networks describe default &>/dev/null; then
    echo "Deleting default network..."
    gcloud compute networks delete default --quiet
fi

# 2. Create auto-mode network 'mynetwork' and firewall rules
if ! gcloud compute networks describe mynetwork &>/dev/null; then
    gcloud compute networks create mynetwork --subnet-mode=auto --quiet
fi

gcloud compute firewall-rules create mynetwork-allow-custom \
    --network=mynetwork \
    --allow=tcp,udp,icmp \
    --source-ranges=10.128.0.0/9 --quiet || true

gcloud compute firewall-rules create mynetwork-allow-icmp \
    --network=mynetwork \
    --allow=icmp \
    --source-ranges=0.0.0.0/0 --quiet || true

gcloud compute firewall-rules create mynetwork-allow-rdp \
    --network=mynetwork \
    --allow=tcp:3389 \
    --source-ranges=0.0.0.0/0 --quiet || true

gcloud compute firewall-rules create mynetwork-allow-ssh \
    --network=mynetwork \
    --allow=tcp:22 \
    --source-ranges=0.0.0.0/0 --quiet || true

# 3. Provision Compute Engine VM Instances
if ! gcloud compute instances describe mynet-us-vm --zone="$ZONE_1" &>/dev/null; then
    gcloud compute instances create mynet-us-vm \
        --zone="$ZONE_1" \
        --machine-type=e2-micro \
        --network=mynetwork --quiet
fi

if ! gcloud compute instances describe mynet-r2-vm --zone="$ZONE_2" &>/dev/null; then
    gcloud compute instances create mynet-r2-vm \
        --zone="$ZONE_2" \
        --machine-type=e2-micro \
        --network=mynetwork --quiet
fi

echo "Lab setup completed successfully!"