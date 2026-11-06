# THIS ONE IS NOT TESTED

## Estimated Time:
~5-7 minutes (creating 3 VPC networks, 8 firewall rules, and 4 VM instances across two continents)

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

3. *(Optional)* If your lab assigned different regions or zones:
   ```bash
   REGION_1="your-us-region" ZONE_1="your-us-zone" REGION_2="your-eu-region" ZONE_2="your-eu-zone" ./script.sh
   ```
