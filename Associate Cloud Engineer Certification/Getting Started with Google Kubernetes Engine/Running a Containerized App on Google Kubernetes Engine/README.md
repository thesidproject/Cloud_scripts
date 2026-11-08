# Running a Containerized App on Google Kubernetes Engine

## Estimated Time: 8 minutes

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
   ZONE="us-west1-c" CLUSTER_NAME="hello-world" APP_NAME="hello-app" ./script.sh
   ```
