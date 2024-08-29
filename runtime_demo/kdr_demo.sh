#!/bin/bash

POD_NAME="ping-app-$(date +%s)"

cleanup() {
    echo "🧹 Cleaning up the pod: ${POD_NAME}..."
    kubectl delete pod "${POD_NAME}"
}

error_exit() {
    echo "❌ $1" 1>&2
    exit 1
}

##############################################
# Verify Kubescape Runtime Detection is Ready
##############################################

echo "🔍 Verifying that Kubescape Storage is ready..."
kubectl wait -n kubescape --for=condition=ready pod -l app.kubernetes.io/part-of=kubescape-storage --timeout=600s || error_exit "Kubescape Storage is not ready. Exiting."

echo "🔍 Verifying that Kubescape is ready..."
kubectl wait -n kubescape --for=condition=ready pod -l app.kubernetes.io/instance=kubescape --timeout=600s || error_exit "Kubescape is not ready. Exiting."

echo "🔍 Checking if Runtime Detection is enabled..."
kubectl get cm node-agent -n kubescape -o jsonpath='{.data.config\.json}' | jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true || error_exit "One or both of 'applicationProfileServiceEnabled' and 'runtimeDetectionEnabled' are not enabled. Exiting."

######################
# Install the Web App
######################

# Trap any EXIT signal and call the cleanup function
trap cleanup EXIT

echo "🚀 Deploying the web app with a brief learning period of ⏰ 3 minutes: ${POD_NAME}..."
sed "s/\${POD_NAME}/${POD_NAME}/g" ping-app.yaml | kubectl apply -f - || error_exit "Failed to apply 'ping-app.yaml'. Exiting."

echo "⏳ Waiting for the web app pod to be ready..."
kubectl wait --for=condition=ready pod -l app="${POD_NAME}" --timeout=600s || error_exit "Web app pod is not ready. Exiting."

SELECTED_NODE=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}') || error_exit "Failed to retrieve the node name. Exiting."
echo "✅ Web app pod '${POD_NAME}' is running on node: ${SELECTED_NODE}."

echo "🔍 Finding the node-agent pod running on the same node..."
NODE_AGENT_POD=$(kubectl get pods -n kubescape -l app=node-agent -o jsonpath="{.items[?(@.spec.nodeName=='${SELECTED_NODE}')].metadata.name}") || error_exit "Failed to find the node-agent pod. Exiting."
echo "✅ Node-agent pod identified: ${NODE_AGENT_POD}."

###############################################
# Wait for the Application Profile to be Ready
###############################################

echo "⏳ Waiting for the application profile to be created..."
sleep 10
kubectl get applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" > /dev/null || error_exit "Application profile not found. Exiting."

echo "⏳ Waiting for the application profile to initialize or be ready..."
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=initializing applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" --timeout=5s || \
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=ready applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" --timeout=300s || \
error_exit "Application profile is not initializing or ready. Exiting."

echo "🛠️ Generating activities to populate the application profile..."
kubectl exec -t "${POD_NAME}" -- sh -c 'cat && curl --help > /dev/null 2>&1 && ping -c 1 1.1.1.1 > /dev/null 2>&1 && ln -s /dev/null /tmp/null_link' || error_exit "Failed to generate activities. Exiting."

echo "⏳ Waiting for the application profile to be completed..."
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=completed applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-"${POD_NAME}" --timeout=600s || error_exit "Application profile is not completed. Exiting."

############################
# Verify Detections Locally
############################

verify_detections() {
    local detections=("$@") # Accept detections as parameters
    echo "🔍 Fetching logs from node-agent pod..."
    log_output=$(kubectl logs -n kubescape "${NODE_AGENT_POD}") || error_exit "Failed to fetch logs from node-agent pod. Exiting."

    echo "🔍 Verifying all detections in logs..."
    for detection in "${detections[@]}"; do
        if echo "$log_output" | grep -iq "${detection}.*${POD_NAME}"; then
            echo "✅ Detection '${detection}' found for pod '${POD_NAME}'."
        else
            echo "❌ Detection '${detection}' not found for pod '${POD_NAME}'."
        fi
    done
}

###############################
# Initiate Security Incidents
###############################

initiate_security_incidents() {
    echo "🚨 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -t "${POD_NAME}" -- ls > /dev/null 2>&1 || error_exit "Failed to list directory contents. Exiting."
    
    echo "🚨 Initiating 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' ('Kubernetes Client Executed' locally) security incidents..."
    kubectl exec -t "${POD_NAME}" -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods > /dev/null 2>&1' || error_exit "Failed to initiate 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents. Exiting."
    
    echo "🚨 Initiating 'Soft link created over sensitive file' ('Symlink Created Over Sensitive File' locally) security incident..."
    kubectl exec -t "${POD_NAME}" -- sh -c 'ln -s /etc/passwd /tmp/asd > /dev/null 2>&1' || error_exit "Failed to initiate 'Soft link created over sensitive file' incident. Exiting."
    
    echo "🚨 Initiating 'Environment Variables Read from procfs' security incident..."
    kubectl exec -t "${POD_NAME}" -- sh -c 'cat /proc/self/environ > /dev/null 2>&1' || error_exit "Failed to initiate 'Environment Variables Read from procfs' incident. Exiting."
    
    echo "🚨 Initiating 'Crypto mining domain communication' security incident..."
    kubectl exec -t "${POD_NAME}" -- sh -c 'ping -c 4 data.miningpoolstats.stream > /dev/null 2>&1' || error_exit "Failed to initiate 'Crypto mining domain communication' incident. Exiting."
    
    echo "✅ All of the desired incidents detected successfully locally."
}

# Check for command-line argument or loop for user input
if [ "$1" == "--initiate-incident" ]; then
    echo "⏳ Waiting 10 seconds before initiating a security incident..."
    sleep 10
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

    # Prompt to delete the ${POD_NAME} pod
    read -p "🗑️ Would you like to delete the pod '${POD_NAME}'? [Y/n] " -r
    REPLY=${REPLY:-Y}
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup
    else
        echo "🚫 The pod '${POD_NAME}' was not deleted."
        trap - EXIT
    fi

fi

echo "✅ Script execution completed successfully."
