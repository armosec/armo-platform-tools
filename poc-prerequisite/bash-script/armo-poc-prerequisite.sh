#!/bin/bash

set -euo pipefail

# Load parameters from values.conf
source values.conf

# Function to validate file existence
validate_files() {
  local files=("$IP_FILE" "$EBPF_DAEMONSET_FILE" "$PV_CHECK_PVC_FILE")

  for file in "${files[@]}"; do
    if [[ ! -f $file ]]; then
      echo "❌ Required file not found: $file"
      exit 1
    fi
  done
}

# Validate the required files before proceeding
validate_files

# Function to check network accessibility
check_network_accessibility() {
  local IP_LIST
  IP_LIST=$(<"$IP_FILE")

  local OUTPUT
  local FAILED_ADDRESSES=""
  local POD_NAME="armo-network-check"

  trap "kubectl delete pod $POD_NAME" EXIT

  kubectl run $POD_NAME --image=busybox --env="IP_LIST=$IP_LIST" --restart=Never -- sh -c '
    FAILED_ADDRESSES=""

    for ADDR in $IP_LIST; do
      if ! nc -z -w 5 $ADDR 443; then
        FAILED_ADDRESSES="$FAILED_ADDRESSES $ADDR"
      fi
    done

    if [ -z "$FAILED_ADDRESSES" ]; then
      echo "success"
    else
      echo "failed to access:$FAILED_ADDRESSES"
    fi
  '

  # Wait for the pod to complete by checking the pod's phase
  while true; do
    PHASE=$(kubectl get pod $POD_NAME -o jsonpath='{.status.phase}')
    if [ "$PHASE" == "Succeeded" ] || [ "$PHASE" == "Failed" ]; then
      break
    fi
    sleep 1
  done

  # Retrieve the output from the pod's logs
  OUTPUT=$(kubectl logs $POD_NAME 2>&1)

  trap - EXIT
  kubectl delete pod $POD_NAME

  if echo "$OUTPUT" | grep -q "failed to access"; then
    echo "$OUTPUT" | grep "failed to access"
    return 1
  elif echo "$OUTPUT" | grep -q "error"; then
    echo "$OUTPUT"
    return 1
  elif echo "$OUTPUT" | grep -q "success"; then
    return 0
  fi

  return 1
}

# Function to verify Helm chart installation permissions
verify_helm_permissions() {
  local CLUSTER_NAME
  CLUSTER_NAME=$(kubectl config current-context)
  local HELM_OUTPUT
  
  HELM_OUTPUT=$( { helm repo add "$RELEASE_NAME" "$HELM_REPO" && \
    helm repo update && \
    helm upgrade --install --dry-run "$RELEASE_NAME" "$CHART_NAME" \
    -n "$NAMESPACE" --create-namespace \
    --set clusterName="$CLUSTER_NAME" \
    --set account="$ACCOUNT_ID" \
    --set accessKey="$ACCESS_KEY" \
    --set server="$SERVER"; } 2>&1)
  
  if [ $? -eq 0 ]; then
    return 0
  else
    echo "$HELM_OUTPUT"
    return 1
  fi
}

