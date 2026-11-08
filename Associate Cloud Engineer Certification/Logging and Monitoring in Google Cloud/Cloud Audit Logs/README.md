# Cloud Audit Logs

## Estimated Time: 2:30 minutes

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
   REGION="us-west1" ZONE="us-west1-b" VM_NAME="default-us-vm" NETWORK_NAME="mynetwork" ./script.sh
   ```

---

## Task 3. Viewing audit logs

In this task, you view and explore both Admin Activity and Data Access audit logs in the Logs Explorer, examining the details of logged events such as bucket deletion and data access operations. You then read the Data Access logs using the Cloud SDK.

Admin Activity logs contain log entries for API calls or other administrative actions that modify the configuration or metadata of resources. For example, the logs record when VM instances and App Engine applications are created, or when permissions are changed. To view the logs, you must have the Cloud Identity and Access Management roles Logging/Logs Viewer or Project/Viewer.

Admin Activity logs are always enabled so there is no need to enable them. There is no charge for your Admin Activity audit logs.

1. In the Google Cloud console, navigate to https://console.cloud.google.com/logs/query.

2. In Logs Explorer, enable **Show query** and delete the contents of Query box.

3. Click the **All log names** dropdown and use the filter to locate the **activity** log under **Cloud Audit** section and **Apply** it to the query.

4. Press the **Run query** button, and then use the Log fields explorer to filter to **GCS Bucket** entries.

5. Locate the log entry for when the Cloud Storage was deleted.

6. Expand the delete entry, then drill into `protoPayload > authenticationInfo` field and notice you can see the email address of the user that performed this action.

7. Feel free to explore other fields in the entry. Also, notice how many of the values can be clicked to add inclusions/exclusions to the query.

8. Delete the existing query and use **All log names** to view the **data_access** logs, then click **Run query**.
