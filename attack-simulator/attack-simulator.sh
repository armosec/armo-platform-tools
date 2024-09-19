#!/bin/bash

#################
# Default values
#################

APP_NAME="simulation-app-$(date +%s)"
NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
NAMESPACE=${NAMESPACE:-default}
KUBESCAPE_NAMESPACE="kubescape"
MODE="run_all_once" # Default mode
SKIP_PRE_CHECKS=()
VERIFY_DETECTIONS=false
EXISTING_POD_NAME=""
LEARNING_PERIOD="3m"
APP_YAML_PATH="ping-app.yaml"
PRE_RUN_SCRIPT=""
ATTACK_SCRIPT=""

KUBESCAPE_READINESS_TIMEOUT=10s
APP_CREATION_TIMEOUT=60s
APP_PROFILE_CREATION_TIMEOUT=10s
APP_PROFILE_READINESS_TIMEOUT=300s
APP_PROFILE_COMPLETION_TIMEOUT=600s
VERIFY_DETECTIONS_DELAY=10s

#######################
# Function Definitions
#######################

cleanup() {
    if [[ -z "${EXISTING_POD_NAME}" ]]; then
        # Prompt to delete the deployed application
        read -p "🗑️ Would you like to delete the deployed application? [Y/n] " -r
        REPLY=${REPLY:-Y}
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "🧹 Cleaning up '${APP_YAML_PATH}' in namespace: '${NAMESPACE}'..."
            sed -e "s/\${APP_NAME}/${APP_NAME}/g" -e "s/\${LEARNING_PERIOD}/${LEARNING_PERIOD}/g" "${APP_YAML_PATH}" | kubectl delete -n "${NAMESPACE}" -f - &> /dev/null || echo "⚠️ Failed to delete '${APP_YAML_PATH}'."
            echo "✅ '${APP_NAME}' was deleted successfully."
        else
            echo "✅ '${APP_NAME}' was not deleted."
        fi
    else
        echo "⏭️ Skipping application deletion since an existing pod '${EXISTING_POD_NAME}' was used."
    fi
    trap - EXIT
}

error_exit() {
    echo "😿 $1" 1>&2
    exit 1
}

kubectl_version_compatibility_check() {
    echo "🔍 Verifying compatibility between the kubectl CLI and Kubernetes cluster versions..."
    # Get client and server versions
    versions=$(kubectl version --output json)

    # Extract and format full versions as major.minor (e.g., "1.30")
    client_version=$(echo "${versions}" | jq -r '.clientVersion | "\(.major).\(.minor|split("+")[0])"')
    server_version=$(echo "${versions}" | jq -r '.serverVersion | "\(.major).\(.minor|split("+")[0])"')

    # Compare versions
    if [[ "${client_version}" == "${server_version}" || "${client_version}" == "1.$(( ${server_version#1.} + 1 ))" || "${server_version}" == "1.$(( ${client_version#1.} + 1 ))" ]]; then
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
        kubectl wait -n "${KUBESCAPE_NAMESPACE}" --for=condition=ready pod -l app.kubernetes.io/component="${component}" --timeout="${KUBESCAPE_READINESS_TIMEOUT}" > /dev/null || error_exit "'${component}' is not ready. Exiting."
    done
    echo "✅ All Kubescape's components are ready."
}

