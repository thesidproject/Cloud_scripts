## Estimated Time:
~3-4 minutes (provisions VM with attached 50GB SSD, reserves static IP, formats disk, installs Minecraft, and schedules backups)

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

3. *(Optional)* If your lab assigned a different region or zone (defaults to `us-east4` and `us-east4-c`):
   ```bash
   REGION="your-region" ZONE="your-zone" ./script.sh
   ```