# Function to check eBPF support on all nodes
check_ebpf_support() {
  local OUTPUT
  local UNSUPPORTED_NODES=""
  local DAEMONSET_NAME="armo-ebpf-check"
  local TIMEOUT=30
  
  trap "kubectl delete daemonset $DAEMONSET_NAME" EXIT

  OUTPUT=$(kubectl apply -f "$EBPF_DAEMONSET_FILE")

  # Wait for the DaemonSet to schedule the desired number of pods
  echo "Waiting for the DaemonSet '$DAEMONSET_NAME' to schedule pods..."
  local desiredPods=0
  local scheduledPods=0
  while [ "$desiredPods" -eq 0 ] || [ "$scheduledPods" -ne "$desiredPods" ]; do
    read desiredPods scheduledPods < <(kubectl get daemonset $DAEMONSET_NAME -o jsonpath='{.status.desiredNumberScheduled} {.status.currentNumberScheduled}')
    echo "Scheduled pods: $scheduledPods/$desiredPods"
    sleep 1
  done

  # Now wait for all scheduled pods to be ready
  echo "Waiting for all pods of the DaemonSet '$DAEMONSET_NAME' to be ready..."
  kubectl wait --for=condition=Ready --timeout=${TIMEOUT}s pod -l app=$DAEMONSET_NAME

  # Fetch pod names
  PODS=$(kubectl get pods -l app=$DAEMONSET_NAME -o jsonpath='{.items[*].metadata.name}')
  
  for pod in $PODS; do
    if ! kubectl logs $pod | grep -q "eBPF is supported"; then
      UNSUPPORTED_NODES="$UNSUPPORTED_NODES $(kubectl get pod $pod -o jsonpath='{.spec.nodeName}')"
    fi
  done

  kubectl delete daemonset $DAEMONSET_NAME

  trap - EXIT

  if [ -n "$UNSUPPORTED_NODES" ]; then
    echo "eBPF is not supported on the following nodes: $UNSUPPORTED_NODES"
    return 1
  else
    echo "eBPF is supported on all nodes."
    return 0
  fi
}

# Function to check PV support
check_pv_support() {
  local OUTPUT
  local PVC_NAME="armo-pv-check-pvc"
  local POD_NAME="armo-pv-check-pod"
  local TIMEOUT=30 # Timeout in seconds to wait for PV provisioning

  trap "kubectl delete pod $POD_NAME; kubectl delete pvc $PVC_NAME" EXIT

  # Apply the PVC and Pod in the same file
  OUTPUT=$(kubectl apply -f "$PV_CHECK_PVC_FILE")

  # Wait for PVC to be bound, timeout after $TIMEOUT seconds
  for ((i=0; i<TIMEOUT; i++)); do
    PVC_STATUS=$(kubectl get pvc $PVC_NAME -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" == "Bound" ]; then
      echo "success"
      kubectl delete pod $POD_NAME
      kubectl delete pvc $PVC_NAME
      trap - EXIT
      return 0
    fi
    sleep 1
  done

  echo "failed to bind PVC"
  return 1
}
# Function to clean the previous line in the terminal
clean_previous_line() {
  echo -n -e "\033[1A\033[K"
}

# Function to format and print failure details
print_failure_details() {
  echo -e "\n######################\n###    Details    ###\n######################\n\n$1"
}

# Main script execution
stty -echo -icanon time 0 min 0

FAILURES=0

echo "🔄 Checking network accessibility..."
if ! NETWORK_FAILURES=$(check_network_accessibility); then
  clean_previous_line
  echo "❌ Network accessibility check failed."
  print_failure_details "$NETWORK_FAILURES"
  FAILURES=$((FAILURES + 1))
else
  clean_previous_line
  echo "✅ Network accessibility check passed."
fi

echo "🔄 Checking Helm chart installation permissions..."
if ! HELM_FAILURES=$(verify_helm_permissions); then
  clean_previous_line
  echo "❌ Helm chart installation permissions check failed."
  print_failure_details "$HELM_FAILURES"
  FAILURES=$((FAILURES + 1))
else
  clean_previous_line
  echo "✅ Helm chart installation permissions check passed."
fi

echo "🔄 Checking eBPF support on all nodes..."
if ! EBPF_FAILURES=$(check_ebpf_support); then
  clean_previous_line
  echo "❌ eBPF support check failed."
  print_failure_details "$EBPF_FAILURES"
  FAILURES=$((FAILURES + 1))
else
  clean_previous_line
  echo "✅ eBPF support check passed."
fi

echo "🔄 Checking PV support..."
if ! PV_FAILURES=$(check_pv_support); then
  clean_previous_line
  echo "❌ PV support check failed."
  print_failure_details "$PV_FAILURES"
  FAILURES=$((FAILURES + 1))
else
  clean_previous_line
  echo "✅ PV support check passed."
fi

echo
if [ $FAILURES -eq 0 ]; then
  echo "🎉🐼 Your cluster is ready for the ARMO Security POC."
else
  echo "🚨 Your cluster is not ready for the ARMO Security POC. Failures: $FAILURES"
fi

stty sane