# Function to print usage
print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Main Options:"
    echo "  -n, --namespace NAMESPACE               Specify the namespace for deploying a new application or locating an existing pod (default: current context namespace or 'default')."
    echo "  --mode MODE                             Set the execution mode. Available modes:"
    echo "                                          - 'interactive': Wait for user input to initiate security incidents."
    echo "                                          - 'investigation': Allows you to run any command and automatically prints local detections triggered by the command."
    echo "                                          - 'run_all_once' (default): Automatically initiates security incidents once and exits."
    echo "  --verify-detections                     Run local verification for detections."
    echo "  --use-existing-pod POD_NAME             Use an existing pod instead of deploying a new one."
    echo "  --app-yaml-path PATH                    Specify the path to the application YAML file to deploy. Default is 'ping-app.yaml'."
    echo "  --pre-run-script PATH                   Specify a shell script to run during the pre-run activities."
    echo "  --attack-script PATH                    Specify a shell script to run instead of the default attack activities."
    echo
    echo "Additional Options:"
    echo "  --kubescape-namespace KUBESCAPE_NAMESPACE Specify the namespace where Kubescape components are deployed (default: 'kubescape')."
    echo "  --learning-period LEARNING_PERIOD       Set the learning period duration (default: 3m). Should not be used with --use-existing-pod."
    echo "  --skip-pre-checks CHECK1,CHECK2,...     Skip specific pre-checks before running the script. Available options: 'kubectl_installed', 'kubectl_version', 'jq_installed', 'kubescape_components', 'runtime_detection', 'namespace_existence', 'all'."
    echo "  --verify-detections-delay DELAY         Set the delay before verifying detections (default: 10s)."
    echo "  --kubescape-readiness-timeout TIMEOUT   Set the timeout for checking Kubescape components readiness (default: 10s)."
    echo "  --app-creation-timeout TIMEOUT          Set the timeout for application's pod creation (default: 60s)."
    echo "  --app-profile-creation-timeout TIMEOUT  Set the timeout for application profile creation (default: 10s)."
    echo "  --app-profile-readiness-timeout TIMEOUT Set the timeout for application profile readiness (default: 300s)."
    echo "  --app-profile-completion-timeout TIMEOUT Set the timeout for application profile completion (default: 600s)."
    echo "  -h, --help                              Display this help message and exit."
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
            APP_POD_NAME="$2"
            EXISTING_POD_NAME="$2"
            shift 2
            ;;
        --learning-period)
            LEARNING_PERIOD="$2"
            shift 2
            ;;
        --app-yaml-path)
            APP_YAML_PATH="$2"
            shift 2
            ;;
        --pre-run-script)
            PRE_RUN_SCRIPT="$2"
            shift 2
            ;;
        --attack-script)
            ATTACK_SCRIPT="$2"
            shift 2
            ;;
        --kubescape-readiness-timeout)
            KUBESCAPE_READINESS_TIMEOUT="$2"
            shift 2
            ;;
        --app-creation-timeout)
            APP_CREATION_TIMEOUT="$2"
            shift 2
            ;;
        --app-profile-creation-timeout)
            APP_PROFILE_CREATION_TIMEOUT="$2"
            shift 2
            ;;
        --app-profile-readiness-timeout)
            APP_PROFILE_READINESS_TIMEOUT="$2"
            shift 2
            ;;
        --app-profile-completion-timeout)
            APP_PROFILE_COMPLETION_TIMEOUT="$2"
            shift 2
            ;;
        --verify-detections-delay)
            VERIFY_DETECTIONS_DELAY="$2"
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

##############################
# Post-Argument parsing steps
##############################

check_time_format() {
    local name="$1"
    local expected_format="$2"
    local value="${!name}"  # Indirect reference to get the value of the variable

    [[ "${value}" =~ ^[0-9]+["${expected_format}"]$ ]] || error_exit "Invalid time format '${value}' for '${name}': must be a positive integer followed by '${expected_format}' (e.g., '10${expected_format:0:1}')."
}

check_time_format "KUBESCAPE_READINESS_TIMEOUT" "s"
check_time_format "APP_CREATION_TIMEOUT" "s"
check_time_format "APP_PROFILE_CREATION_TIMEOUT" "s"
check_time_format "APP_PROFILE_READINESS_TIMEOUT" "s"
check_time_format "APP_PROFILE_COMPLETION_TIMEOUT" "s"
check_time_format "LEARNING_PERIOD" "mh"
check_time_format "VERIFY_DETECTIONS_DELAY" "s"

# Validate that the simulation-app.yaml file exists
if [[ ! -f "${APP_YAML_PATH}" ]]; then
    error_exit "The provided application YAML file '${APP_YAML_PATH}' does not exist."
fi

