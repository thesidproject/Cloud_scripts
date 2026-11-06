#!/bin/bash
set -e

# ==============================================================================
# USER CONFIGURATION
# Set these if your lab assigns a region/zone different from the defaults below.
# ==============================================================================
LOCATION="US"             # Cloud Storage Location (US, EU, ASIA)
REGION="us-east4"         # Assigned GCP Region
ZONE="us-east4-c"         # Assigned GCP Zone
# ==============================================================================

# Automatically detect active GCP Project ID dynamically
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Could not detect GCP Project ID. Ensure Cloud Shell is connected."
    exit 1
fi
echo "Using Project ID: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" --quiet

export DB_PASSWORD="Passw0rd1!"

echo "=== Task 1: Deploy Web Server VM Instance (bloghost) ==="
if ! gcloud compute instances describe bloghost --zone="$ZONE" &>/dev/null; then
    gcloud compute instances create bloghost \
        --zone="$ZONE" \
        --machine-type=e2-standard-2 \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=http-server \
        --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 php php-mysql -y
service apache2 restart' \
        --quiet
fi

# Ensure Firewall rule for HTTP traffic exists
if ! gcloud compute firewall-rules describe default-allow-http &>/dev/null; then
    gcloud compute firewall-rules create default-allow-http \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80 \
        --target-tags=http-server \
        --quiet || true
fi

echo "=== Task 2: Create Cloud Storage Bucket & Upload Asset ==="
if ! gcloud storage buckets describe gs://$PROJECT_ID &>/dev/null; then
    gcloud storage buckets create -l $LOCATION gs://$PROJECT_ID --quiet
fi

gcloud storage cp gs://cloud-training/gcpfci/my-excellent-blog.png my-excellent-blog.png --quiet
gcloud storage cp my-excellent-blog.png gs://$PROJECT_ID/my-excellent-blog.png --quiet
gsutil acl ch -u allUsers:R gs://$PROJECT_ID/my-excellent-blog.png

echo "=== Task 3: Create Cloud SQL Instance (blog-db) ==="
if ! gcloud sql instances describe blog-db &>/dev/null; then
    gcloud sql instances create blog-db \
        --database-version=MYSQL_8_0 \
        --tier=db-custom-1-3840 \
        --edition=enterprise \
        --region="$REGION" \
        --zone="$ZONE" \
        --root-password="$DB_PASSWORD" \
        --quiet
fi

# Wait for Cloud SQL to become fully ready
echo "Waiting for Cloud SQL instance to be running..."
until [ "$(gcloud sql instances describe blog-db --format='value(state)' 2>/dev/null)" == "RUNNABLE" ]; do
    sleep 10
done

# Create Database User
gcloud sql users create blogdbuser \
    --instance=blog-db \
    --password="$DB_PASSWORD" --quiet || true

# Fetch bloghost External IP & authorize it on Cloud SQL
BLOGHOST_IP=$(gcloud compute instances describe bloghost --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
gcloud sql instances patch blog-db --authorized-networks="$BLOGHOST_IP/32" --quiet

echo "=== Task 4: Configure Application (index.php) via SSH ==="
CLOUDSQL_IP=$(gcloud sql instances describe blog-db --format='get(ipAddresses[0].ipAddress)')
IMAGE_URL="https://storage.googleapis.com/$PROJECT_ID/my-excellent-blog.png"

# Wait for SSH connectivity on bloghost
echo "Waiting for SSH connection to bloghost..."
until gcloud compute ssh bloghost --zone="$ZONE" --command="echo SSH Ready" --quiet &>/dev/null; do
    sleep 5
done

gcloud compute ssh bloghost --zone="$ZONE" --command="cat << 'EOF' | sudo tee /var/www/html/index.php
<html>
<head><title>Welcome to my excellent blog</title></head>
<body>
<img src='$IMAGE_URL'>
<h1>Welcome to my excellent blog</h1>
<?php
 \$dbserver = \"$CLOUDSQL_IP\";
 \$dbuser = \"blogdbuser\";
 \$dbpassword = \"$DB_PASSWORD\";

 try {
  \$conn = new PDO(\"mysql:host=\$dbserver;dbname=mysql\", \$dbuser, \$dbpassword);
  \$conn->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
  echo \"Connected successfully\";
} catch(PDOException \$e) {
  echo \"Database connection failed:: \" . \$e->getMessage();
}
?>
</body></html>
EOF
sudo service apache2 restart" --quiet

echo "=== Lab Execution Completed Successfully! ==="