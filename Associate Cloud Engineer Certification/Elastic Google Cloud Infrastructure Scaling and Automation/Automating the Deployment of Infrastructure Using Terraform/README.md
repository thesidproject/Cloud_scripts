# Automating the Deployment of Infrastructure Using Terraform

## Estimated Time: 2 minutes

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
   REGION_1="europe-west4" ZONE_1="europe-west4-c" REGION_2="europe-west1" ZONE_2="europe-west1-b" ./script.sh
   ```
