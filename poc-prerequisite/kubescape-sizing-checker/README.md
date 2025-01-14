# Kubescape Sizing Checker

## Overview

Kubescape Sizing Checker analyzes your Kubernetes cluster's resources and generates recommended Helm values to ensure Kubescape runs smoothly and efficiently.

## Prerequisites

- **Kubernetes Cluster** with `kubectl` configured.
- **Helm** installed on your local machine.
- **Permissions** to create ServiceAccounts, ClusterRoles, ClusterRoleBindings, and Jobs.

## Installation

1. **Deploy the Sizing Checker Job**

   Apply the Kubernetes manifest to set up the necessary resources:

   ```sh
   kubectl apply -f kubescape-sizing-checker-job.yaml
   ```

2. **Verify Job Completion**

   Check the status and logs of the Job:

   ```sh
   kubectl get jobs kubescape-sizing-checker
   kubectl logs job/kubescape-sizing-checker
   ```

## Usage

### Export Recommended Values

Retrieve the `recommended-values.yaml` from the ConfigMap:

```sh
kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data "recommended-values.yaml" }}' > recommended-values.yaml
```

### Deploy Kubescape with Recommended Resources

Use Helm to deploy Kubescape using the recommended values:

```sh
helm upgrade --install kubescape kubescape/kubescape-operator \
  --namespace kubescape --create-namespace \
  --values recommended-values.yaml [other parameters or value files here]
```

### (Optional) View the Sizing Report

If you want to review the sizing report, export and open the HTML file:

1. **Export the HTML Report**

   ```sh
   kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data "sizing-report.html" }}' > sizing-report.html
   ```

2. **Open in Browser**

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

## Troubleshooting

- **Empty Exported Files:**
  - Ensure the ConfigMap `sizing-report` in the `kubescape` namespace contains data.
  - Verify the `go-template` syntax used in export commands.

- **Permission Errors:**
  - Confirm the `kubescape-sizing-checker` ServiceAccount has the necessary ClusterRole permissions.
  - Review ClusterRole and ClusterRoleBinding configurations.

- **Job Failures:**
  - Inspect Job logs for errors:
    ```sh
    kubectl logs job/kubescape-sizing-checker
    ```

## License

This project is licensed under the [MIT License](LICENSE).
