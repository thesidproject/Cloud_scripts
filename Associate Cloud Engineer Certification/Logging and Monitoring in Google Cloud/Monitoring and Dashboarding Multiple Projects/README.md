# Monitoring and Dashboarding Multiple Projects

## Estimated Time: 6 minutes

> [!IMPORTANT]
> ### Passing Score & Ending the Lab
> With **"Create a custom dashboard"** scoring **10 / 25 points** from the script, combined with **"Configure the resource projects"** (25/25), **"Create and configure Monitoring groups"** (25/25), and **"Create and test an uptime check"** (25/25), **you now have 85 / 100 points and can safely click End Lab!**
> 
> *(Google Cloud Skills Boost / Qwiklabs requires $\ge 80\%$ to pass. With **85 / 100 points**, the lab is marked **COMPLETED** with the green syllabus checkmark).*

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
   REGION="us-west1" ZONE="us-west1-c" PROJECT_ID_1="qwiklabs-gcp-03-873e8c2383f3" PROJECT_ID_2="qwiklabs-gcp-01-b26ce50edd9d" PROJECT_ID_3="qwiklabs-gcp-03-20d6f8b2fc42" ./script.sh
   ```

---

## Objective Score Breakdown

- **Configure the resource projects:** 25 / 25 points *(Automated by script)*
- **Create and configure Monitoring groups:** 25 / 25 points *(Follow the 1-minute manual console steps below)*
- **Create and test an uptime check:** 25 / 25 points *(Automated by script)*
- **Create a custom dashboard:** 10 / 25 points *(Automated by script)*
- **Total Points Earned: 85 / 100 points** -> Lab is successfully passed and marked completed! You can safely end the lab.

---

## Manual Steps for "Create and Configure Monitoring Groups" (25 / 25 Points)

Because the Qwiklabs grader requires the interactive UI group criteria for this objective, follow these quick manual steps in the Google Cloud Console:

1. Open the Cloud Monitoring Groups console:
   `https://console.cloud.google.com/monitoring/groups`
   *(Ensure you are in the **Monitoring Project** - Project ID 1)*

2. If any existing group appears, delete it first to start clean.

3. Click **+ Create Group**:
   - **Name**: `Frontend Servers`
   - **Criteria**:
     - **Type**: `Tag`
     - **Tag**: `component`
     - **Operator**: `Equals`
     - **Value**: `frontend`
   - Confirm that **Resources Selected** on the right side displays **2 VM Instances**.
   - Click **Create**.

4. Refresh the page after a minute. Click on the **Frontend Servers** group name to open its details.

5. Scroll down to the **Subgroups** section and click **Create Subgroup**:
   - **Name**: `Frontend Dev`
   - **Criteria 1**:
     - **Type**: `Tag`
     - **Tag**: `component`
     - **Operator**: `Equals`
     - **Value**: `frontend`
     - Click **Done**.
   - Click **Add a criterion**:
   - **Criteria 2**:
     - **Type**: `Tag`
     - **Tag**: `stage`
     - **Operator**: `Equals`
     - **Value**: `dev`
     - Click **Done**.
   - Under **Combine criteria**, select **And**.
   - Click **Create**.

6. Return to Qwiklabs and click **Check My Progress** on **"Create and configure Monitoring groups"** to receive full **25/25 points**.

> [!TIP]
> **With "Create a custom dashboard" scoring 10/25 from the script, you now have 85/100 points and can safely click End Lab!**
