# Accessing Grafana (kube-prometheus-stack)

Grafana runs in the `monitoring` namespace as part of the existing
`kube-prometheus-stack` installation. It is not exposed externally, so access
requires a `kubectl port-forward`.

## 1. Set the right gcloud/kubectl context

```bash
gcloud container clusters get-credentials armo-platform-cluster \
  --zone us-central1-c \
  --project elated-pottery-310110
```

Verify you're pointed at the right cluster:

```bash
kubectl config current-context
# expect: gke_elated-pottery-310110_us-central1-c_armo-platform-cluster
```

## 2. Get the admin credentials

```bash
# username
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-user}' | base64 -d && echo

# password
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## 3. Port-forward to Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Then open **http://localhost:3000** and log in with the credentials from step 2.

## Notes

- The port-forward runs in the foreground; run it in a separate terminal (or with `&`
  to background it) if you need the shell for other commands.
- The Pyroscope data source (name: `Pyroscope`) should already be configured, pointing
  at `http://pyroscope-query-frontend.pyroscope.svc.cluster.local:4040`. If it's
  missing (e.g. after a Grafana reinstall), add it via **Connections > Data sources
  > Add data source > Pyroscope**, using that URL.
