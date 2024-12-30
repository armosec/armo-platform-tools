#!/bin/bash

#########
# values
#########

# Default values (Overridable)
NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
NAMESPACE=${NAMESPACE:-default}
KUBESCAPE_NAMESPACE="kubescape"
MODE="run_all_once" # Default mode
SKIP_PRE_CHECKS=()
VERIFY_DETECTIONS=false
EXISTING_POD_NAME=""
LEARNING_PERIOD="3m"
APP_YAML_PATH="ping-app.yaml"
KEEP_LOGS=false
KEEP_APP=false
DEBUG_MODE=false

PRE_RUN_SCRIPT=""
ATTACK_SCRIPT=""
ATTACK_DURATION="10s"

KUBESCAPE_READINESS_TIMEOUT=10s
APP_CREATION_TIMEOUT=60s
APP_PROFILE_CREATION_TIMEOUT=10s
APP_PROFILE_READINESS_TIMEOUT=300s
APP_PROFILE_COMPLETION_TIMEOUT=600s
VERIFY_DETECTIONS_DELAY=30s
POST_APP_PROFILE_COMPLETION_DELAY=30s

# Constants (Non-Overridable)
APP_PROFILE_API="applicationprofiles.spdx.softwarecomposition.kubescape.io"
STATUS_JSONPATH='{.metadata.annotations.kubescape\.io/status}'

# Runtime Variables (Initialized During Execution)
APP_NAME="simulation-app-$(date +%s)"
PRE_RUN_PID=""
LOG_FILES=()

#######################
# Function Definitions
#######################

# Centralized logging function
log() {
    local level="$1"
    shift
    local message="$*"
    case "$level" in
        INFO)
            echo "$message"
            ;;
        DEBUG)
            if [ "$DEBUG_MODE" = true ]; then
                echo "$message"
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
}

