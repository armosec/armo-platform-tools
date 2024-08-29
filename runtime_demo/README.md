# Attack Simulator README

## Overview

The **Attack Simulator** is a script designed to simulate various security incidents within a Kubernetes environment to test and validate runtime detection capabilities using Kubescape. The script deploys a web application, checks for the readiness of the necessary components, initiates predefined security incidents, and verifies if these incidents are detected correctly.

## Prerequisites

- A Kubernetes cluster with Kubescape installed and configured.
- `kubectl` command-line tool configured to interact with your cluster.
- `jq` installed for JSON parsing.

## Usage Instructions

1. **Run the Script**:
   - Make the script executable:
     ```bash
     chmod +x attack-simulator.sh
     ```
   - Run the script:
     ```bash
     ./attack-simulator.sh
     ```

2. **Initiate Security Incidents**:
   - Automatically initiate incidents with a delay:
     ```bash
     ./attack-simulator.sh --initiate-incident
     ```
   - Or interactively respond to the script prompts to initiate security incidents manually.

3. **Cleanup**: 
   - The script will prompt you to delete the deployed pod after execution. Choose to clean up or retain it for further analysis.

## How It Works

- **Deploys a web app pod** with a unique name.
- **Verifies Kubescape readiness** and its runtime detection capabilities.
- **Initiates multiple security incidents** like unauthorized API access and unexpected process launches.
- **Checks detection logs** to confirm incident detection.
- **Prompts for cleanup** to remove the test pod.

## Troubleshooting

If errors occur, ensure all components are correctly installed and configured. Review the script's output for detailed error messages. For further assistance, consult Kubescape documentation.

---

This script is for testing and educational purposes within controlled environments.