# Armo demo-cluster Deployment with ArgoCD

## Clone Repository
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

### Set ARMO’s Private Registry Password for Image Pulling
```sh
yq eval '.kubescape.imagePullSecret.password = "<set_the_password>"' -i environments/production/kubescape/values.yaml
```
or
```sh
sed -i '' 's|password: .*|password: <set_the_password>|' environments/production/kubescape/values.yaml
```

### Exclude Kubescape Resources from ArgoCD tracking (Optional)
```sh
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
    "data": {
      "resource.exclusions": "- apiGroups:\n  - spdx.softwarecomposition.kubescape.io\n  kinds:\n    - \"*\"\n  clusters:\n    - \"*\""
    }
  }'
```

## Deploy the App-of-Apps
```sh
kubectl apply -f environments/production/applications/templates/app-of-apps.yaml
```
This step sets up the application structure:
1. Deploys the App-of-Apps, which manages itself.
2. Takes control of the existing ArgoCD installation, enabling it to manage itself from this point onward.
3. Deploys and manages Kubescape's agent for security monitoring.
4. Deploys all of the apps for the demo

## Restart ArgoCD components to ensure proper scanning by ARMO
```sh
kubectl rollout restart deployment -n argocd
kubectl rollout restart statefulset -n argocd
```

## Trigger ADR Detection with the Attack Simulator (Optional)
```sh
armo-platform-tools/attack-simulator/
chmod +x attack-simulator.sh
./attack-simulator.sh
popd
```

## Connect to ArgoCD
Retrieve the initial admin password and port-forward the ArgoCD UI:
```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
kubectl port-forward service/argocd-server -n argocd 8080:443
```

Now, access ArgoCD at [https://localhost:8080](https://localhost:8080) and log in using the retrieved password.
