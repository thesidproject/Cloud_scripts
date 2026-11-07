# Accessing the Google Cloud Console and Cloud Shell

## Estimated Time: 2 minutes

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

3. *(Optional)* Override region or zone inline if assigned different parameters:
   ```bash
   REGION="europe-west1" ZONE="europe-west1-c" ./script.sh
   ```
