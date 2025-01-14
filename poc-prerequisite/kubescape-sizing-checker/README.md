# Kubescape Sizing Checker

## Overview

Kubescape Sizing Checker analyzes your Kubernetes cluster's resources and generates recommended Helm values to ensure Kubescape runs smoothly and efficiently.

## Prerequisites

- **Kubernetes Cluster** with `kubectl` configured.
- **Permissions** to create ServiceAccounts, ClusterRoles, ClusterRoleBindings, and Jobs.

## Run the Check

There are two ways to run the check:

### Option 1 - Local Run

1. Navigate to the command directory and Execute the program:
   ```sh
   cd /cmd
   go run .
   ```

### Option 2 - Deploy the Sizing Checker Job

1. **Deploy the Kubernetes manifest:**

   Apply the Kubernetes manifest to set up the necessary resources:

   ```sh
   kubectl apply -f kubescape-sizing-checker-job.yaml
   ```

2. **Verify Job Completion:**

   Check the status and logs of the Job:

   ```sh
   kubectl get jobs kubescape-sizing-checker
   kubectl logs job/kubescape-sizing-checker
   ```

3. **Export the Files:**

   Retrieve the `recommended-values.yaml` and `sizing-report.html` from the ConfigMap:

   ```sh
   kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data "recommended-values.yaml" }}' > recommended-values.yaml
   kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data "sizing-report.html" }}' > sizing-report.html
   ```

## Usage

### Deploy Kubescape with Recommended Resources

Use Helm to deploy Kubescape using the recommended values:

```sh
helm upgrade --install kubescape kubescape/kubescape-operator \
  --namespace kubescape --create-namespace \
  --values recommended-values.yaml [other parameters or value files here]
```

### (Optional) View the Sizing Report

If you want to review the sizing report, export and open the HTML file:

1. **Export the HTML Report:**

   ```sh
   kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data "sizing-report.html" }}' > sizing-report.html
   ```

2. **Open in Browser:**

   - **macOS:**
     ```sh
     open sizing-report.html
     ```
   - **Linux:**
     ```sh
     xdg-open sizing-report.html
     ```
   - **Windows (Git Bash):**
     ```sh
     start sizing-report.html
     ```
