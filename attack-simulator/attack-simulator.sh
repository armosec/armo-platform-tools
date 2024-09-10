#!/bin/bash

#################
# Default values
#################

POD_NAME="ping-app-$(date +%s)"
NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
NAMESPACE=${NAMESPACE:-default}
KUBESCAPE_NAMESPACE="kubescape"
MODE="run_all_once" # Default mode
SKIP_PRE_CHECKS=()
VERIFY_DETECTIONS=false
EXISTING_POD_NAME=""
LEARNING_PERIOD="3m"

#######################
# Function Definitions
#######################

cleanup() {
    if [[ -z "$EXISTING_POD_NAME" ]]; then
        # Prompt to delete the ${POD_NAME} pod
        read -p "🗑️ Would you like to delete the pod '${POD_NAME}'? [Y/n] " -r
        REPLY=${REPLY:-Y}
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "🧹 Cleaning up the pod: ${POD_NAME} in namespace: ${NAMESPACE}..."
            kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}"
        else
            echo "⚠️ The pod '${POD_NAME}' was not deleted."
        fi
    else
        echo "⏭️ Skipping pod deletion since an existing pod '${EXISTING_POD_NAME}' was used."
    fi
    trap - EXIT
}

error_exit() {
    echo "😿 $1" 1>&2
    exit 1
}

kubectl_version_compatibility_check() {
    echo "🔍 Verifying compatibility between the kubectl CLI version and the Kubernetes cluster..."
    # Get client and server versions
    versions=$(kubectl version --output json)

    # Extract and format full versions as major.minor (e.g., "1.30")
    client_version=$(echo "$versions" | jq -r '.clientVersion | "\(.major).\(.minor|split("+")[0])"')
    server_version=$(echo "$versions" | jq -r '.serverVersion | "\(.major).\(.minor|split("+")[0])"')

    # Compare versions
    if [[ "$client_version" == "$server_version" || "$client_version" == "1.$(( ${server_version#1.} + 1 ))" || "$server_version" == "1.$(( ${client_version#1.} + 1 ))" ]]; then
        echo "✅ Client '${client_version}' and server '${server_version}' versions are compatible."
    else
        echo "⚠️ Client '${client_version}' and server '${server_version}' versions are NOT compatible."
    fi
}

check_kubescape_components() {
    echo "🔍 Verifying that Kubescape's components are ready..."
    components=(
        storage
        node-agent
        gateway
        operator
        otel-collector
        synchronizer
        kollector
    )
    for component in "${components[@]}"; do
        echo "Checking readiness of $component..."
        kubectl wait -n "$KUBESCAPE_NAMESPACE" --for=condition=ready pod -l app.kubernetes.io/component="$component" --timeout=600s || error_exit "$component is not ready. Exiting."
    done
    echo "✅ All Kubescape's components are ready."
}

# Function to print usage
print_usage() {
    echo "Usage: $0 [-n NAMESPACE] [--kubescape-namespace] [--mode MODE] [--skip-pre-checks CHECK1,CHECK2,... | all] [--verify-detections] [--use-existing-pod POD_NAME | --learning-period LEARNING_PERIOD] [-h]"
    echo
    echo "Options:"
    echo "  -n, --namespace NAMESPACE          Specify the namespace for deploying a new pod or locating an existing pod (default: current context namespace or 'default')."
    echo "  --kubescape-namespace              KUBESCAPE_NAMESPACE  Specify the namespace where Kubescape components are deployed (default: 'kubescape')."
    echo "  --mode                             Set the execution mode. Available modes:"
    echo "                                      - 'interactive': Wait for user input to initiate security incidents."
    echo "                                      - 'investigation': Allows you to run any command and automatically prints local detections triggered by the command."
    echo "                                      - 'run_all_once' (default): Automatically initiates security incidents once and exits."
    echo "  --verify-detections                Run local verification for detections."
    echo "  --use-existing-pod POD_NAME        Use an existing pod instead of deploying a new one."
    echo "  --learning-period LEARNING_PERIOD  Set the learning period duration (default: 3m). Should not be used with --use-existing-pod, as it applies only when creating a new pod."
    echo "  --skip-pre-checks                  Skip specific pre-checks before running the script. Available options:"
    echo "                                      - 'kubectl_installed': Skips checking if 'kubectl' is installed."
    echo "                                      - 'kubectl_version': Skips the check that ensures the 'kubectl' client version is compatible with the Kubernetes cluster, which verifies that the client and server versions are either the same or within one minor version."
    echo "                                      - 'jq_installed': Skips checking if 'jq' is installed."
    echo "                                      - 'kubescape_components': Skips checking if Kubescape components are installed and ready."
    echo "                                      - 'runtime_detection': Skips checking if runtime detection is enabled in Kubescape."
    echo "                                      - 'namespace_existence': Skips checking if the specified namespaces exist."
    echo "                                      - 'all': Skips all of the above pre-checks."
    echo "  -h, --help                         Display this help message and exit."
}