# Check that the file contains both placeholders \${APP_NAME} and \${LEARNING_PERIOD}
if ! grep -q '\${APP_NAME}' "${APP_YAML_PATH}" || ! grep -q '\${LEARNING_PERIOD}' "${APP_YAML_PATH}"; then
    error_exit "The provided application YAML file '${APP_YAML_PATH}' must contain both placeholders '\${APP_NAME}' and '\${LEARNING_PERIOD}'."
fi

# Check if the pre-run script exists
if [[ -n "${PRE_RUN_SCRIPT}" ]]; then
    if [[ ! -f "${PRE_RUN_SCRIPT}" ]]; then
        error_exit "The provided pre-run script '${PRE_RUN_SCRIPT}' does not exist."
    fi
fi

# Check if the attack script exists
if [[ -n "${ATTACK_SCRIPT}" ]]; then
    if [[ ! -f "${ATTACK_SCRIPT}" ]]; then
        error_exit "The provided attack script '${ATTACK_SCRIPT}' does not exist."
    fi
fi

# Set Application Profile's default values
APP_PROFILE_API="applicationprofiles.spdx.softwarecomposition.kubescape.io"
STATUS_JSONPATH='{.metadata.annotations.kubescape\.io/status}'

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
        if [[ "${check}" == "${check_name}" ]]; then
            return 0
        fi
    done
    return 1
}

######################################
# Perform pre-checks (if not skipped)
######################################

if ! skip_pre_check "kubectl_installed"; then
    echo "🔍 Verifying that 'kubectl' is installed..."
    command -v kubectl &> /dev/null || error_exit "kubectl is not installed. Please install kubectl to continue. Exiting."
    echo "✅ 'kubectl' is installed."
fi

if ! skip_pre_check "jq_installed"; then
    echo "🔍 Verifying that 'jq' is installed..."
    command -v jq &> /dev/null || error_exit "jq is not installed. Please install jq to continue. Exiting."
    echo "✅ 'jq' is installed."
fi

if ! skip_pre_check "kubectl_version"; then
    kubectl_version_compatibility_check
fi

if ! skip_pre_check "kubescape_components"; then
    check_kubescape_components
fi

if ! skip_pre_check "runtime_detection"; then
    echo "🔍 Checking if Runtime Detection is enabled..."
    kubectl get cm node-agent -n "${KUBESCAPE_NAMESPACE}" -o jsonpath='{.data.config\.json}' | jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true &> /dev/null || error_exit "One or both of 'applicationProfileServiceEnabled' and 'runtimeDetectionEnabled' are not enabled. Exiting."
    echo "✅ Runtime Detection is enabled."
fi

if ! skip_pre_check "namespace_existence"; then
    if [[ -n "${NAMESPACE}" ]]; then
        if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
            error_exit "Namespace '${NAMESPACE}' does not exist."
        fi
    fi

    if [[ -n "${KUBESCAPE_NAMESPACE}" ]]; then
        if ! kubectl get namespace "${KUBESCAPE_NAMESPACE}" &> /dev/null; then
            error_exit "Kubescape namespace '${KUBESCAPE_NAMESPACE}' does not exist."
        fi
    fi
fi

#####################################
# Deploy or Validate Application Pod
#####################################

