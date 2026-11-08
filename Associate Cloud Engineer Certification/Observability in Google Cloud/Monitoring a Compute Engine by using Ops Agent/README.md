# Monitoring a Compute Engine by using Ops Agent

## Estimated Time: 2:30 minutes

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
   REGION="us-west1" ZONE="us-west1-b" VM_NAME="quickstart-vm" MACHINE_TYPE="e2-small" ./script.sh
   ```

---

## Task 4 Note: Apache Overview Dashboard

After the script finishes generating traffic, you can view the automatically provisioned Apache metrics charts in the Google Cloud Console:
- Navigate to **Monitoring > Dashboards** or go directly to https://console.cloud.google.com/monitoring/dashboards.
- Under **All Dashboards**, open the **Apache Overview** dashboard to view traffic rate, latency, and worker metrics.
