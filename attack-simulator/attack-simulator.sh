#!/bin/bash

#################
# Default values
#################

POD_NAME="ping-app-$(date +%s)"
NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
NAMESPACE=${NAMESPACE:-default}
KUBESCAPE_NAMESPACE="kubescape"
INITIATE_INCIDENTS_ONCE=false
SKIP_PRE_CHECKS=false
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
            echo "🚫 The pod '${POD_NAME}' was not deleted."
        fi
    else
        echo "🛑 Skipping pod deletion since an existing pod '${EXISTING_POD_NAME}' was used."
    fi
    trap - EXIT
}

error_exit() {
    echo "❌ $1" 1>&2
    exit 1
}

kubectl_version_compatibility_check() {
    # Get client and server versions
    versions=$(kubectl version --output json)

    # Extract and format full versions as major.minor (e.g., "1.30")
    client_version=$(echo "$versions" | jq -r '.clientVersion | "\(.major).\(.minor|split("+")[0])"')
    server_version=$(echo "$versions" | jq -r '.serverVersion | "\(.major).\(.minor|split("+")[0])"')

    # Compare versions
    if [[ "$client_version" == "$server_version" || "$client_version" == "1.$(( ${server_version#1.} + 1 ))" || "$server_version" == "1.$(( ${client_version#1.} + 1 ))" ]]; then
        echo "✅ Client and server versions are compatible."
    else
        echo "❌ Client and server versions are NOT compatible."
    fi
}

# Function to print usage
print_usage() {
    echo "Usage: $0 [-n NAMESPACE] [--initiate-incidents-once] [--skip-pre-checks] [--use-existing-pod POD_NAME | --learning-period LEARNING_PERIOD] [-h]"
    echo
    echo "Options:"
    echo "  -n, --namespace NAMESPACE          Specify the namespace for deploying a new pod or locating an existing pod (default: current context namespace or 'default')."
    echo "  --kubescape-namespace              KUBESCAPE_NAMESPACE  Specify the namespace where Kubescape components are deployed (default: 'kubescape')."
    echo "  --initiate-incidents-once          Trigger all security incidents once without prompting."
    echo "  --skip-pre-checks                  Skip pre-checks for readiness and configurations."
    echo "  --use-existing-pod POD_NAME        Use an existing pod instead of deploying a new one."
    echo "  --learning-period LEARNING_PERIOD  Set the learning period duration (default: 3m). Should not be used with --use-existing-pod, as it applies only when creating a new pod."
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
        --initiate-incidents-once)
            INITIATE_INCIDENTS_ONCE=true
            shift
            ;;
        --skip-pre-checks)
            SKIP_PRE_CHECKS=true
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

# Check if the provided namespace exists
if [[ -n "$NAMESPACE" ]]; then
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        error_exit "Namespace '$NAMESPACE' does not exist."
    fi
fi

if [[ ! "$LEARNING_PERIOD" =~ ^[0-9]+[mh]$ ]]; then
    error_exit "Invalid learning period format: '$LEARNING_PERIOD'. It must be a positive integer followed by 'm' for minutes or 'h' for hours (e.g., '5m', '1h')."
fi


##############################################
# Verify Kubescape Runtime Detection is Ready
##############################################

if [[ "$SKIP_PRE_CHECKS" == false ]]; then
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

    echo "🔍 Checking if Runtime Detection is enabled..."
    kubectl get cm node-agent -n "$KUBESCAPE_NAMESPACE" -o jsonpath='{.data.config\.json}' | jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true || error_exit "One or both of 'applicationProfileServiceEnabled' and 'runtimeDetectionEnabled' are not enabled. Exiting."
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

verify_detections() {
    NODE_NAME=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}') || error_exit "Failed to retrieve the node name. Exiting."
    echo "✅ Web app pod '${POD_NAME}' is running on node: ${NODE_NAME} in namespace: ${NAMESPACE}."

    echo "🔍 Finding the node-agent pod running on the same node..."
    NODE_AGENT_POD=$(kubectl get pods -n "$KUBESCAPE_NAMESPACE" -l app=node-agent -o jsonpath="{.items[?(@.spec.nodeName=='${NODE_NAME}')].metadata.name}") || error_exit "Failed to find the node-agent pod. Exiting."
    echo "✅ Node-agent pod identified: ${NODE_AGENT_POD}."

    local detections=("$@") # Accept detections as parameters
    echo "🔍 Fetching logs from node-agent pod..."
    log_output=$(kubectl logs -n "$KUBESCAPE_NAMESPACE" "${NODE_AGENT_POD}") || error_exit "Failed to fetch logs from node-agent pod. Exiting."

    echo "🔍 Verifying all detections in logs..."
    for detection in "${detections[@]}"; do
        if echo "$log_output" | grep -iq "${detection}.*${POD_NAME}"; then
            echo "✅ Detection '${detection}' found for pod '${POD_NAME}'."
        else
            echo "❌ Detection '${detection}' not found for pod '${POD_NAME}'."
        fi
    done
}

##############################
# Initiate Security Incidents
##############################

initiate_security_incidents() {
    echo "🚨 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- ls > /dev/null 2>&1 || error_exit "Failed to list directory contents. Exiting."
    
    echo "🚨 Initiating 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' ('Kubernetes Client Executed' locally) security incidents..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods > /dev/null 2>&1' || error_exit "Failed to initiate 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents. Exiting."
    
    echo "🚨 Initiating 'Soft link created over sensitive file' ('Symlink Created Over Sensitive File' locally) security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'ln -s -f /etc/passwd /tmp/asd > /dev/null 2>&1' || error_exit "Failed to initiate 'Soft link created over sensitive file' incident. Exiting."
    
    echo "🚨 Initiating 'Environment Variables Read from procfs' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'cat /proc/self/environ > /dev/null 2>&1' || error_exit "Failed to initiate 'Environment Variables Read from procfs' incident. Exiting."
    
    echo "🚨 Initiating 'Crypto mining domain communication' security incident..."
    kubectl exec -n "${NAMESPACE}" -t "${POD_NAME}" -- sh -c 'ping -c 1 data.miningpoolstats.stream > /dev/null 2>&1' || error_exit "Failed to initiate 'Crypto mining domain communication' incident. Exiting."
    
    echo "✅ All of the desired incidents detected successfully locally."
}

#######
# Main
#######

# Check for command-line argument or loop for user input
if $INITIATE_INCIDENTS_ONCE; then
    initiate_security_incidents
    sleep 5
    verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"

    echo "✅ Exiting after one-time incident initiation."
else
    while true; do
        read -p "⚠️ Do you want to initiate a security incident? [y/n]: " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            initiate_security_incidents
            sleep 5
            verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            echo "⏭️ Skipping further security incident initiation."
            break
        else
            echo "❌ Invalid input. Please enter 'y' or 'n'."
        fi
    done

    cleanup
fi

echo "✅ Script execution completed successfully."
