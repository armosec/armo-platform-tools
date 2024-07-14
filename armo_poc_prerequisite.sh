#!/bin/bash

set -euo pipefail

# Function to check network accessibility
check_network_accessibility() {
  local IP_FILE="ip_list.txt"
  if [[ ! -f $IP_FILE ]]; then
    echo "❌ IP list file not found: $IP_FILE"
    return 1
  fi

  local IP_LIST
  IP_LIST=$(<"$IP_FILE")

  local OUTPUT
  local FAILED_ADDRESSES=""

  trap "kubectl delete pod armo-network-check" SIGINT

  OUTPUT=$(kubectl run armo-network-check --rm -it --image=busybox --env="IP_LIST=$IP_LIST" --restart=Never -- sh -c '
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

  trap - SIGINT

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
  local RELEASE_NAME="kubescape"
  local CHART_NAME="kubescape/kubescape-operator"
  local NAMESPACE="kubescape"
  local CLUSTER_NAME
  CLUSTER_NAME=$(kubectl config current-context)
  local ACCOUNT_ID="00000000-0000-0000-0000-000000000000"
  local ACCESS_KEY="00000000-0000-0000-0000-000000000000"
  local SERVER="api.armosec.io"
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

  trap "kubectl delete daemonset armo-ebpf-check" SIGINT

  OUTPUT=$(kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: armo-ebpf-check
  labels:
    app: armo-ebpf-check
spec:
  selector:
    matchLabels:
      app: armo-ebpf-check
  template:
    metadata:
      labels:
        app: armo-ebpf-check
    spec:
      containers:
      - name: armo-ebpf-check
        image: busybox
        command:
        - /bin/sh
        - -c
        - |
          #!/bin/sh
          if [ ! -r /sys/fs/bpf ]; then
            echo "eBPF is not supported on $(hostname)"
          else
            echo "eBPF is supported on $(hostname)"
            exit 1
          fi
          sleep 3600
      restartPolicy: Always
EOF
  )

  sleep 10

  PODS=$(kubectl get pods -l app=armo-ebpf-check -o jsonpath='{.items[*].metadata.name}')
  
  for pod in $PODS; do
    if ! kubectl logs $pod | grep -q "eBPF is supported"; then
      UNSUPPORTED_NODES="$UNSUPPORTED_NODES $(kubectl get pod $pod -o jsonpath='{.spec.nodeName}')"
    fi
  done

  kubectl delete daemonset armo-ebpf-check

  trap - SIGINT

  if [ -n "$UNSUPPORTED_NODES" ]; then
    echo "failed on nodes:$UNSUPPORTED_NODES"
    return 1
  else
    echo "success"
    return 0
  fi
}

# Function to check PV support
check_pv_support() {
  local OUTPUT

  trap "kubectl delete pvc armo-pv-check-pvc" SIGINT

  OUTPUT=$(kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: armo-pv-check-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
  )

  sleep 10

  PVC_STATUS=$(kubectl get pvc armo-pv-check-pvc -o jsonpath='{.status.phase}')

  kubectl delete pvc armo-pv-check-pvc

  trap - SIGINT

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
