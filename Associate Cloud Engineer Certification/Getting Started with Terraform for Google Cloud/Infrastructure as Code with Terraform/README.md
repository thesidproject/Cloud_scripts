# <span style="color:red">THIS SCRIPT MAY NOT WORK - DO MANUALLY</span>

# Infrastructure as Code with Terraform

## Estimated Time: 2:30 minutes

> [!IMPORTANT]
> ### Checkpoint Verification Pause
> The script automates Tasks 2 through 5 (installing Terraform, initializing the provider, provisioning the `terraform` VM, adding tags `["web", "dev"]`, and updating the machine type to `e2-medium`).
> 
> Before running Task 6 (`terraform destroy`), the script **pauses execution** so you can click **Check my progress** in the lab interface for:
> 1. **Build the infrastructure**
> 2. **Adding tags to the compute resource**
> 3. **Change the infrastructure for machine-type**
> 
> Once all three checkpoints turn green, press **[Enter]** in Cloud Shell to trigger Task 6 (`terraform destroy`) and then verify the final checkpoint:
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
   Or bypass the interactive pause before destruction:
   ```bash
   AUTO_DESTROY="true" ./script.sh
   ```

---

## Checkpoints Verified

- **Build the infrastructure:** Verified after initial `terraform apply` provisions the `e2-micro` VM with boot disk and default network.
- **Adding tags to the compute resource:** Verified after in-place update applying tags `["web", "dev"]`.
- **Change the infrastructure for machine-type:** Verified after updating to `e2-medium` with `allow_stopping_for_update = true`.
- **Destroy the Infrastructure:** Verified after `terraform destroy -auto-approve` tears down the resources.
