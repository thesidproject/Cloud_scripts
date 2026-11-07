# Configure Google Cloud HA VPN

## Estimated Time: 5 minutes

> [!WARNING]
> **Status: Probably Not Working**
> This lab does not have automated "Check my progress" checkpoints and is marked to be completed later.

> [!NOTE]
> **Lab Type & Completion Requirement:**
> This is an un-scored guided walkthrough lab without automated "Check my progress" checkpoints.
> To receive course completion credit:
> 1. Run the script to provision the resources.
> 2. Keep the lab session active for at least 5 minutes.
> 3. Click **End Lab** to trigger the syllabus green checkmark.

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   ```
###  (Paste the script code from VS Code, then press Ctrl+S to save, and Ctrl+X to exit)

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override regions or zones inline if assigned different parameters:
   ```bash
   REGION1="europe-west1" ZONE1="europe-west1-b" REGION2="us-east4" ZONE2="us-east4-b" ./script.sh
   ```
