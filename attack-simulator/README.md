# Attack Simulator README

## Overview

The **Attack Simulator** is a script designed to simulate various security incidents within a Kubernetes environment, specifically to test and validate runtime detection capabilities using Kubescape. This script automates the deployment of a dedicated application, checks the readiness of necessary components, initiates a series of predefined security incidents (or custom scripts provided by the user), and verifies if these incidents are detected correctly by Kubescape.

## Prerequisites

Before running the **Attack Simulator**, ensure you have the following:

- A Kubernetes cluster with Kubescape installed and properly configured.
- The `kubectl` command-line tool set up and configured to interact with your Kubernetes cluster.
- `jq` installed on your system for JSON parsing.
- The default application YAML file (`ping-app.yaml`) or your own application YAML file if you wish to deploy a custom application.
- **Optional**: Custom shell scripts for pre-run activities and/or attack activities if you wish to use them.

## Usage Instructions

1. **Prepare the Script**:
   - Download the script and make it executable by running the following commands:
     ```bash
     git clone https://github.com/armosec/armo-platform-tools.git
     cd armo-platform-tools/attack-simulator/
     chmod +x attack-simulator.sh
     ```

2. **Run the Script**:
   - To deploy a new application and initiate security incidents, simply execute:
     ```bash
     ./attack-simulator.sh
     ```
   - For additional options, including specifying namespaces, custom application YAML files, timeouts, and skipping pre-checks, use the help flag to see all available options:
     ```bash
     ./attack-simulator.sh --help
     ```

3. **Options**:

   **Main Options**:

   - `-n, --namespace NAMESPACE`: Specify the namespace for deploying a new application or locating an existing pod (default: current context namespace or 'default').
   - `--use-existing-pod POD_NAME`: Use an existing pod for the simulation instead of deploying a new one.
   - `--verify-detections`: Run local verification for detections.

   **Advanced Options**:

   - `--pre-run-script PATH`: Specify a shell script to run during the pre-run activities.
   - `--attack-script PATH`: Specify a shell script to run instead of the default attack activities.
   - `--attack-duration DURATION`: Specify the duration to run the attack script (default: `10s`).
   - `--app-yaml-path PATH`: Specify the path to the application YAML file to deploy (default: `ping-app.yaml`).
   - `--mode MODE`: Set the execution mode. Available modes:
     - `interactive`: Wait for user input to initiate security incidents.
     - `investigation`: Allows you to run any command and automatically prints local detections triggered by the command.
     - `run_all_once` (default): Automatically initiates security incidents once and exits.
   - `--learning-period LEARNING_PERIOD`: Set the learning period duration (default: `3m`). Should not be used with `--use-existing-pod`.
   - `--kubescape-namespace KUBESCAPE_NAMESPACE`: Specify the namespace where Kubescape components are deployed (default: `kubescape`).
   - `--skip-pre-checks CHECK1,CHECK2,...`: Skip specific pre-checks before running the script. Available options:
     - `kubectl_installed`: Skips checking if `kubectl` is installed.
     - `kubectl_version`: Skips checking if the `kubectl` client version is compatible with the Kubernetes cluster.
     - `jq_installed`: Skips checking if `jq` is installed.
     - `kubescape_components`: Skips checking if Kubescape components are installed and ready.
     - `runtime_detection`: Skips checking if runtime detection is enabled in Kubescape.
     - `namespace_existence`: Skips checking if the specified namespaces exist.
     - `all`: Skips all of the pre-checks mentioned above.
   - `--kubescape-readiness-timeout TIMEOUT`: Set the timeout for checking Kubescape components readiness (default: `10s`).
   - `--app-creation-timeout TIMEOUT`: Set the timeout for application pod creation (default: `60s`).
   - `--app-profile-creation-timeout TIMEOUT`: Set the timeout for application profile creation (default: `10s`).
   - `--app-profile-readiness-timeout TIMEOUT`: Set the timeout for application profile readiness (default: `300s`).
   - `--app-profile-completion-timeout TIMEOUT`: Set the timeout for application profile completion (default: `600s`).
   - `--verify-detections-delay DELAY`: Set the delay before verifying detections (default: `30s`).
   - `--post-app-profile-completion-delay DELAY`: Set the delay after application profile completion (default: `30s`).
   - `--keep-logs`: Keep log files generated during script execution. By default, logs are deleted.
   - `--keep-app`: Keep the deployed application after the script finishes. By default, the application is deleted.
   - `--debug`: Enable debug mode for detailed logging.
   - `-h, --help`: Display detailed usage information and exit.

4. **Cleanup**:
   - After running the simulation, the script will automatically delete the deployed application and log files, unless overridden with `--keep-app` or `--keep-logs`.

