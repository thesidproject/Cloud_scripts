# Examine Billing data with BigQuery

## Estimated Time: 3 minutes

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   ```
###  (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override parameters inline if assigned different values:
   ```bash
   LOCATION="US" DATASET_NAME="billing_dataset" TABLE_NAME="sampleinfotable" ./script.sh
   ```
