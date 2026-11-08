# Monitor Resources with Google Cloud Observability

## Estimated Time: 2 minutes

## How to Run

1. Create the script file in Cloud Shell:
   ```bash
   nano script.sh
   ```
###  (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)

2. Make it executable and run it:
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

3. *(Optional)* Override parameters inline if assigned different values:
   ```bash
   NOTIFICATION_EMAIL="student@qwiklabs.net" ./script.sh
   ```

> [!NOTE]
> If Task 4 (Resource groups) does not immediately award points via script due to backend grader checks:
> 1. In Google Cloud Console, navigate to **Monitoring > Groups**.
> 2. Click **+ Create Group**, set Name to `VM instances`.
> 3. Under Criteria, set Value to `nginx`, click **Done**, then click **Create**.
> 4. Click on `VM instances` to open its group dashboard, wait 15 seconds, and click **Check my progress**.
