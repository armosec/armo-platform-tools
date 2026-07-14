# armo-platform-cluster environment

GitOps adoption of an existing, already-running GKE cluster (`armo-platform-cluster`,
project `elated-pottery-310110`, zone `us-central1-c`). This is a **side/demo cluster
with its own self-hosted ArgoCD** — it is independent of the `production` and
`production-us` environments in this repo and does not share their app-of-apps.

Before this environment existed, the cluster already had a self-hosted ArgoCD
(namespace `argocd`, deployed out-of-band — not via this repo) managing exactly two
Applications (`armosec`, `pyroscope`), sourced from a local, never-committed
`app.yaml`/`pyroscope-app.yaml` pair. Everything else running in the cluster was
unmanaged: standalone Helm releases nobody had wired into ArgoCD, and a large number
of raw/hand-applied workloads (demo apps, security-training fixtures, per-service
microservice namespaces). This environment brings all of that under ArgoCD,
including formalizing `armosec`/`pyroscope` into git for the first time (same
`metadata.name`/`namespace`, so ArgoCD adopts the existing live Applications rather
than creating duplicates).

## Critical policy: no prune, ever

**Every `Application`/`ApplicationSet` in this environment must omit
`syncPolicy.automated.prune` (or set it to `false`).** Prune is what deletes live
resources that fall out of the git-defined set, and this environment exists to
*adopt* already-running workloads without any risk of deleting them. If you add a
new Application here, do not add `prune: true`.

Every Application/ApplicationSet has `syncPolicy.automated.selfHeal: true` — after
initially running manual-sync-only while first adopting everything (diffed and
confirmed change-free by hand), this was switched back on once that verification
was done. selfHeal auto-corrects drift on resources ArgoCD already owns; it does
not create-or-delete anything prune would.

## Structure

- `applications/` — the Helm chart (this environment's own, distinct from
  `production`/`production-us`) containing the top-level `app-of-apps`, the
  `AppProject`s, both `ApplicationSet`s, and the individual `Application` manifests
  for one-off adoptions.
- `helm-releases/` — real, pre-existing Helm releases, adopted via chart+values so
  ArgoCD manages them the same way Helm did:
  - `prometheus` (namespace `default`) — public chart, no value overrides (pure
    chart defaults).
  - `kube-prometheus-stack` (namespace `monitoring`) — public chart, with the
    live release's actual value overrides.
  - `metadata-db` (namespace `default`) — a custom chart with no discoverable
    public source; captured as a static rendered-manifest snapshot instead.
  - `armosec` (namespace `kubescape`) — the kubescape-operator, the cluster's
    pre-existing security-scanning Application. Node agent's image tag is left
    unset so it always tracks whatever the chart's default/latest is, rather
    than pinning a specific version.
  - `pyroscope` (namespace `pyroscope`) — continuous profiling backend, feeding
    the node agent's profiler (see `docs-enable-node-agent-profiling.md` in
    this folder).
- `adopted/` — static manifest snapshots of raw/unmanaged workloads, one folder per
  Application: `redis-orphan` (an orphaned Bitnami redis StatefulSet whose Helm
  release record no longer points to it), `webshop`, `kubernetes-goat`,
  `attack-suite`, `admin`, `secure-middleware`, `big-monolith`,
  `kube-prometheus-stack-sealed-secrets` (the `SealedSecret` holding the Slack
  webhook, see the crashloop-alert note below).
- `docs/` — operational runbooks moved in from a local, never-committed
  `~/Desktop/kubescape-gke` folder: `grafana-access.md`,
  `enable-node-agent-profiling.md`.
- `online-boutique/` — 12 subfolders (one per namespace: `ad`, `cart`, `checkout`,
  `currency`, `email`, `frontend`, `loadgenerator`, `payment`, `product-catalog`,
  `recommendation`, `shipping`, `static-serving`), each a standalone deployment of
  one microservice. Managed by the `online-boutique` `ApplicationSet` via a git
  directory generator — add a 13th namespace by adding a 13th subfolder, no YAML
  edits required.
- `credit-suite/` — 5 subfolders (`credit-admin`, `credit-auth`, `credit-data`,
  `credit-finance`, `credit-public-web`), same ApplicationSet-driven pattern via the
  `credit-suite` ApplicationSet.

## Known intentionally-risky content

This cluster is a security-training/demo environment. Some captured manifests
contain content that would be a real problem in a production repo but is
deliberate here:

- `attack-suite/manifest.yaml` — `mysql`'s root password is sourced from a
  `mysql-credentials` Secret (created live, not committed) rather than a literal
  value, after GitGuardian flagged the original plaintext.
- `admin/manifest.yaml` — the SSH host private key lives in a `ssh-host-key` Secret
  (created live, not committed; the pod mounts it via a projected volume alongside
  the ConfigMap's public key + sshd_config), and `ping-app`'s password is sourced
  from a `ping-app-credentials` Secret. Both were originally committed as plaintext
  and flagged by GitGuardian; the existing values were kept as-is (not rotated) at
  the user's request.
- `credit-suite/credit-public-web/manifest.yaml` — a Log4Shell-vulnerable demo image
  with a shell loop that beacons to external domains, running privileged with a
  hostPath mount. This is a red-team/security-training fixture, not a real
  compromise — but treat any change to this file with extra scrutiny.
- `adopted/kubernetes-goat/manifest.yaml` — `bad-creds-deployment`/
  `health-check-deployment` mount `/var/run/docker.sock` and
  `/run/containerd/containerd.sock` privileged; `system-monitor-deployment` runs
  privileged with `hostPID`/`hostIPC` and a hostPath mount of `/`; `supplychain-attack`
  beacons to an external domain (same pattern as `credit-public-web` above).
- `adopted/webshop/manifest.yaml` — `currencyservice` and `emailservice` run
  `privileged: true` / `allowPrivilegeEscalation: true`, unlike their sibling
  services in the same file.
- `adopted/secure-middleware/manifest.yaml` — despite the namespace name, this runs
  a Kubernetes Goat `cache-store` image, not an actual security middleware.

None of the still-plaintext-adjacent items above (SSH key/password values
themselves, once created as Secrets; the beaconing/privileged workloads) were
redacted or removed; they were adopted as-is by explicit decision, since this whole
cluster exists to demonstrate exactly these kinds of misconfigurations.

## Bootstrapping

```sh
kubectl apply -f demo-cluster/environments/armo-platform-cluster/applications/templates/app-of-apps.yaml
```

This creates the `app-of-apps-armo-platform-cluster` Application, the `AppProject`s,
both `ApplicationSet`s, and every one-off `Application`. With `selfHeal: true` set
throughout, ArgoCD picks these up and syncs them automatically — no manual
`argocd app sync` needed for day-to-day changes. If you want to preview a change
before it applies (e.g. after editing a values file), `argocd app diff <app-name>`
still works the same way; selfHeal just means you no longer have to follow it with
a manual sync.
