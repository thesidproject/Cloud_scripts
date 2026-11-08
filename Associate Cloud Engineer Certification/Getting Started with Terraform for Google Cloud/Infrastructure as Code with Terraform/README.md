# <span style="color:red">THIS SCRIPT IS NOT WORKING - DO MANUALLY</span>

# Infrastructure as Code with Terraform

> [!CAUTION]
> # <span style="color:red">THIS SCRIPT IS NOT WORKING - DO MANUALLY</span>
> **Do not use this script. Please follow the lab guide and complete all tasks manually in Cloud Shell and Google Cloud Console.**

## Estimated Time: 2:30 minutes

> [!IMPORTANT]
> ### Checkpoint Verification Pause
> The script automatically provisions the instance, updates the tags, and scales the machine type. Before running `terraform destroy` (Task 5), the script **pauses execution** so you can click **Check my progress** in the lab interface for:
> 1. **Build the infrastructure**
> 2. **Adding tags to the compute resource**
> 3. **Change the infrastructure for machine-type**
> 
> Once all three checkpoints turn green, press **[Enter]** in Cloud Shell to allow Terraform to tear down the infrastructure and complete:
> 4. **Destroy the Infrastructure**

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
   REGION="us-west1" ZONE="us-west1-b" VM_NAME="terraform" ./script.sh
   ```
   Or run without the checkpoint pause if desired:
   ```bash
   AUTO_DESTROY="true" ./script.sh
   ```