###############################
# Parse command-line arguments
###############################

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --kubescape-namespace)
            KUBESCAPE_NAMESPACE="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --skip-pre-checks)
            IFS=',' read -r -a SKIP_PRE_CHECKS <<< "$2"
            shift 2
            ;;
        --verify-detections)
            VERIFY_DETECTIONS=true
            shift
            ;;
        --use-existing-pod)
            EXISTING_POD_NAME="$2"
            shift 2
            ;;
        --learning-period)
            LEARNING_PERIOD="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            print_usage
            error_exit "Unknown parameter passed: $1"
            ;;
    esac
done

###############################
# Check command-line arguments
###############################

# Check if the learning period format is valid
if [[ ! "$LEARNING_PERIOD" =~ ^[0-9]+[mh]$ ]]; then
    error_exit "Invalid learning period format: '$LEARNING_PERIOD'. It must be a positive integer followed by 'm' for minutes or 'h' for hours (e.g., '5m', '1h')."
fi

#################################################
# Helper function to check if a check is skipped
#################################################

skip_pre_check() {
    local check_name="$1"
    # If "all" is specified in SKIP_PRE_CHECKS, skip all checks
    if [[ " ${SKIP_PRE_CHECKS[@]} " =~ " all " ]]; then
        return 0
    fi
    # Check if the specific check should be skipped
    for check in "${SKIP_PRE_CHECKS[@]}"; do
        if [[ "$check" == "$check_name" ]]; then
            return 0
        fi
    done
    return 1
}

######################################
# Perform pre-checks (if not skipped)
######################################

if ! skip_pre_check "kubectl_installed"; then
    echo "🔍 Verifying that kubectl is installed..."
    command -v kubectl &> /dev/null || error_exit "kubectl is not installed. Please install kubectl to continue. Exiting."
    echo "✅ kubectl is installed."
fi

if ! skip_pre_check "kubectl_version"; then
    kubectl_version_compatibility_check
fi

if ! skip_pre_check "jq_installed"; then
    echo "🔍 Verifying that jq is installed..."
    command -v jq &> /dev/null || error_exit "jq is not installed. Please install jq to continue. Exiting."
    echo "✅ jq is installed."
fi

if ! skip_pre_check "kubescape_components"; then
    check_kubescape_components
fi

if ! skip_pre_check "runtime_detection"; then
    echo "🔍 Checking if Runtime Detection is enabled..."
    kubectl get cm node-agent -n "$KUBESCAPE_NAMESPACE" -o jsonpath='{.data.config\.json}' | jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true &> /dev/null || error_exit "One or both of 'applicationProfileServiceEnabled' and 'runtimeDetectionEnabled' are not enabled. Exiting."
    echo "✅ Runtime Detection is enabled."
fi

if ! skip_pre_check "namespace_existence"; then
    if [[ -n "$NAMESPACE" ]]; then
        if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
            error_exit "Namespace '$NAMESPACE' does not exist."
        fi
    fi

    if [[ -n "$KUBESCAPE_NAMESPACE" ]]; then
        if ! kubectl get namespace "$KUBESCAPE_NAMESPACE" &> /dev/null; then
            error_exit "Kubescape namespace '$KUBESCAPE_NAMESPACE' does not exist."
        fi
    fi
fi

