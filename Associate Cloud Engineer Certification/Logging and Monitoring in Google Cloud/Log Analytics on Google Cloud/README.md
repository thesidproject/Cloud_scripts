# Log Analytics on Google Cloud

## Estimated Time: 6:30 minutes

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   ```
### (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override parameters inline if assigned different values:
   ```bash
   REGION="us-west1" ZONE="us-west1-b" CLUSTER_NAME="day2-ops" LOG_BUCKET_NAME="day2ops-log" SINK_NAME="day2ops-sink" ./script.sh
   ```
