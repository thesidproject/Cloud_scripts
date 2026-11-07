# Configure an Application Load Balancer with Autoscaling

## Estimated Time: 11 minutes

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   # (Paste the script code from VS Code, then press Ctrl+S to save, and Ctrl+X to exit)
   ```

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override regions or zones inline if assigned different parameters:
   ```bash
   REGION1="us-east1" ZONE1="us-east1-d" REGION2="asia-south1" ./script.sh
   ```