cleanup() {
    local app_deleted=false

    # Cleanup the deployed application if necessary
    if [[ -z "${EXISTING_POD_NAME}" ]]; then
        if [[ "$KEEP_APP" == false ]]; then
            log "INFO" "🧹 Cleaning up '${APP_YAML_PATH}' in namespace: '${NAMESPACE}'..."
            sed -e "s/\${APP_NAME}/${APP_NAME}/g" -e "s/\${LEARNING_PERIOD}/${LEARNING_PERIOD}/g" "${APP_YAML_PATH}" | \
                kubectl delete -n "${NAMESPACE}" -f - &> /dev/null || \
                log "INFO" "⚠️ Failed to delete '${APP_YAML_PATH}'."
            log "INFO" "✅ '${APP_NAME}' was deleted successfully. This can be configured using the '--keep-app' argument."
            app_deleted=true
        else
            log "INFO" "⏭️ Skipping deletion of the deployed application. Pod name: '${APP_POD_NAME}'."
        fi
    fi

    if [[ "$app_deleted" = false && -n "${PRE_RUN_PID}" ]]; then
        log "INFO" "🧹 Cleaning up pre-run script resources..."
        PRE_RUN_CHILD_PIDs=$(kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- pgrep --parent "${PRE_RUN_PID}" 2> /dev/null)
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- kill -9 "${PRE_RUN_PID}" "${PRE_RUN_CHILD_PIDs}" &> /dev/null || \
            log "INFO" "⚠️ Failed to stop pre-run script process."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- rm -f /tmp/pre-run-script.sh &> /dev/null || \
            log "INFO" "⚠️ Failed to remove pre-run script."
        log "INFO" "✅ Pre-run script resources cleaned up successfully."
    fi

    if [[ ${#LOG_FILES[@]} -gt 0 ]]; then
        log "INFO" "🧹 These log files were generated:"
        for log_file in "${LOG_FILES[@]}"; do
            log "INFO" " - ${log_file}"
        done

        if [[ "$KEEP_LOGS" == false ]]; then
            for log_file in "${LOG_FILES[@]}"; do
                rm -f "${log_file}" || log "INFO" "⚠️ Failed to remove: ${log_file}"
            done
            log "INFO" "✅ All log files removed. This can be configured using the '--keep-logs' argument."
        else
            log "INFO" "⚠️ Log files were kept as per the '--keep-logs' argument."
        fi
    fi

    # Reset trap and exit
    trap - EXIT
    log "INFO" "✅ Cleanup completed."
    log "INFO" "✅ Script execution completed successfully."

    exit 0
}

error_exit() {
    log "ERROR" "😿 $1" 1>&2
    exit 1
}

kubectl_version_compatibility_check() {
    log "DEBUG" "🔍 Verifying compatibility between the kubectl CLI and Kubernetes cluster versions..."
    # Get client and server versions
    versions=$(kubectl version --output json)

    # Extract and format full versions as major.minor (e.g., "1.30")
    client_version=$(echo "${versions}" | jq -r '.clientVersion | "\(.major).\(.minor|split("+")[0])"')
    server_version=$(echo "${versions}" | jq -r '.serverVersion | "\(.major).\(.minor|split("+")[0])"')

    # Compare versions
    if [[ "${client_version}" == "${server_version}" || \
        "${client_version}" == "1.$(( ${server_version#1.} + 1 ))" || \
        "${server_version}" == "1.$(( ${client_version#1.} + 1 ))" ]]; then
        log "DEBUG" "✅ Client '${client_version}' and server '${server_version}' versions are compatible."
    else
        log "DEBUG" "⚠️ Client '${client_version}' and server '${server_version}' versions are NOT compatible."
    fi
}

check_kubescape_components() {
    log "DEBUG" "🔍 Verifying that Kubescape's components are ready..."
    components=(
        storage
        node-agent
        gateway
        operator
        otel-collector
        synchronizer
    )
    for component in "${components[@]}"; do
        kubectl wait -n "${KUBESCAPE_NAMESPACE}" --for=condition=ready pod -l app.kubernetes.io/component="${component}" \
            --timeout="${KUBESCAPE_READINESS_TIMEOUT}" > /dev/null || \
            error_exit "'${component}' is not ready. Exiting."
    done
    log "DEBUG" "✅ All Kubescape's components are ready."
}

# Function to print usage
print_usage() {
    log "INFO" "Usage: $0 [OPTIONS]"
    log "INFO" ""
    log "INFO" "Main Options:"
    log "INFO" "  -n, --namespace NAMESPACE               Specify the namespace for deploying or locating a pod (default: current context or ‘default’ namespace)."
    log "INFO" "  --use-existing-pod POD_NAME             Use an existing pod instead of deploying a new one."
    log "INFO" "  --verify-detections                     Run local verification for detections."
    log "INFO" ""
    log "INFO" "Advance Options:"
    log "INFO" "  --pre-run-script PATH                   Specify a shell script to run during the pre-run activities."
    log "INFO" "  --attack-script PATH                    Specify a shell script to run instead of the default attack activities."
    log "INFO" "  --attack-duration DURATION              Specify the duration to run the attack script (default: '10s')."
    log "INFO" "  --app-yaml-path PATH                    Specify the path to the application YAML file to deploy. Default is 'ping-app.yaml'."
    log "INFO" "  --mode MODE                             Set the execution mode. Available modes:"
    log "INFO" "                                          - 'interactive': Wait for user input to initiate security incidents."
    log "INFO" "                                          - 'investigation': Allows you to run any command and automatically prints local detections triggered by the command."
    log "INFO" "                                          - 'run_all_once' (default): Automatically initiates security incidents once and exits."
    log "INFO" "  --learning-period LEARNING_PERIOD       Set the learning period duration (default: 3m). Should not be used with --use-existing-pod."
    log "INFO" "  --kubescape-namespace KUBESCAPE_NAMESPACE Specify the namespace where Kubescape components are deployed (default: 'kubescape')."
    log "INFO" "  --skip-pre-checks CHECK1,CHECK2,...     Skip specific pre-checks before running the script. Options:"
    log "INFO" "                                          kubectl_installed, kubectl_version, jq_installed, kubescape_components, runtime_detection, namespace_existence, all."
    log "INFO" "  --kubescape-readiness-timeout TIMEOUT   Set the timeout for checking Kubescape components readiness (default: 10s)."
    log "INFO" "  --app-creation-timeout TIMEOUT          Set the timeout for application's pod creation (default: 60s)."
    log "INFO" "  --app-profile-creation-timeout TIMEOUT  Set the timeout for application profile creation (default: 10s)."
    log "INFO" "  --app-profile-readiness-timeout TIMEOUT Set the timeout for application profile readiness (default: 300s)."
    log "INFO" "  --app-profile-completion-timeout TIMEOUT Set the timeout for application profile completion (default: 600s)."
    log "INFO" "  --verify-detections-delay DELAY         Set the delay before verifying detections (default: 5s)."
    log "INFO" "  --post-app-profile-completion-delay DELAY Set the delay after application profile completion (default: 30s)."
    log "INFO" "  --keep-logs                             Keep log files generated during script execution. By default, logs are deleted."
    log "INFO" "  --keep-app                              Keep the deployed application after the script finishes. By default, the application is deleted."
    log "INFO" "  --debug                                 Enable debug mode for detailed logging."
    log "INFO" "  -h, --help                              Display this help message and exit."
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
        --attack-duration)
            ATTACK_DURATION="$2"
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
        --post-app-profile-completion-delay)
            POST_APP_PROFILE_COMPLETION_DELAY="$2"
            shift 2
            ;;
        --keep-logs)
            KEEP_LOGS=true
            shift
            ;;
        --keep-app)
            KEEP_APP=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
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

    [[ "${value}" =~ ^[0-9]+["${expected_format}"]$ ]] || \
        error_exit "Invalid time format '${value}' for '${name}': must be a positive integer followed by '${expected_format}' (e.g., '10${expected_format:0:1}')."
}