#####################################
# Deploy or Validate Application Pod
#####################################

# Check if the provided pod exists, is ready, and if its application profile exists and is completed
if [[ -n "$EXISTING_POD_NAME" ]]; then
    echo "🔍 Checking if the pod and its application profile are ready..."

    # Check if the pod exists and is ready
    pod_ready_status=$(kubectl get pod -n "$NAMESPACE" "$EXISTING_POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || \
    error_exit "Pod '$EXISTING_POD_NAME' in namespace '$NAMESPACE' does not exist."
    
    if [[ "$pod_ready_status" != "True" ]]; then
        error_exit "Pod '$EXISTING_POD_NAME' in namespace '$NAMESPACE' is not ready."
    fi

    # Check if the application profile exists and is completed
    application_profile_status=$(kubectl get applicationprofiles.spdx.softwarecomposition.kubescape.io "pod-${EXISTING_POD_NAME}" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.kubescape\.io/status}' 2>/dev/null) || \
    error_exit "Application profile for pod '$EXISTING_POD_NAME' in namespace '$NAMESPACE' does not exist."

    if [[ "$application_profile_status" != "completed" ]]; then
        error_exit "Application profile for pod '$EXISTING_POD_NAME' in namespace '$NAMESPACE' is not completed (current status: $application_profile_status)."
    fi

    POD_NAME="$EXISTING_POD_NAME"

    echo "✅ The provided pod and its application profile are ready."
else
    # Trap any EXIT signal and call the cleanup function
    trap cleanup EXIT

    echo "🚀 Deploying the web app with a learning period of ⏰ ${LEARNING_PERIOD}: ${POD_NAME} in namespace: ${NAMESPACE}..."
    sed -e "s/\${POD_NAME}/${POD_NAME}/g" -e "s/\${LEARNING_PERIOD}/${LEARNING_PERIOD}/g" ping-app.yaml | kubectl apply -f - -n "${NAMESPACE}" || error_exit "Failed to apply 'ping-app.yaml'. Exiting."
    echo "⏳ Waiting for the web app pod to be ready in namespace: ${NAMESPACE}..."
    kubectl wait --for=condition=ready pod -l app="${POD_NAME}" -n "${NAMESPACE}" --timeout=600s || error_exit "Web app pod is not ready. Exiting."

    ###################################################
    # Wait for the Application Profile to be Completed
    ###################################################

    echo "⏳ Waiting for the application profile to initialize or be ready..."
    kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=initializing applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" -n "${NAMESPACE}" --timeout=5s || \
    kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=ready applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" -n "${NAMESPACE}" --timeout=300s || \
    error_exit "Application profile is not initializing or ready. Exiting."

    echo "🛠️ Generating activities to populate the application profile..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'cat && curl --help > /dev/null 2>&1 && ping -c 1 1.1.1.1 > /dev/null 2>&1 && ln -s /dev/null /tmp/null_link' || error_exit "Failed to generate activities. Exiting."

    echo "⏳ Waiting for the application profile to be completed..."
    kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=completed applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" -n "${NAMESPACE}" --timeout=600s || error_exit "Application profile is not completed. Exiting."

    sleep 10
fi

############################
# Verify Detections Locally
############################

NODE_NAME=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}') || error_exit "Failed to retrieve the node name. Exiting."
echo "✅ Web app pod '${POD_NAME}' is running on node: ${NODE_NAME} in namespace: ${NAMESPACE}."

echo "🔍 Finding the node-agent pod running on the same node..."
NODE_AGENT_POD=$(kubectl get pods -n "$KUBESCAPE_NAMESPACE" -l app=node-agent -o jsonpath="{.items[?(@.spec.nodeName=='${NODE_NAME}')].metadata.name}") || error_exit "Failed to find the node-agent pod. Exiting."
echo "✅ Node-agent pod identified: ${NODE_AGENT_POD}."

