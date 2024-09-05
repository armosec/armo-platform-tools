# Attack Simulator README

## Overview

The **Attack Simulator** is a script designed to simulate various security incidents within a Kubernetes environment, specifically to test and validate runtime detection capabilities using Kubescape. This script automates the deployment of a web application pod, checks the readiness of necessary components, initiates a series of predefined security incidents, and verifies if these incidents are detected correctly by Kubescape.

## Prerequisites

Before running the **Attack Simulator**, ensure you have the following:

- A Kubernetes cluster with Kubescape installed and properly configured.
- The `kubectl` command-line tool set up and configured to interact with your Kubernetes cluster.
- `jq` installed on your system for JSON parsing.

## Usage Instructions

1. **Prepare the Script**:
   - Make the script executable by running the following command:
     ```bash
     chmod +x attack-simulator.sh
     ```

2. **Run the Script**:
   - To deploy a new pod and initiate security incidents, simply execute:
     ```bash
     ./attack-simulator.sh
     ```
   - For additional options, including specifying namespaces and skipping pre-checks, use the help flag to see all available options:
     ```bash
     ./attack-simulator.sh --help
     ```

3. **Options**:
   - `-n, --namespace NAMESPACE`: Specify the namespace where the pod should be deployed (default: uses the current context namespace or 'default').
   - `--kubescape-namespace KUBESCAPE_NAMESPACE`: Specify the namespace where Kubescape components are deployed (default: 'kubescape').
   - `--interactive`: Interactively initiate security incidents based on user prompts.
   - `--skip-pre-checks`: Skip the initial pre-checks that ensure component readiness and proper configuration.
   - `--use-existing-pod POD_NAME`: Use an existing pod for the simulation instead of deploying a new one.
   - `--learning-period LEARNING_PERIOD`: Define the duration for the learning period of the web app (default: 3 minutes). This option is applicable only when deploying a new pod.
   - `-h, --help`: Display detailed usage information and exit.

4. **Initiate Security Incidents**:
   - To initiate incidents interactively based on user prompts, use the `--interactive` flag:
     ```bash
     ./attack-simulator.sh --interactive
     ```
   - To automatically initiate incidents without user prompts, run the script without the `--interactive` flag.

5. **Cleanup**:
   - After running the simulation, the script will prompt you to decide whether to delete the deployed pod. You can choose to clean up or retain the pod for further analysis and investigation.

## How It Works

- **Deploys a web app pod**: The script deploys a web application pod with a unique name, configured to operate for a specific learning period.
- **Verifies readiness**: It checks the readiness of Kubescape's components and ensures runtime detection capabilities are enabled.
- **Initiates predefined security incidents**: The script triggers multiple simulated security incidents, such as unauthorized API access, unexpected process launches, environment variable exposure, and crypto mining domain communication.
- **Verifies detection logs**: After initiating the incidents, the script checks the logs to confirm that Kubescape has accurately detected each incident.
- **Prompts for cleanup**: Finally, it prompts the user to remove the test pod, ensuring a clean environment after the simulation.

---

**Note**: This script is designed for testing and educational purposes within controlled environments.