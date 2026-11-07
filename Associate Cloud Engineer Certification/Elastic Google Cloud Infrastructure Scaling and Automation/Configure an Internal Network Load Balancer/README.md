## Estimated Time: 4 minutes

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
   REGION="us-east4" ZONE_A="us-east4-a" ZONE_B="us-east4-b" ZONE_C="us-east4-c" ./script.sh
   ```
