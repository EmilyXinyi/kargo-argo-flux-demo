# Demo: Kargo + Argo CD + Flux

One Kargo project rolls cert-manager out across a fleet. Kargo bumps the chart version in Git. Argo CD syncs the Flux `HelmRelease` object for each stage. Flux helm-controller installs or upgrades upstream cert-manager into that stage's cluster with the Helm SDK and keeps reconciling it. Argo reads the HelmRelease's Ready condition as health, and Kargo gates the next stage on that health.

```
            Warehouse (charts.jetstack.io/cert-manager)
                         │ Freight = chart version
                    addons-test
                    ╱          ╲
           addons-prod-eu   addons-prod-us
                 │                 │
      Argo CD App (HelmRelease)  Argo CD App (HelmRelease)
                 │                 │
       Flux helm-controller   Flux helm-controller
                 │                 │
          vcluster prod-eu    vcluster prod-us
```

## One cluster, three "clusters"

Everything runs on a single kind cluster. Each stage's cluster is a [vcluster](https://www.vcluster.com/) in its own namespace:

```
kind cluster kargo-argo-flux
├─ argocd, kargo, cert-manager   (this cert-manager is Kargo's dependency, not the demo's)
├─ flux-system                   source-controller + helm-controller only
├─ vc-test      vcluster  + HelmRelease cert-manager  →  cert-manager inside the vcluster
├─ vc-prod-eu   vcluster  + HelmRelease cert-manager  →  cert-manager inside the vcluster
└─ vc-prod-us   vcluster  + HelmRelease cert-manager  →  cert-manager inside the vcluster
```

Why vclusters rather than plain namespaces: cert-manager's CRDs, webhooks and leader-election lease are cluster-wide. Three copies in plain namespaces would collide, and upgrading `test` would also upgrade the CRDs for "prod". A vcluster gives each stage its own API server, so its CRDs are its own.

Flux runs once, on the host. Each HelmRelease sits in `vc-<stage>` and uses `spec.kubeConfig` (the `vc-vcluster` Secret that vcluster exports) to install into that stage's vcluster. As a result, Argo CD only deploys to its own cluster: there are no clusters to register and no cluster labels.

## Who does what

| Concern | Tool |
|---|---|
| Discover new chart versions, promote stage to stage | Kargo |
| Deliver the HelmRelease for each stage; fleet-wide visibility | Argo CD (ApplicationSet) |
| Run Helm (SDK) against each stage's cluster, remediate failed upgrades, correct drift | Flux helm-controller |

## Layout

```
setup.sh                         creates the kind cluster and installs everything
vk.sh                            kubectl into a stage's vcluster: ./vk.sh test get pods -A
cluster/vcluster-values.yaml     shared vcluster config
addons/cert-manager/base/        HelmRepository + HelmRelease (upstream chart)
addons/cert-manager/env/<stage>/ namespace vc-<stage> + chart version (Kargo writes here)
argocd/addons-appset.yaml        one Application per stage
kargo/                           Project, Warehouse, PromotionTask, Stages
```

## Setup

Prerequisites: `docker`, `kind`, `kubectl`, `helm`, `flux`.

1. **Point the repo at your fork.** Replace `emilyxinyi` in `argocd/addons-appset.yaml` and `kargo/promotiontask.yaml`, then push this repo.
2. **Run `./setup.sh`.** This creates the kind cluster, then installs cert-manager (for Kargo), Argo CD, Kargo, Flux and the three vclusters, and applies `kargo/` and the ApplicationSet. Chart versions are pinned at the top of the script. The script is safe to re-run.
3. **Give Kargo push access.** Add a Git credentials Secret to the `kargo-argo-flux` namespace.
4. **Set the starting version.** Sync the three `cert-manager-*` apps once in Argo CD. Each `env/<stage>/version-patch.yaml` starts at 1.17.2, so the live promotion is a real upgrade.

The script prints the port-forward commands and logins for the Argo CD and Kargo UIs. Each port-forward runs in a restart loop, because `kubectl port-forward` exits on the first connection reset. Kargo's API resets connections now and then, for example on a plain `http://` request. Use `https://`; both UIs have self-signed certs.

## Run of show (about 6 minutes)

1. **Kargo pipeline view (1 min).** Show the new cert-manager Freight waiting, with test fanning out to prod-eu and prod-us.
2. **Promote to test (2 min).** Show the Git commit, then the Argo CD app syncing the HelmRelease, then the HelmRelease going Progressing to Healthy. Flip to `flux get helmreleases -A` so both views are on screen. It lists every stage in one place.
3. **Drift (1 min).** Run `./vk.sh test -n cert-manager scale deploy cert-manager --replicas=0`, then watch helm-controller restore it with `./vk.sh test -n cert-manager get deploy -w`. Argo CD shows nothing here: it manages the HelmRelease on the host, not what runs inside the vcluster. helm-controller polls rather than watches, so the fix lands on its next reconcile, within the 1m `interval`. To show it right away, trigger the next reconcile early with `flux reconcile helmrelease cert-manager -n vc-test`. Either way, `kubectl -n vc-test get events --field-selector involvedObject.kind=HelmRelease` shows `DriftDetected` then `DriftCorrected`. This is the "continuously managed Helm state" point, shown live.
4. **Promote to both prod stages (2 min).** This is the fleet moment: the same version lands in both regions in parallel, each one gated on health. Close with: Kargo promotes, Argo CD delivers, Flux runs Helm.

## Risk control

- **Pre-pull images.** Use `kind load docker-image <image> --name kargo-argo-flux` to load the cert-manager images for both versions ahead of time. vcluster pods run on the kind node, so they use the loaded images. Conference Wi-Fi is the most likely failure.
- **Record a backup.** Keep a recording of the full run.
- **Keep intervals short.** The HelmRelease `interval` is 1m, so nothing appears to stall. If the drift fix is slow on stage, use `flux reconcile` (run of show, step 3).

## Open decisions

- **Delivery path.** Should Argo CD deliver the HelmRelease (as above), or should Kargo write to Git and a Flux Kustomization sync it directly? The direct path is more Flux-native, but Kargo then needs a verification job to know the upgrade succeeded.
- **OCI variant.** Kargo v1.12's `tar` and `oci-push` steps can publish rendered manifests as an OCI artifact for a Flux `OCIRepository`.

## Tested

On kind with Argo CD chart 10.11.6 (v3.5.6), Kargo 1.12.5, Flux 2.6.1 and vcluster 0.37.6:

- `setup.sh` runs end to end on a fresh cluster.
- Host Flux installs cert-manager into a vcluster.
- The drift fix works.
- No cert-manager CRDs leak to the host.
- Argo CD's built-in HelmRelease health check reports Healthy. No custom check is needed; the old `argocd-cm` fallback misread Flux 2.6 status and has been removed.

- Kargo promotes cert-manager to test and then to both prod stages, with Argo CD syncing each HelmRelease.
