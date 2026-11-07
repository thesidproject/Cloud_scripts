## Estimated Time: 2 minutes

> **Note for Task 1:** In the Google Cloud Console, navigate to **Marketplace > Search "LAMP Stack on Debian12" (by Apps4Rent LLC) > Click Get Started > Deploy** (Zone: `us-central1-b`, Series: `E2`, Machine type: `e2-medium`). This script verifies the deployment, checks firewall rules, and validates the HTTP web server.

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

3. *(Optional)* If your lab assigned a specific zone:
   ```bash
   ZONE="your-zone" ./script.sh
   ```