# Check if the provided pod exists, is ready, and if its application profile exists and is completed
if [[ -n "${EXISTING_POD_NAME}" ]]; then
    echo "🔍 Checking if the pod and its application profile are ready..."

    # Check if the pod exists and is ready
    pod_ready_status=$(kubectl get pod -n "${NAMESPACE}" "${EXISTING_POD_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || \
    error_exit "Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' does not exist."
    echo "✅ Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' exists."
    
    if [[ "${pod_ready_status}" != "True" ]]; then
        error_exit "Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' is not ready."
    fi

    APP_NAME=$(kubectl get pod -n "${NAMESPACE}" "${EXISTING_POD_NAME}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null) || \
    error_exit "Failed to retrieve the app name for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}'."
    echo "✅ Application name '${APP_NAME}' retrieved successfully."

    # Check if the application profile exists and is completed
    APP_PROFILE_NAME=$(kubectl get "${APP_PROFILE_API}" -n "${NAMESPACE}" -o json | jq -r --arg APP_NAME "${APP_NAME}" '.items[] | select(.metadata.labels["kubescape.io/workload-name"]==$APP_NAME) | .metadata.name') || \
    error_exit "Failed to retrieve the application profile name for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}'."
    echo "✅ Application profile '${APP_PROFILE_NAME}' exists."
    
    application_profile_status=$(kubectl get "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" -o jsonpath="${STATUS_JSONPATH}" 2>/dev/null) || \
    error_exit "Application profile for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' does not exist."

    if [[ "${application_profile_status}" != "completed" ]]; then
        error_exit "Application profile for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' is not completed (current status: '${application_profile_status}')."
    fi

    echo "✅ The provided pod and its application profile are ready."
else
    # Trap any EXIT signal and call the cleanup function
    trap cleanup EXIT

    echo "🚀 Deploying the application: '${APP_NAME}' in namespace: '${NAMESPACE}' with a learning period of ⏰ '${LEARNING_PERIOD}'..."
    sed -e "s/\${APP_NAME}/${APP_NAME}/g" -e "s/\${LEARNING_PERIOD}/${LEARNING_PERIOD}/g" "${APP_YAML_PATH}" | kubectl apply -n "${NAMESPACE}" -f - &> /dev/null || error_exit "Failed to apply '${APP_YAML_PATH}'. Exiting."
    
    echo "⏳ Waiting for application's pod to be created..."
    APP_POD_NAME=""
    SECONDS=0 # Initialize the SECONDS counter
    while [[ -z "${APP_POD_NAME}" ]]; do
        if (( SECONDS >= ${APP_CREATION_TIMEOUT%s} )); then
            error_exit "Timed out after ${APP_CREATION_TIMEOUT} seconds waiting for application's pod to be created."
        fi
        APP_POD_NAME=$(kubectl get pod -l app="${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2> /dev/null)
        sleep 1
    done
    echo "✅ Application's pod '${APP_POD_NAME}' created successfully!"
    
    echo "⏳ Waiting for the application's pod to be ready..."
    kubectl wait --for=condition=ready pod "${APP_POD_NAME}" -n "${NAMESPACE}" --timeout="${APP_CREATION_TIMEOUT}" &> /dev/null || error_exit "'${APP_POD_NAME}' pod is not ready. Exiting."
    echo "✅ Application's pod is ready!" 

    ###################################################
    # Wait for the Application Profile to be Completed
    ###################################################

    echo "⏳ Waiting for application profile to be created..."
    APP_PROFILE_NAME=""
    SECONDS=0  # Initialize the SECONDS counter
    while [[ -z "${APP_PROFILE_NAME}" ]]; do
        if (( SECONDS >= ${APP_PROFILE_CREATION_TIMEOUT%s} )); then
            error_exit "Timed out after ${APP_PROFILE_CREATION_TIMEOUT} seconds waiting for application profile creation."
        fi
        APP_PROFILE_NAME=$(kubectl get "${APP_PROFILE_API}" -n "${NAMESPACE}" -o json 2> /dev/null | jq -r --arg APP_NAME "${APP_NAME}" '.items[] | select(.metadata.labels["kubescape.io/workload-name"]==$APP_NAME) | .metadata.name')
        sleep 1
    done
    echo "✅ Application profile '${APP_PROFILE_NAME}' in namespace '${NAMESPACE}' created successfully!"

    echo "⏳ Waiting for the application profile to be ready..."
    kubectl wait --for=jsonpath="${STATUS_JSONPATH}"=ready "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" --timeout="${APP_PROFILE_READINESS_TIMEOUT}" &> /dev/null || \
    error_exit "Application profile is not ready after '${APP_PROFILE_READINESS_TIMEOUT}' timeout. Exiting."

    # Generate activities to populate the application profile
    if [[ -n "${PRE_RUN_SCRIPT}" ]]; then
        echo "🛠️ Copying pre-run script '${PRE_RUN_SCRIPT}' to the pod and executing it..."
        kubectl cp "${PRE_RUN_SCRIPT}" "${NAMESPACE}/${APP_POD_NAME}:/tmp/pre-run-script.sh" || error_exit "Failed to copy pre-run script to the pod."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'chmod +x /tmp/pre-run-script.sh && nohup /tmp/pre-run-script.sh > /dev/null 2>&1 &' && \
        echo "✅ Pre-run script executed successfully." || error_exit "Failed to execute pre-run script on the pod."
    else
        echo "🛠️ Generating default activities to populate the application profile..."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c '
        {
            cat &&
            curl --help &&
            ping -c 1 1.1.1.1 &&
            ln -sf /dev/null /tmp/null_link
        } > /dev/null 2>&1' > /dev/null 2>&1 && echo "✅ Pre-run activities completed successfully." || \
        echo "⚠️ One or more pre-run activities failed."
    fi

    echo "⏳ Waiting for the application profile to be completed..."
    kubectl wait --for=jsonpath="${STATUS_JSONPATH}"=completed "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" --timeout="${APP_PROFILE_COMPLETION_TIMEOUT}" &> /dev/null || error_exit "Application profile is not completed after '${APP_PROFILE_COMPLETION_TIMEOUT}' timeout. Exiting."
    echo "✅ Application profile is completed!"

    sleep 10
fi

############################
# Verify Detections Locally
############################

NODE_NAME=$(kubectl get pod "${APP_POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}') || error_exit "Failed to retrieve the node name. Exiting."
echo "✅ Pod '${APP_POD_NAME}' is running on node: '${NODE_NAME}'."

NODE_AGENT_POD=$(kubectl get pod -n "${KUBESCAPE_NAMESPACE}" -l app=node-agent -o jsonpath="{.items[?(@.spec.nodeName=='${NODE_NAME}')].metadata.name}") || error_exit "Failed to find the node-agent pod. Exiting."
echo "✅ Node-agent pod identified: '${NODE_AGENT_POD}'."

verify_detections() {
    echo "🔍 Running detection verification..."

    local detections=("$@") # Accept detections as parameters
    echo "🔍 Fetching logs from node-agent pod..."
    log_output=$(kubectl logs -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}") || error_exit "Failed to fetch logs from node-agent pod. Exiting."

    echo "🔍 Verifying all detections in logs..."
    for detection in "${detections[@]}"; do
        if echo "${log_output}" | grep -iq "${detection}.*${APP_POD_NAME}" 2>/dev/null; then
            echo "✅ Detection '${detection}' found."
        else
            echo "⚠️ Detection '${detection}' not found."
        fi
    done
}

##############################
# Initiate Security Incidents
##############################

initiate_security_incidents() {
    echo "🎯 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'ls > /dev/null 2>&1' > /dev/null 2>&1 || echo "⚠️ Failed to list directory contents. Exiting."
    
    echo "🎯 Initiating 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' ('Kubernetes Client Executed' locally) security incidents..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods > /dev/null 2>&1' > /dev/null 2>&1 || echo "⚠️ Failed to initiate 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents. Exiting."
    
    echo "🎯 Initiating 'Soft link created over sensitive file' ('Symlink Created Over Sensitive File' locally) security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'ln -sf /etc/passwd /tmp/asd > /dev/null 2>&1' > /dev/null 2>&1 || echo "⚠️ Failed to initiate 'Soft link created over sensitive file' incident. Exiting."
    
    echo "🎯 Initiating 'Environment Variables Read from procfs' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'cat /proc/self/environ > /dev/null 2>&1' > /dev/null 2>&1 || echo "⚠️ Failed to initiate 'Environment Variables Read from procfs' incident. Exiting."
    
    echo "🎯 Initiating 'Crypto mining domain communication' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'ping -c 1 data.miningpoolstats.stream > /dev/null 2>&1' > /dev/null 2>&1 || echo "⚠️ Failed to initiate 'Crypto mining domain communication' incident. Exiting."
    
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
            if [[ "${choice}" == "y" || "${choice}" == "Y" ]]; then
                if [[ -n "${ATTACK_SCRIPT}" ]]; then
                    echo "🛠️ Copying attack script '${ATTACK_SCRIPT}' to the pod and executing it..."
                    CHECKPOINT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                    kubectl cp "${ATTACK_SCRIPT}" "${NAMESPACE}/${APP_POD_NAME}:/tmp/attack-script.sh" || error_exit "Failed to copy attack script to the pod."
                    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'chmod +x /tmp/attack-script.sh && nohup /tmp/attack-script.sh > /dev/null 2>&1 &' && \
                    echo "✅ Attack script executed successfully." || error_exit "Failed to execute attack script on the pod."
                    if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                        echo "📝 Logging new events after checkpoint '${CHECKPOINT}' and filtering by app name '${APP_NAME}'..."
                        kubectl logs --since-time "${CHECKPOINT}" -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}" -f | grep "${APP_NAME}" || error_exit "Failed to fetch logs from node-agent pod. Exiting."
                    fi
                else
                    initiate_security_incidents
                    if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                        sleep ${VERIFY_DETECTIONS_DELAY%s}
                        verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
                    fi
                fi
            elif [[ "${choice}" == "n" || "${choice}" == "N" ]]; then
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
            echo ${choice}
            checkpoint=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c "${choice}" && echo "✅ Command executed successfully. Waiting for detections" && sleep ${VERIFY_DETECTIONS_DELAY%s} || \
            echo "⚠️ Failed to execute the command."
            echo "🔍 Checking for threat detections triggered by your command..."
            echo "============================================================="
            echo " Detection logged by the node-agent for the executed command"
            echo "============================================================="
            node_agent_logs=$(kubectl logs --since-time "${checkpoint}" -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}" || error_exit "Failed to fetch logs from node-agent pod. Exiting." 2>/dev/null)
            # Check if logs are empty
            if [[ -z "${node_agent_logs}" ]]; then
                echo "⚠️ No threats found for the executed command."
            else
                echo "${node_agent_logs}"
                echo "✅ Command executed and detection logs retrieved."
            fi

            echo "========================================================="
            echo " Synchronizer activities logged for the executed command"
            echo "========================================================="
            synchronizer_logs=$(kubectl logs --since-time "${checkpoint}" -n "${KUBESCAPE_NAMESPACE}" "deployment.apps/synchronizer" || error_exit "Failed to fetch logs from node-agent pod. Exiting." 2>/dev/null)
            # Check if logs are empty
            if [[ -z "${synchronizer_logs}" ]]; then
                echo "⚠️ No updates sent to Armo by the synchronizer for the executed command."
            else
                echo "${synchronizer_logs}"
                echo "✅ Command executed and synchronizer logs retrieved."
            fi
        done
        ;;
    "run_all_once" | *)
        if [[ -n "${ATTACK_SCRIPT}" ]]; then
            echo "🛠️ Copying attack script '${ATTACK_SCRIPT}' to the pod and executing it..."
            CHECKPOINT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            kubectl cp "${ATTACK_SCRIPT}" "${NAMESPACE}/${APP_POD_NAME}:/tmp/attack-script.sh" || error_exit "Failed to copy attack script to the pod."
            kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'chmod +x /tmp/attack-script.sh && nohup /tmp/attack-script.sh > /dev/null 2>&1 &' && \
            echo "✅ Attack script executed successfully." || error_exit "Failed to execute attack script on the pod."
            if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                echo "📝 Logging new events after checkpoint '${CHECKPOINT}' and filtering by app name '${APP_NAME}'..."
                kubectl logs --since-time "${CHECKPOINT}" -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}" -f | grep "${APP_NAME}" || error_exit "Failed to fetch logs from node-agent pod. Exiting."
            fi
        else
            initiate_security_incidents
            if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                sleep ${VERIFY_DETECTIONS_DELAY%s}
                verify_detections "Unexpected process launched" "Unexpected service account token access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
            fi
            echo "✅ Exiting after one-time incident initiation."
        fi
        ;;
esac

cleanup
echo "✅ Script execution completed successfully."
