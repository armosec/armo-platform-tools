#!/bin/bash

##############################################
# Verify Kubescape Runtime Detection is ready
##############################################

echo "🔍 Verifying Kubescape Storage is ready..."
kubectl wait -n kubescape --for=condition=ready pod -l app.kubernetes.io/part-of=kubescape-storage --timeout=600s || { echo "❌ Kubescape Storage is not ready. Exiting."; exit 1; }

echo "🔍 Verifying Kubescape is ready..."
kubectl wait -n kubescape --for=condition=ready pod -l app.kubernetes.io/instance=kubescape --timeout=600s || { echo "❌ Kubescape is not ready. Exiting."; exit 1; }

echo "🔍 Verifying Runtime Detection is enabled..."
kubectl get cm node-agent -n kubescape -o jsonpath='{.data.config\.json}' | jq '.applicationProfileServiceEnabled and .runtimeDetectionEnabled' | grep true || { echo "❌ One or both of applicationProfileServiceEnabled and runtimeDetectionEnabled are not enabled. Exiting."; exit 1; }

######################
# Install the web app
######################

echo "🚀 Applying the YAML file for the web app..."
kubectl apply -f ping-app.yaml || { echo "❌ Failed to apply ping-app.yaml. Exiting."; exit 1; }

echo "⏳ Waiting for the web app to be ready..."
kubectl wait --for=condition=ready pod -l app=ping-app --timeout=600s || { echo "❌ Web app is not ready. Exiting."; exit 1; }

###############################################
# Wait for the application profile to be ready
###############################################

echo "⏳ Waiting for the application profile to be created..."
sleep 10
kubectl get applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-ping-app > /dev/null || { echo "❌ Application profile not found. Exiting."; exit 1; }

echo "⏳ Waiting for the application profile to initialize..."
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=initializing applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-ping-app --timeout=100s

echo "⏳ Waiting for the application profile to be ready..."
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=ready applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-ping-app --timeout=300s || { echo "❌ Application profile is not ready. Exiting."; exit 1; }

echo "🛠️ Generating activities to populate the application profile..."
kubectl exec -t ping-app -- sh -c 'cat && curl --help > /dev/null 2>&1' || { echo "❌ Failed to generate activities. Exiting."; exit 1; }

echo "⏳ Waiting for the application profile to be completed..."
kubectl wait --for=jsonpath='{.metadata.annotations.kubescape\.io/status}'=completed applicationprofiles.spdx.softwarecomposition.kubescape.io/pod-ping-app --timeout=600s || { echo "❌ Application profile is not completed. Exiting."; exit 1; }

###############################
# Initiate a security incident
###############################

# Function to initiate a security incident
initiate_security_incidents() {
    echo "🚨 Initiating 'Unexpected process launched' security incident..."
    kubectl exec -t ping-app -- ls || { echo "❌ Failed to list directory contents. Exiting."; exit 1; }

    echo "🚨 Initiating 'Unexpected service account token access' & 'Workload uses Kubernetes API unexpectedly' security incidents..."
    kubectl exec -t ping-app -- sh -c 'curl -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://kubernetes.default.svc/api/v1/namespaces/default/pods' || { echo "❌ Failed to initiate security incident. Exiting."; exit 1; }
    echo "✅ Incident initiated successfully."
}

# Check for command-line argument or loop for user input
if [ "$1" == "--initiate-incident" ]; then
    echo "⏳ Waiting 60s before initiating a security incident..."
    sleep 60
    initiate_security_incidents
    echo "Exiting after one-time incident initiation."
else
    while true; do
        read -p "⚠️ Do you want to initiate a security incident? [y/n]: " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            initiate_security_incidents
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            echo "⏭️ Skipping further security incident initiation."
            break
        else
            echo "❌ Invalid input. Please enter 'y' or 'n'."
        fi
    done
fi

echo "✅ Script execution completed successfully."
