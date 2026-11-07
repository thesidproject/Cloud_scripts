#!/bin/bash
set -eo pipefail

# ==============================================================================
# 1. USER CONFIGURATIONS
# Edit these variables if your lab specifies different values.
# Override inline: LOCATION="US" DATASET_NAME="billing_dataset" ./script.sh
# ==============================================================================
export LOCATION="${LOCATION:-US}"
export DATASET_NAME="${DATASET_NAME:-billing_dataset}"
export TABLE_NAME="${TABLE_NAME:-sampleinfotable}"
export SOURCE_AVRO="gs://cloud-training/archinfra/BillingExport-2020-09-18.avro"

# ==============================================================================
# 2. DYNAMIC ENVIRONMENT SETUP
# ==============================================================================
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "${DEVSHELL_PROJECT_ID:-$GOOGLE_CLOUD_PROJECT}")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Google Cloud Project ID not found. Ensure gcloud is initialized."
    exit 1
fi

echo "=================================================="
echo "Project ID   : $PROJECT_ID"
echo "Location     : $LOCATION"
echo "Dataset Name : $DATASET_NAME"
echo "Table Name   : $TABLE_NAME"
echo "Source File  : $SOURCE_AVRO"
echo "=================================================="

gcloud config set project "$PROJECT_ID" --quiet

# Ensure BigQuery API is enabled
gcloud services enable bigquery.googleapis.com --quiet 2>/dev/null || true

# ==============================================================================
# 3. TASK 1: CREATE DATASET & IMPORT AVRO DATA TABLE
# ==============================================================================
echo "Checking BigQuery dataset: $DATASET_NAME..."
if ! bq show "$PROJECT_ID:$DATASET_NAME" &>/dev/null; then
    echo "Creating dataset $DATASET_NAME (Location: $LOCATION, default table expiration: 1 day)..."
    bq --location="$LOCATION" mk \
        --dataset \
        --default_table_expiration=86400 \
        "$PROJECT_ID:$DATASET_NAME"
else
    echo "Dataset $DATASET_NAME already exists."
fi

echo "Checking BigQuery table: $DATASET_NAME.$TABLE_NAME..."
if ! bq show "$PROJECT_ID:$DATASET_NAME.$TABLE_NAME" &>/dev/null; then
    echo "Loading Avro data from $SOURCE_AVRO into $TABLE_NAME..."
    bq --location="$LOCATION" load \
        --source_format=AVRO \
        "$PROJECT_ID:$DATASET_NAME.$TABLE_NAME" \
        "$SOURCE_AVRO"
else
    echo "Table $TABLE_NAME already exists."
fi

# ==============================================================================
# 4. TASK 3: EXECUTE SIMPLE FILTER QUERY
# ==============================================================================
echo "Executing verbatim Task 3 query (filter cost > 0)..."
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT * FROM \`billing_dataset.sampleinfotable\` WHERE cost > 0"

# Also execute with project prefix for compatibility
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT * FROM \`$PROJECT_ID.billing_dataset.sampleinfotable\` WHERE cost > 0" 2>/dev/null || true

# ==============================================================================
# 5. TASK 4: ANALYZE BILLING DATASET WITH SQL QUERIES
# ==============================================================================
echo "Running analytical billing queries..."

# Query 1: Retrieve basic billing fields
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT billing_account_id, project.id, project.name, service.description, currency, currency_conversion_rate, cost, usage.amount, usage.pricing_unit FROM \`billing_dataset.sampleinfotable\`"

# Query 2: Retrieve latest 100 non-zero charges sorted by usage end time
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT service.description, sku.description, location.country, cost, project.id, project.name, currency, currency_conversion_rate, usage.amount, usage.unit FROM \`billing_dataset.sampleinfotable\` WHERE cost > 0 ORDER BY usage_end_time DESC LIMIT 100"

# Query 3: Find charges over 10 dollars
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT service.description, sku.description, location.country, cost, project.id, project.name, currency, currency_conversion_rate, usage.amount, usage.unit FROM \`billing_dataset.sampleinfotable\` WHERE cost > 10"

# Query 4: Count billing records grouped by product service description
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT service.description, COUNT(*) AS billing_records FROM \`billing_dataset.sampleinfotable\` GROUP BY service.description ORDER BY billing_records DESC"

# Query 5: Find most frequently billed products with charges over 1 dollar
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT service.description, COUNT(*) AS billing_records FROM \`billing_dataset.sampleinfotable\` WHERE cost > 1 GROUP BY service.description ORDER BY billing_records DESC"

# Query 6: Find the most commonly charged unit of measure
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT usage.unit, COUNT(*) AS billing_records FROM \`billing_dataset.sampleinfotable\` WHERE cost > 0 GROUP BY usage.unit ORDER BY billing_records DESC"

# Query 7: Calculate aggregate total cost grouped by product service description
bq query --use_legacy_sql=false --location="$LOCATION" \
"SELECT service.description, ROUND(SUM(cost),2) AS total_cost FROM \`billing_dataset.sampleinfotable\` GROUP BY service.description ORDER BY total_cost DESC"

# ==============================================================================
# 6. VERIFICATION SUMMARY
# ==============================================================================
echo ""
echo "=================================================="
echo "DEPLOYMENT VERIFICATION SUMMARY"
echo "=================================================="
echo "Dataset Metadata:"
bq show --format=prettyjson "$PROJECT_ID:$DATASET_NAME" | grep -E '"id"|"location"|"defaultTableExpirationMs"' || true

echo ""
echo "Table Metadata:"
bq show --format=prettyjson "$PROJECT_ID:$DATASET_NAME.$TABLE_NAME" | grep -E '"numRows"|"numBytes"|"type"' || true

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