## Extended Usage Examples

Here are some examples of how to use the script with different flags and modes:

- **Run in `investigation` mode**:
  In this mode, you can enter any command, and the script will automatically display any threat detections triggered by the command.
  ```bash
  ./attack-simulator.sh --mode investigation
  ```

- **Run in `interactive` mode**:
  This will prompt you for confirmation before security incidents are initiated.
  ```bash
  ./attack-simulator.sh --mode interactive
  ```

- **Using a Custom Application YAML File**:
  To deploy a custom application using your own YAML file:
  ```bash
  ./attack-simulator.sh --app-yaml-path my-custom-app.yaml
  ```

- **Adjusting the Learning Period**:
  To set a different learning period for the application (e.g., 5 minutes):
  ```bash
  ./attack-simulator.sh --learning-period 5m
  ```

- **Using a Custom Pre-Run Script**:
  To use a custom shell script for pre-run activities:
  ```bash
  ./attack-simulator.sh --pre-run-script /path/to/your/pre-run-script.sh
  ```
  - **Note**: Ensure that the script is executable and compatible with the environment inside the pod.

- **Using a Custom Attack Script**:
  To use a custom shell script for attack activities instead of the default incidents:
  ```bash
  ./attack-simulator.sh --attack-script /path/to/your/attack-script.sh
  ```
  - **Adjusting Attack Duration**:
    To specify the duration for which the attack script runs (e.g., 20 seconds):
    ```bash
    ./attack-simulator.sh --attack-script /path/to/your/attack-script.sh --attack-duration 20s
    ```
  - The script will execute your custom attack script inside the pod and monitor logs for any detections.

- **Using Both Custom Scripts**:
  To use both custom pre-run and attack scripts:
  ```bash
  ./attack-simulator.sh --pre-run-script /path/to/your/pre-run-script.sh --attack-script /path/to/your/attack-script.sh
  ```

- **Skipping Specific Pre-checks**:
  This example skips checking whether `kubectl` and `jq` are installed and bypasses the `runtime_detection` enablement check.
  ```bash
  ./attack-simulator.sh --skip-pre-checks kubectl_installed,jq_installed,runtime_detection
  ```

- **Verifying Detections Locally**:
  Use this command to verify local detections triggered by the incidents without re-running the simulation.
  ```bash
  ./attack-simulator.sh --verify-detections
  ```

- **Using an Existing Pod**:
  If you want to reuse an existing pod (`my-existing-pod`) for the simulation instead of deploying a new one:
  ```bash
  ./attack-simulator.sh --use-existing-pod my-existing-pod
  ```

- **Enabling Debug Mode**:
  To enable detailed logging for troubleshooting purposes:
  ```bash
  ./attack-simulator.sh --debug
  ```

- **Adjusting Post Application Profile Completion Delay**:
  To set a different delay after the application profile has completed (e.g., 60 seconds):
  ```bash
  ./attack-simulator.sh --post-app-profile-completion-delay 60s
  ```

## How It Works

- **Deploys a web application**: The script deploys a web application with a unique name, configured to operate for a specific learning period.
- **Verifies readiness**: It checks the readiness of Kubescape's components and ensures runtime detection capabilities are enabled.
- **Generates activities to populate the application profile**: If a custom pre-run script is provided via `--pre-run-script`, the script copies and executes it inside the pod to generate baseline activities. Otherwise, it performs default pre-run activities.
- **Waits for the application profile to complete**: After generating activities, the script waits for the application profile to reach the `completed` status. Once completed, it waits for an additional delay (configurable via `--post-app-profile-completion-delay`, default: `30s`) to ensure all components are fully ready.
- **Initiates security incidents**: The script triggers multiple simulated security incidents, such as unauthorized API access, unexpected process launches, environment variable exposure, and crypto mining domain communication. If a custom attack script is provided via `--attack-script`, it executes the script inside the pod instead of the default incidents.
  - **Adjusting Attack Duration**: You can specify how long the attack script should run using the `--attack-duration` option.
- **Monitors and verifies detections**: After initiating the incidents, the script monitors the logs to confirm that Kubescape has accurately detected each incident. When using a custom attack script, it logs any new events after a checkpoint and filters them by the application name.
  - **Verification Delay**: The script waits for a configurable delay (default: `30s`, set via `--verify-detections-delay`) before verifying detections to allow time for logs to be generated.
- **Centralized Logging**: The script uses a centralized logging mechanism, and you can enable detailed logging (debug mode) using the `--debug` option.
- **Automatically cleans up**: By default, the script deletes the test application and removes log files unless `--keep-app` or `--keep-logs` arguments are used to override this behavior.

---

**Note**: This script is designed for testing and educational purposes within controlled environments.