check_time_format "KUBESCAPE_READINESS_TIMEOUT" "s"
check_time_format "APP_CREATION_TIMEOUT" "s"
check_time_format "APP_PROFILE_CREATION_TIMEOUT" "s"
check_time_format "APP_PROFILE_READINESS_TIMEOUT" "s"
check_time_format "APP_PROFILE_COMPLETION_TIMEOUT" "s"
check_time_format "LEARNING_PERIOD" "mh"
check_time_format "VERIFY_DETECTIONS_DELAY" "s"
check_time_format "POST_APP_PROFILE_COMPLETION_DELAY" "s"
check_time_format "ATTACK_DURATION" "s"

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

if [[ "$DEBUG_MODE" = false ]]; then
    log "INFO" "🔍 Verifying prerequisites..."
fi

if ! skip_pre_check "kubectl_installed"; then
    log "DEBUG" "🔍 Verifying that 'kubectl' is installed..."
    command -v kubectl &> /dev/null || error_exit "kubectl is not installed. Please install kubectl to continue. Exiting."
    log "DEBUG" "✅ 'kubectl' is installed."
fi

if ! skip_pre_check "jq_installed"; then
    log "DEBUG" "🔍 Verifying that 'jq' is installed..."
    command -v jq &> /dev/null || error_exit "jq is not installed. Please install jq to continue. Exiting."
    log "DEBUG" "✅ 'jq' is installed."
fi

if ! skip_pre_check "kubectl_version"; then
    kubectl_version_compatibility_check
fi

if ! skip_pre_check "kubescape_components"; then
    check_kubescape_components
fi

if ! skip_pre_check "runtime_detection"; then
    log "DEBUG" "🔍 Checking if Runtime Detection is enabled..."
    kubectl get cm node-agent -n "${KUBESCAPE_NAMESPACE}" -o jsonpath='{.data.config\.json}' | \
        jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true &> /dev/null || \
        error_exit "One or both of 'applicationProfileServiceEnabled' and 'runtimeDetectionEnabled' are not enabled. Exiting."
    log "DEBUG" "✅ Runtime Detection is enabled."
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

if [[ "$DEBUG_MODE" = false ]]; then
    log "INFO" "✅ All prerequisites verified."
fi

#####################################
# Deploy or Validate Application Pod
#####################################

# Trap any EXIT signal and call the cleanup function
trap cleanup EXIT

