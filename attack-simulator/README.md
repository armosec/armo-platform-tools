# Attack Simulator README

## Overview

The **Attack Simulator** is a script designed to simulate various security incidents within a Kubernetes environment, specifically to test and validate runtime detection capabilities using Kubescape. This script automates the deployment of a dedicated application, checks the readiness of necessary components, initiates a series of predefined security incidents, and verifies if these incidents are detected correctly by Kubescape.

## Prerequisites

Before running the **Attack Simulator**, ensure you have the following:

- A Kubernetes cluster with Kubescape installed and properly configured.
- The `kubectl` command-line tool set up and configured to interact with your Kubernetes cluster.
- `jq` installed on your system for JSON parsing.
- The default application YAML file (`ping-app.yaml`) or your own application YAML file if you wish to deploy a custom application.

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

   - `-n, --namespace NAMESPACE`: Specify the namespace where the application should be deployed or where the existing pod is located (default: current context namespace or 'default').
   - `--mode MODE`: Set the execution mode. Available modes:
     - `interactive`: Wait for user input to initiate security incidents.
     - `investigation`: Run any command and automatically print local detections triggered by the command.
     - `run_all_once` (default): Automatically initiate security incidents once and exit.
   - `--verify-detections`: Run local verification for detections.
   - `--use-existing-pod POD_NAME`: Use an existing pod for the simulation instead of deploying a new one.
   - `--app-yaml-path PATH`: Specify the path to the application YAML file to deploy (default: `ping-app.yaml`).

   **Additional Options**:

   - `--kubescape-namespace KUBESCAPE_NAMESPACE`: Specify the namespace where Kubescape components are deployed (default: `kubescape`).
   - `--learning-period LEARNING_PERIOD`: Define the duration for the learning period of the application (default: `3m`). Applicable only when deploying a new application.
   - `--skip-pre-checks CHECK1,CHECK2,... | all`: Skip specific pre-checks before the script runs. Available options:
     - `kubectl_installed`: Skips checking if `kubectl` is installed.
     - `kubectl_version`: Skips checking if the `kubectl` client version is compatible with the Kubernetes cluster.
     - `jq_installed`: Skips checking if `jq` is installed.
     - `kubescape_components`: Skips checking if Kubescape components are installed and ready.
     - `runtime_detection`: Skips checking if runtime detection is enabled in Kubescape.
     - `namespace_existence`: Skips checking if the specified namespaces exist.
     - `all`: Skips all of the pre-checks mentioned above.
   - `--verify-detections-delay DELAY`: Set the delay before verifying detections (default: `10s`).
   - `--kubescape-readiness-timeout TIMEOUT`: Set the timeout for checking Kubescape components readiness (default: `10s`).
   - `--app-creation-timeout TIMEOUT`: Set the timeout for application pod creation (default: `60s`).
   - `--app-profile-creation-timeout TIMEOUT`: Set the timeout for application profile creation (default: `10s`).
   - `--app-profile-readiness-timeout TIMEOUT`: Set the timeout for application profile readiness (default: `300s`).
   - `--app-profile-completion-timeout TIMEOUT`: Set the timeout for application profile completion (default: `600s`).
   - `-h, --help`: Display detailed usage information and exit.

4. **Cleanup**:
   - After running the simulation, the script will prompt you to decide whether to delete the deployed application. You can choose to clean up or retain the application for further analysis and investigation.

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

## How It Works

- **Deploys a web application**: The script deploys a web application with a unique name, configured to operate for a specific learning period.
- **Verifies readiness**: It checks the readiness of Kubescape's components and ensures runtime detection capabilities are enabled.
- **Initiates predefined security incidents**: The script triggers multiple simulated security incidents, such as unauthorized API access, unexpected process launches, environment variable exposure, and crypto mining domain communication.
- **Verifies detection logs**: After initiating the incidents, the script checks the logs to confirm that Kubescape has accurately detected each incident.
- **Prompts for cleanup**: Finally, it prompts the user to remove the test application, ensuring a clean environment after the simulation.

---

**Note**: This script is designed for testing and educational purposes within controlled environments.