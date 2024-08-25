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

  OUTPUT=$(kubectl run $POD_NAME --rm -it --image=busybox@sha256:50aa4698fa6262977cff89181b2664b99d8a56dbca847bf62f2ef04854597cf8 --env="IP_LIST=$IP_LIST" --restart=Never -- sh -c '
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
  ' 2>&1)

  trap - EXIT

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
  
  HELM_OUTPUT=$(helm upgrade --install --dry-run "$RELEASE_NAME" "$CHART_NAME" -n "$NAMESPACE" --create-namespace \
    --set clusterName="$CLUSTER_NAME" \
    --set account="$ACCOUNT_ID" \
    --set accessKey="$ACCESS_KEY" \
    --set server="$SERVER" 2>&1)
  
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

  trap "kubectl delete daemonset $DAEMONSET_NAME" EXIT

  OUTPUT=$(kubectl apply -f "$EBPF_DAEMONSET_FILE")

  # Wait for all desired pods to be ready
  local desiredPods=0
  local readyPods=0
  read desiredPods readyPods < <(kubectl get daemonset $DAEMONSET_NAME -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}')
  while [ "$desiredPods" -ne "$readyPods" ]; do
    echo "Wait for all pods of the DaemonSet '$DAEMONSET_NAME' to be ready. Ready pods: $readyPods/$desiredPods"
    sleep 5
    read desiredPods readyPods < <(kubectl get daemonset $DAEMONSET_NAME -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}')
  done

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

  trap "kubectl delete pvc $PVC_NAME" EXIT

  OUTPUT=$(kubectl apply -f "$PV_CHECK_PVC_FILE")

  sleep 10

  PVC_STATUS=$(kubectl get pvc $PVC_NAME -o jsonpath='{.status.phase}')

  kubectl delete pvc $PVC_NAME

  trap - EXIT

  if [ "$PVC_STATUS" == "Bound" ]; then
    echo "success"
    return 0
  else
    echo "failed to bind PVC"
    return 1
  fi
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
