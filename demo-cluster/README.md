# Armo demo-cluster Deployment with ArgoCD

## Setup Repository
```sh
git clone https://github.com/armosec/armo-platform-tools.git
cd armo-platform-tools/demo-cluster
```

## Deploy ArgoCD (Without Applications)
```sh
pushd environments/production/argocd-infra
helm dep up
kubectl create ns argocd
helm template -n argocd argocd-infra . | kubectl apply -n argocd -f -    
rm -rf charts/ Chart.lock
popd
```

## Configure Kubescape Prerequisites
### Deploy a Secret with ARMO Account Credentials
```sh
kubectl create ns kubescape
kubectl create secret generic cloud-secret \
  --from-literal=account="<your_accountID>" \
  --from-literal=accessKey="<your_accessKey>" \
  -n kubescape
```

### Exclude Kubescape Resources from ArgoCD Scan (Optional)
```sh
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
    "data": {
      "resource.exclusions": "- apiGroups:\n  - spdx.softwarecomposition.kubescape.io\n  kinds:\n    - \"*\"\n  clusters:\n    - \"*\""
    }
  }'
```

## Deploy the App-of-Apps
This step sets up the application structure:
1. Deploys the **App-of-Apps**, which manages itself.
2. Registers ArgoCD, which was manually installed earlier.

```sh
kubectl apply -f environments/production/applications/templates/app-of-apps.yaml
```

## Connect to ArgoCD
Retrieve the initial admin password and port-forward the ArgoCD UI:
```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
kubectl port-forward service/argocd-server -n argocd 8080:443
```

Now, access ArgoCD at [https://localhost:8080](https://localhost:8080) and log in using the retrieved password.

---

### Notes
- Ensure Helm dependencies are updated before deploying ArgoCD.
- The `resource.exclusions` patch prevents ArgoCD from tracking Kubescape resources.
- The App-of-Apps structure allows ArgoCD to manage itself and future applications seamlessly.

