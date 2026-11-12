# Google Cloud Shell bash scripts


## Repository Structure

```text
<Certification Path Name>/
└── <Course Name>/
    └── <Lab Name>/
        ├── script.sh    # Standalone, idempotent automation script
        └── README.md    # Estimated completion time and execution guide
```

---


## Instructions for dumbos

1. Download the zip file of project, extract it
2. Open Antigravity on extracted directory (use Gemini 3.8 Flash (High) in Antigravity)
3. Open Chrome and open Google Skills
4. Start the lab
5. After lab started successfully remain on the same skills lab where there are instructions and give login details
6. Open Ask Gemini on Chrome and share the tab with it
7. Use Gemini 3.6 Flash
8. Give prompt exactly this:

   ```text
   You are an expert Google Cloud engineer analyzing a Google Cloud Skills Boost / Qwiklabs lab.
   
   Extract all instructions, configurations, and verification criteria from the provided lab text and output them in the exact structured markdown format below.
   
   CRITICAL EXTRACTION RULES:
   1. NO GENERIC PLACEHOLDERS: NEVER output generic placeholders like "REGION", "ZONE", or "[YOUR_REGION]". Look through the entire text, tables, commands, and connection details for the ACTUAL assigned values (e.g., `us-east1`, `us-east1-c`). If multiple regions/zones appear (e.g., primary vs secondary), extract all of them explicitly.
   2. 100% VERBATIM CODE: Extract all startup scripts, code files, and shell commands EXACTLY as written. Do not reorder flags, remove/add commands (like apt-get update), or "improve" the code, as automated lab graders test for exact string matches.
   3. CONSOLE DEFAULTS: If a step says "leave all remaining settings as default" in the Google Cloud Console, explicitly note the implied default values (e.g., location type, storage class, public access prevention).
   4. EXACT CHECKPOINT NAMES: Extract the exact names of the "Check my progress" assessment checkpoints and point values if available.
   
   ---
   ### Output Format:
   
   # Module Name: <Exact Name of the Course Module>
   ## Lab Name: <Exact Name of the Lab>
   
   ### 1. Lab Overview & Objectives
   * Brief summary of what the lab builds or configures.
   
   ### 2. Lab Parameters (Actual Assigned Values)
   * Primary Region: (e.g., us-east1)
   * Primary Zone: (e.g., us-east1-c)
   * Secondary Region / Region 2 (if any): (e.g., europe-west1 or us-central1)
   * Secondary Zone / Zone 2 (if any): (e.g., europe-west1-d or us-central1-a)
   * Project ID / Default Bucket Suffix: (e.g., $DEVSHELL_PROJECT_ID)
   
   ### 3. Fixed Resource Specifications
   * Compute / GKE: <Instance names, machine types, image version, tags, boot disk size/type>
   * Storage / Database: <Bucket names, SQL instance ID, DB version, root password>
   * Networks / Subnets: <VPC names, subnet names, CIDR ranges>
   * Firewall Rules: <Rule names, target tags, allowed ports/protocols, source ranges>
   * Metadata / Startup Scripts: <Verbatim script contents or URLs>
   
   ### 4. Step-by-Step Task Breakdown
   For each task:
   #### Task <N>: <Task Title>
   * **Objective**: What needs to be done.
   * **Console / CLI Configurations**: Step-by-step actions and exact verbatim commands.
   * **Implied Console Defaults** (if applicable): <e.g., Multi-region US, Uniform Access, etc.>
   * **Checkpoint / Grader Requirement**: Exact checkpoint name and condition that triggers the green checkmark.
   
   ### 5. Verification Commands
   * CLI commands to verify that the resources are active and healthy before clicking "Check my progress".
   ---
   
   Here is the lab content to extract:
   <PASTE YOUR LAB CONTENT / TRANSCRIPT / WEBPAGE TEXT HERE>
   (always include all the info given here (exact))
   ```

9. Copy the output and paste it in Antigravity
10. Ask Antigravity (using Gemini 3.8 Flash (High)) to update the script according to given details
11. Paste the updated script in Google Cloud Shell
12. Remember the 80% Passing Score Rule: Google Cloud Skills Boost / Qwiklabs marks a lab complete with a syllabus green checkmark once you reach 80% or higher (e.g., 13/15 points or 80/100 points). If a minor optional step lags in log propagation, check if you have already met the 80% threshold before spending extra time debugging
13. Don't forget to read current README of each lab

---

## Important Execution Guidelines

### 1. Standard Run Sequence
Inside Google Cloud Shell:
```bash
nano script.sh
```
### (Paste the script code, then press Ctrl+S to save, and Ctrl+X to exit)
```bash
chmod +x script.sh
./script.sh
```

### 2. Inline Variable Overrides
All scripts use configurable defaults that automatically discover the active `PROJECT_ID` and region/zone. If a lab assigns custom parameters, override them inline without editing the file:
```bash
REGION="us-east1" ZONE="us-east1-b" ./script.sh
```

### 3. Progress Verification
Wait until the green ASCII completion banner appears before clicking **Check my progress** in the Qwiklabs console.
