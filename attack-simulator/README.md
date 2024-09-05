# Attack Simulator README

## Overview

The **Attack Simulator** is a script designed to simulate various security incidents within a Kubernetes environment to test and validate runtime detection capabilities using Kubescape. The script deploys a web application pod, verifies the readiness of necessary components, initiates predefined security incidents, and checks if these incidents are correctly detected by Kubescape.

## Prerequisites

- A Kubernetes cluster with Kubescape installed and configured.
- The `kubectl` command-line tool configured to interact with your Kubernetes cluster.
- `jq` installed for JSON parsing.

## Usage Instructions

1. **Prepare the Script**:
   - Make the script executable:
     ```bash
     chmod +x attack-simulator.sh
     ```

2. **Run the Script**:
   - To deploy a new pod and initiate security incidents:
     ```bash
     ./attack-simulator.sh
     ```
   - To specify a namespace or use other options, refer to the script’s help:
     ```bash
     ./attack-simulator.sh --help
     ```

3. **Options**:
   - `-n, --namespace NAMESPACE`: Specify the namespace for deploying the pod (default: current context namespace or 'default').
   - `--initiate-incidents-once`: Automatically trigger all security incidents once without prompting.
   - `--skip-pre-checks`: Skip the pre-checks for component readiness and configuration.
   - `--use-existing-pod POD_NAME`: Use an existing pod instead of deploying a new one.
   - `--learning-period LEARNING_PERIOD`: Set the learning period duration for the web app (default: 3m). This is applicable only when creating a new pod.
   - `-h, --help`: Display usage information.

4. **Initiate Security Incidents**:
   - To automatically initiate incidents once:
     ```bash
     ./attack-simulator.sh --initiate-incidents-once
     ```
   - To interactively initiate incidents based on prompts, simply run the script without the `--initiate-incidents-once` flag.

5. **Cleanup**:
   - The script will prompt you to delete the deployed pod after execution. Choose to clean up or retain it for further analysis.

## How It Works

- **Deploys a web app pod** with a unique name and a configurable learning period.
- **Verifies the readiness** of Kubescape's components and checks if runtime detection capabilities are enabled.
- **Initiates multiple predefined security incidents**, such as unauthorized API access, unexpected process launches, environment variable exposure, and crypto mining domain communication.
- **Verifies detection logs** to ensure that the incidents are accurately detected by Kubescape.
- **Prompts for cleanup** to remove the test pod after the simulation is complete.

---

**Note**: This script is designed for testing and educational purposes within controlled environments.