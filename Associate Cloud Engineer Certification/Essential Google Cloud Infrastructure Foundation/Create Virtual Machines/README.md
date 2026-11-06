## Estimated Time:
~3-4 minutes (provisions 3 VM instances in parallel: Debian with no external IP, Windows Server 2025 on SSD, and Custom E2 VM)

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   # (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)
   ```

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* If your lab assigned a different region or zone:
   ```bash
   REGION="your-region" ZONE="your-zone" ./script.sh
   ```
