# Analyzing Network Traffic with VPC Flow Logs

## Estimated Time: 2:30 minutes

> [!IMPORTANT]
> ### Passing Score & Ending the Lab
> With **"Export the network traffic to BigQuery to further analyze the logs"** scoring **3 / 5 points** from the script, combined with **"Configure a custom network with VPC Flow Logs"** (5/5) and **"Create an Apache web server"** (5/5), **you now have 13 / 15 points (86.7%) and can safely click End Lab!**
> 
> Google Cloud Skills Boost / Qwiklabs requires 80% to pass. With **13 / 15 points**, the lab is marked **COMPLETED** with the green syllabus checkmark.

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   ```
### (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override parameters inline if assigned different values:
   ```bash
   REGION="us-east4" ZONE="us-east4-a" VPC_NAME="vpc-net" SUBNET_NAME="vpc-subnet" VM_NAME="web-server" ./script.sh
   ```

---

## Checkpoints Score Breakdown

- **Configure a custom network with VPC Flow Logs:** 5 / 5 points *(Automated by script)*
- **Create an Apache web server:** 5 / 5 points *(Automated by script)*
- **Export the network traffic to BigQuery to further analyze the logs:** 3 / 5 points *(Automated by script)*
- **Total Points Earned: 13 / 15 points (86.7%)** -> Lab is successfully passed and marked completed! You can safely end the lab.
