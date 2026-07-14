# Enabling Pyroscope Profiling on node-agent

## Prerequisites
- Pyroscope must already be deployed on the cluster (see the `pyroscope` Application
  in `../applications/templates/helm-releases.yaml`), reachable at:
  `http://pyroscope-distributor.pyroscope.svc.cluster.local:4040`

## Steps

1. Open `../helm-releases/armosec/values.yaml` (the values file for the ArgoCD
   `armosec` Application).

2. Add the following under `kubescape-operator.nodeAgent`:

   ```yaml
   nodeAgent:
     env:
       - name: ENABLE_PROFILER
         value: "enable"
       - name: PYROSCOPE_SERVER_SVC
         value: "http://pyroscope-distributor.pyroscope.svc.cluster.local:4040"
   ```

   > **Warning:** Helm replaces list values entirely rather than merging them.
   > If `nodeAgent.env` already has other entries (e.g. `IGNORERULEBINDINGS`), include
   > them in this same list or they will be dropped from the running daemonset.

3. Commit and push - with `selfHeal: true` on the `armosec` Application, ArgoCD picks
   up the change automatically.

4. Verify the env vars landed on the actual container (node-agent is the second
   container in the daemonset pod spec, index `[1]`):

   ```bash
   kubectl get daemonset node-agent-e2-standard-2 -n kubescape \
     -o jsonpath='{.spec.template.spec.containers[1].env}'
   ```

5. Confirm profiles are being pushed:

   ```bash
   kubectl logs -n kubescape -l k8s-app=node-agent -c node-agent --tail=50 | grep -i pyroscope
   ```

   You should see periodic `uploading at http://pyroscope-distributor...` debug lines.

## Verifying in Grafana

Once pushed, `node-agent` will appear as a service in the Grafana Pyroscope
Profiles Drilldown app ("All services" view), with `process_cpu` and `memory`
profile types available.