# Check if the provided pod exists, is ready, and if its application profile exists and is completed
if [[ -n "${EXISTING_POD_NAME}" ]]; then
    log "INFO" "🔍 Checking if the pod and its application profile are ready..."

    # Check if the pod exists and is ready
    pod_ready_status=$(kubectl get pod -n "${NAMESPACE}" "${EXISTING_POD_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || \
        error_exit "Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' does not exist."
    log "DEBUG" "✅ Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' exists."

    if [[ "${pod_ready_status}" != "True" ]]; then
        error_exit "Pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' is not ready."
    fi

    APP_NAME=$(kubectl get pod -n "${NAMESPACE}" "${EXISTING_POD_NAME}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null) || \
        error_exit "Failed to retrieve the app name for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}'."
    log "DEBUG" "✅ Application name '${APP_NAME}' retrieved successfully."

    # Check if the application profile exists and is completed
    APP_PROFILE_NAME=$(kubectl get "${APP_PROFILE_API}" -n "${NAMESPACE}" -o json | \
        jq -r --arg APP_NAME "${APP_NAME}" '.items[] | select(.metadata.labels["kubescape.io/workload-name"]==$APP_NAME) | .metadata.name') || \
        error_exit "Failed to retrieve the application profile name for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}'."
    log "DEBUG" "✅ Application profile '${APP_PROFILE_NAME}' exists."

    application_profile_status=$(kubectl get "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" -o jsonpath="${STATUS_JSONPATH}" 2>/dev/null) || \
        error_exit "Application profile for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' does not exist."

    if [[ "${application_profile_status}" != "completed" ]]; then
        error_exit "Application profile for pod '${EXISTING_POD_NAME}' in namespace '${NAMESPACE}' is not completed (current status: '${application_profile_status}')."
    fi

    log "INFO" "✅ The provided pod: '${EXISTING_POD_NAME}' and its application profile: "${APP_PROFILE_NAME}" are ready."
else
    log "INFO" "🚀 Deploying the application: '${APP_NAME}' in namespace: '${NAMESPACE}'..."
    sed -e "s/\${APP_NAME}/${APP_NAME}/g" -e "s/\${LEARNING_PERIOD}/${LEARNING_PERIOD}/g" "${APP_YAML_PATH}" | kubectl apply -n "${NAMESPACE}" -f - &> /dev/null || \
        error_exit "Failed to apply '${APP_YAML_PATH}'. Exiting."

    log "DEBUG" "⏳ Waiting for application's pod to be created..."
    APP_POD_NAME=""
    SECONDS=0 # Initialize the SECONDS counter
    while [[ -z "${APP_POD_NAME}" ]]; do
        if (( SECONDS >= "${APP_CREATION_TIMEOUT%s}" )); then
            error_exit "Timed out after '${APP_CREATION_TIMEOUT}' seconds waiting for application's pod to be created."
        fi
        APP_POD_NAME=$(kubectl get pod -l app="${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2> /dev/null)
        sleep 1
    done
    log "DEBUG" "✅ Application's pod '${APP_POD_NAME}' created successfully!"

    log "DEBUG" "⏳ Waiting for the application's pod to be ready..."
    kubectl wait --for=condition=ready pod "${APP_POD_NAME}" -n "${NAMESPACE}" --timeout="${APP_CREATION_TIMEOUT}" &> /dev/null || \
        error_exit "'${APP_POD_NAME}' pod is not ready. Exiting."
    log "DEBUG" "✅ Application's pod is ready!"

    ###################################################
    # Wait for the Application Profile to be Completed
    ###################################################

    log "DEBUG" "⏳ Waiting for application profile to be created..."
    APP_PROFILE_NAME=""
    SECONDS=0  # Initialize the SECONDS counter
    while [[ -z "${APP_PROFILE_NAME}" ]]; do
        if (( SECONDS >= "${APP_PROFILE_CREATION_TIMEOUT%s}" )); then
            error_exit "Timed out after '${APP_PROFILE_CREATION_TIMEOUT}' seconds waiting for application profile creation."
        fi
        APP_PROFILE_NAME=$(kubectl get "${APP_PROFILE_API}" -n "${NAMESPACE}" -o json 2> /dev/null | \
            jq -r --arg APP_NAME "${APP_NAME}" '.items[] | select(.metadata.labels["kubescape.io/workload-name"]==$APP_NAME) | .metadata.name')
        sleep 1
    done
    log "DEBUG" "✅ Application profile '${APP_PROFILE_NAME}' in namespace '${NAMESPACE}' created successfully!"

    log "DEBUG" "⏳ Waiting for the application profile to be ready..."
    kubectl wait --for=jsonpath="${STATUS_JSONPATH}"=ready "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" \
        --timeout="${APP_PROFILE_READINESS_TIMEOUT}" &> /dev/null || \
        error_exit "Application profile is not ready after '${APP_PROFILE_READINESS_TIMEOUT}' timeout. Exiting."

    # Generate activities to populate the application profile
    if [[ -n "${PRE_RUN_SCRIPT}" ]]; then
        log "DEBUG" "🛠️ Copying pre-run script '${PRE_RUN_SCRIPT}' to the pod and executing it..."
        kubectl cp "${PRE_RUN_SCRIPT}" "${NAMESPACE}/${APP_POD_NAME}:/tmp/pre-run-script.sh" || \
            error_exit "Failed to copy pre-run script to the pod."
        PRE_RUN_PID=$(kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- \
            sh -c 'chmod +x /tmp/pre-run-script.sh && /tmp/pre-run-script.sh > /tmp/pre-run-script.log 2>&1 & echo $!') || \
            error_exit "Failed to execute pre-run script on the pod."
        log "INFO" "✅ Pre-run script executed successfully with PID: '${PRE_RUN_PID}'."
    else
        log "DEBUG" "🛠️ Generating default activities to populate the application profile..."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c '
        {
            cat &&
            curl --help &&
            ping -c 1 1.1.1.1 &&
            ln -sf /dev/null /tmp/null_link
        } > /dev/null 2>&1' > /dev/null 2>&1 && \
        log "INFO" "✅ Pre-run activities completed successfully." || \
            log "INFO" "⚠️ One or more pre-run activities failed."
    fi

    log "INFO" "⏳ Waiting for the application profile to be completed... This may take up to ⏰ '${LEARNING_PERIOD}'...."
    kubectl wait --for=jsonpath="${STATUS_JSONPATH}"=completed "${APP_PROFILE_API}" "${APP_PROFILE_NAME}" -n "${NAMESPACE}" \
        --timeout="${APP_PROFILE_COMPLETION_TIMEOUT}" &> /dev/null || \
        error_exit "Application profile is not completed after '${APP_PROFILE_COMPLETION_TIMEOUT}' timeout. Exiting."
    sleep "${POST_APP_PROFILE_COMPLETION_DELAY%s}"
    log "INFO" "✅ Application profile is completed!"

fi

############################
# Verify Detections Locally
############################

NODE_NAME=$(kubectl get pod "${APP_POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}') || error_exit "Failed to retrieve the node name. Exiting."
log "DEBUG" "✅ Pod '${APP_POD_NAME}' is running on node: '${NODE_NAME}'."

NODE_AGENT_POD=$(kubectl get pod -n "${KUBESCAPE_NAMESPACE}" -l app=node-agent -o jsonpath="{.items[?(@.spec.nodeName=='${NODE_NAME}')].metadata.name}") || \
    error_exit "Failed to find the node-agent pod. Exiting."
log "DEBUG" "✅ Node-agent pod identified: '${NODE_AGENT_POD}'."

verify_detections() {
    log "INFO" "🔍 Verifying detections locally after '${VERIFY_DETECTIONS_DELAY}' delay..."
    sleep "${VERIFY_DETECTIONS_DELAY%s}"

    local detections=("$@") # Accept detections as parameters
    log "DEBUG" "🔍 Fetching logs from node-agent pod..."
    log_output=$(kubectl logs -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}") || error_exit "Failed to fetch logs from node-agent pod. Exiting."

    log "DEBUG" "🔍 Verifying all detections in logs..."
    for detection in "${detections[@]}"; do
        if [ -n "$(echo "${log_output}" | grep -i "${detection}.*${APP_POD_NAME}")" ]; then
            log "INFO" "✅ Detection '${detection}' found."
        else
            log "INFO" "⚠️ Detection '${detection}' not found."
        fi
    done
}

summarize_detections() {
    log_destination="/tmp/${APP_NAME}-attack-detections-$(date +%s).log"
    LOG_FILES+=("${log_destination}")
    log "INFO" "🔍 Summarizing detections locally after '${VERIFY_DETECTIONS_DELAY}' delay..."

    log "DEBUG" "📝 Logging new events after checkpoint '${CHECKPOINT}' and filtering by app name '${APP_NAME}'..."
    sleep "${VERIFY_DETECTIONS_DELAY%s}"
    kubectl logs --since-time "${CHECKPOINT}" -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}" | grep "${APP_NAME}" > "${log_destination}" || \
        error_exit "Failed to fetch logs from node-agent pod. Exiting."

    log "INFO" "📝 Full log saved to ‘${log_destination}’. Below is a summary."

    jq -r '.BaseRuntimeMetadata.alertName' "${log_destination}" | sort | uniq -c | sort -nr || \
        log "INFO" "⚠️ No detections found in the logs."
}

##############################
# Initiate Security Incidents
##############################

initiate_security_incidents() {
    log "INFO" "🎯 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'ls > /dev/null 2>&1' > /dev/null 2>&1 || \
        log "INFO" "⚠️ Failed to list directory contents. Exiting."

    log "INFO" "🎯 Initiating 'Unexpected service account token access' security incidents..."
    log "INFO" "🎯 Initiating 'Workload uses Kubernetes API unexpectedly' security incidents..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods > /dev/null 2>&1' > /dev/null 2>&1 || \
        log "INFO" "⚠️ Failed to initiate 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents. Exiting."

    log "INFO" "🎯 Initiating 'Soft link created over sensitive file' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'ln -sf /etc/passwd /tmp/asd > /dev/null 2>&1' > /dev/null 2>&1 || \
        log "INFO" "⚠️ Failed to initiate 'Soft link created over sensitive file' incident. Exiting."

    log "INFO" "🎯 Initiating 'Environment Variables Read from procfs' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'cat /proc/self/environ > /dev/null 2>&1' > /dev/null 2>&1 || \
        log "INFO" "⚠️ Failed to initiate 'Environment Variables Read from procfs' incident. Exiting."

    log "INFO" "🎯 Initiating 'Crypto Mining Domain Communication' security incident..."
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'curl data.miningpoolstats.stream > /dev/null 2>&1' > /dev/null 2>&1 || \
        log "INFO" "⚠️ Failed to initiate 'Crypto mining domain communication' incident. Exiting."
}

######################################
# Execute Attack Script with Cleanup
######################################

execute_attack_script() {
    interrupted=false
    log "DEBUG" "🛠️ Copying attack script '${ATTACK_SCRIPT}' to the pod and executing it..."
    CHECKPOINT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    kubectl cp "${ATTACK_SCRIPT}" "${NAMESPACE}/${APP_POD_NAME}:/tmp/attack-script.sh" || \
        error_exit "Failed to copy attack script to the pod."
    # Start executing the attack script in the background
    kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c 'chmod +x /tmp/attack-script.sh && /tmp/attack-script.sh' &
    ATTACK_PID=$!
    log "DEBUG" "✅ Attack script started with PID: '${ATTACK_PID}'."

    # **Added: Dedicated Cleanup Function for Attack Script**
    cleanup_attack() {
        log "INFO" "🧹 Cleaning up the attack script..."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- pkill -f "/tmp/attack-script.sh" &> /dev/null || \
            log "INFO" "⚠️ Failed to kill attack script process."
        kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- rm -f /tmp/attack-script.sh &> /dev/null || \
            log "INFO" "⚠️ Failed to remove attack script from the pod."
        log "INFO" "✅ Attack script cleaned up successfully."
    }

    # **Modified: Wait for Configurable Duration Instead of Using 'wait'**
    wait_for_termination() {
        log "INFO" ""
        log "INFO" "==============================================================="
        log "INFO" "⏳ Attack script will run for '${ATTACK_DURATION}' (or press Ctrl+C to stop)..."
        log "INFO" "==============================================================="
        log "INFO" "To adjust the duration, use the '--attack-duration' argument."
        log "INFO" ""
        sleep "${ATTACK_DURATION%s}"
        if [ "$interrupted" = false ]; then
            cleanup_attack
        fi
    }

    # **Keep: Trap Ctrl+C to Invoke Cleanup Without Exiting Script Prematurely**
    trap 'log "INFO" "⏹️ Ctrl+C detected. Stopping attack script..."; interrupted=true; cleanup_attack' SIGINT

    wait_for_termination

    # Remove the trap after completion
    trap cleanup SIGINT

    if [[ "${VERIFY_DETECTIONS}" == true ]]; then
        summarize_detections
    fi
}

#######
# Main
#######

case $MODE in
    "interactive")
        while true; do
            log "INFO" ""
            read -p "👩‍🔬 Do you want to initiate a security incident? [y/n]: " choice
            if [[ "${choice}" == "y" || "${choice}" == "Y" ]]; then
                if [[ -n "${ATTACK_SCRIPT}" ]]; then
                    execute_attack_script
                else
                    initiate_security_incidents
                    if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                        sleep "${VERIFY_DETECTIONS_DELAY%s}"
                        verify_detections "Unexpected process launched" "Unexpected Service Account Token Access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
                    fi
                fi
            elif [[ "${choice}" == "n" || "${choice}" == "N" ]]; then
                log "INFO" "⏭️ Skipping further security incident initiation."
                break
            else
                log "INFO" "⚠️ Invalid input. Please enter 'y' or 'n'."
            fi
        done
        ;;
    "investigation")
        log "INFO" "💻 Run a shell command to check for Armo threat detection:"
        while true; do
            log "INFO" ""
            read -p "$ " choice
            log "DEBUG" "${choice}"
            checkpoint=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            log "DEBUG" "Checkpoint: ${checkpoint}"
            kubectl exec -n "${NAMESPACE}" "${APP_POD_NAME}" -- sh -c "${choice}"
            log "INFO" ""
            log "INFO" "✅ Command executed successfully. Waiting for detections..." || \
                log "INFO" "⚠️ Failed to execute the command."

            log "INFO" ""
            log "INFO" "=============================================================================="
            log "INFO" " 🔍 Checking for threat detections triggered by your command after '${VERIFY_DETECTIONS_DELAY}' delay"
            log "INFO" "=============================================================================="
            sleep "${VERIFY_DETECTIONS_DELAY%s}" 
            node_agent_logs=$(kubectl logs --since-time "${checkpoint}" -n "${KUBESCAPE_NAMESPACE}" "${NODE_AGENT_POD}" || \
                error_exit "Failed to fetch logs from node-agent pod. Exiting.")
            # Check if logs are empty
            if [[ -z "${node_agent_logs}" ]]; then
                log "INFO" "⚠️ No threats found for the executed command."
            else
                log "INFO" "${node_agent_logs}"
                log "INFO" "✅ Command executed and detection logs retrieved."
            fi

            log "INFO" "========================================================="
            log "INFO" " Synchronizer activities logged for the executed command"
            log "INFO" "========================================================="
            synchronizer_logs=$(kubectl logs --since-time "${checkpoint}" -n "${KUBESCAPE_NAMESPACE}" "deployment.apps/synchronizer" || \
                error_exit "Failed to fetch logs from node-agent pod. Exiting.")
            # Check if logs are empty
            if [[ -z "${synchronizer_logs}" ]]; then
                log "INFO" "⚠️ No updates sent to Armo by the synchronizer for the executed command."
            else
                log "INFO" "${synchronizer_logs}"
                log "INFO" "✅ Command executed and synchronizer logs retrieved."
            fi
        done
        ;;
    "run_all_once" | *)
        if [[ -n "${ATTACK_SCRIPT}" ]]; then
            execute_attack_script
        else
            initiate_security_incidents
            if [[ "${VERIFY_DETECTIONS}" == true ]]; then
                verify_detections "Unexpected process launched" "Unexpected Service Account Token Access" "Kubernetes Client Executed" "Symlink Created Over Sensitive File" "Environment Variables from procfs" "Crypto mining domain communication"
            fi
            log "INFO" "✅ Exiting after one-time incident initiation."
        fi
        ;;
esac

cleanup