verify_detections() {
    echo "🔍 Running detection verification..."
    
    local detections=("$@") # Accept detections as parameters
    echo "🔍 Fetching logs from node-agent pod..."
    log_output=$(kubectl logs -n "$KUBESCAPE_NAMESPACE" "${NODE_AGENT_POD}") || error_exit "Failed to fetch logs from node-agent pod. Exiting."

    echo "🔍 Verifying all detections in logs..."
    for detection in "${detections[@]}"; do
        if echo "$log_output" | grep -iq "${detection}.*${POD_NAME}" 2>/dev/null; then
            echo "✅ Detection '${detection}' found for pod '${POD_NAME}'."
        else
            echo "⚠️ Detection '${detection}' not found for pod '${POD_NAME}'."
        fi
    done
}

##############################
# Initiate Security Incidents
##############################

initiate_security_incidents() {
    echo "🎯 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- ls > /dev/null 2>&1 || error_exit "Failed to list directory contents. Exiting."
    
    echo "🎯 Initiating 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' ('Kubernetes Client Executed' locally) security incidents..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods > /dev/null 2>&1' || error_exit "Failed to initiate 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents. Exiting."
    
    echo "🎯 Initiating 'Soft link created over sensitive file' ('Symlink Created Over Sensitive File' locally) security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'ln -s -f /etc/passwd /tmp/asd > /dev/null 2>&1' || error_exit "Failed to initiate 'Soft link created over sensitive file' incident. Exiting."
    
    echo "🎯 Initiating 'Environment Variables Read from procfs' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'cat /proc/self/environ > /dev/null 2>&1' || error_exit "Failed to initiate 'Environment Variables Read from procfs' incident. Exiting."
    
    echo "🎯 Initiating 'Crypto mining domain communication' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'ping -c 1 data.miningpoolstats.stream > /dev/null 2>&1' || error_exit "Failed to initiate 'Crypto mining domain communication' incident. Exiting."
    
    echo "✅ All of the desired incidents detected successfully locally."
}

#######
# Main
#######

case $MODE in
    "interactive")
        while true; do
            echo
            read -p "👩‍🔬 Do you want to initiate a security incident? [y/n]: " choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                initiate_security_incidents
                if [[ "$VERIFY_DETECTIONS" == true ]]; then
                    sleep 5
                    verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
                fi
            elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
                echo "⏭️ Skipping further security incident initiation."
                break
            else
                echo "⚠️ Invalid input. Please enter 'y' or 'n'."
            fi
        done
        ;;
    "investigation")
        echo "💻 Run a shell command to check for Armo threat detection:"
        while true; do
            echo
            read -p "$ " choice
            echo $choice
            checkpoint=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c "$choice" || error_exit "Failed to execute the command. Exiting."
            sleep 1.5
            echo "🔍 Checking for threat detections triggered by your command..."
            echo "========================================="
            echo " Detection logged by the node-agent for the executed command"
            echo "========================================="
            node_agent_logs=$(kubectl logs --since-time "${checkpoint}" -n "$KUBESCAPE_NAMESPACE" "${NODE_AGENT_POD}" || error_exit "Failed to fetch logs from node-agent pod. Exiting." 2>/dev/null)
            # Check if logs are empty
            if [[ -z "$node_agent_logs" ]]; then
                echo "⚠️ No threats found for the executed command."
            else
                echo "$node_agent_logs"
                echo "✅ Command executed and detection logs retrieved."
            fi

            echo "========================================="
            echo " Synchronizer activities logged for the executed command"
            echo "========================================="
            synchronizer_logs=$(kubectl logs --since-time "${checkpoint}" -n "$KUBESCAPE_NAMESPACE" "deployment.apps/synchronizer" || error_exit "Failed to fetch logs from node-agent pod. Exiting." 2>/dev/null)
            # Check if logs are empty
            if [[ -z "$synchronizer_logs" ]]; then
                echo "⚠️ No threats found for the executed command."
            else
                echo "$synchronizer_logs"
                echo "✅ Command executed and synchronizer logs retrieved."
            fi
        done
        ;;
    "run_all_once" | *)
        initiate_security_incidents
        if [[ "$VERIFY_DETECTIONS" == true ]]; then
            sleep 5
            verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
        fi
        echo "✅ Exiting after one-time incident initiation."
        ;;
esac

cleanup
echo "✅ Script execution completed successfully."