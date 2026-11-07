# Google Cloud Shell bash scripts


---

## Repository Structure

```text
<Certification Path Name>/
└── <Course Name>/
    └── <Lab Name>/
        ├── script.sh    # Standalone, idempotent automation script
        └── README.md    # Estimated completion time and execution guide
```

---

## Important Execution Guidelines

### 1. Standard Run Sequence
Inside Google Cloud Shell:
```bash
nano script.sh
```
###  (Paste the script code from VS Code, then press Ctrl+S to save, and Ctrl+X to exit)
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
