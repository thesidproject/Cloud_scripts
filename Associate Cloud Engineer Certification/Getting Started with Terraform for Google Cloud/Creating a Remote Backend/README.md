# Creating a Remote Backend

## Estimated Time: 2:00 minutes

> [!IMPORTANT]
> ### Checkpoint Verification Pause
> The script automates Tasks 2 through 5 (installing Terraform, provisioning the Cloud Storage bucket with a local backend, migrating state to a remote Cloud Storage backend, and adding bucket labels before executing `terraform refresh`).
> 
> Before running Task 6 (`terraform destroy`), the script **pauses execution** so you can click **Check my progress** in the lab interface for:
> 1. **Add a local backend**
> 2. **Add a Cloud Storage backend**
> 3. **Refresh the state**
> 
> Once all three checkpoints turn green, press **[Enter]** in Cloud Shell to allow the script to migrate state back to local storage and tear down the bucket to complete:
> 4. **Clean up the workspace**

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
   REGION="us-central1" BUCKET_NAME="qwiklabs-gcp-03-fd4ee171f4eb" ./script.sh
   ```
   Or bypass the interactive pause before destruction:
   ```bash
   AUTO_DESTROY="true" ./script.sh
   ```

---
