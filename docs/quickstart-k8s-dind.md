# Quickstart: Kubernetes without sysbox (dind mode)

This guide covers `dataPlane.mode: dind`, the in-cluster runner that uses
privileged Docker-in-Docker instead of the sysbox runtime.

Use [quickstart-k8s.md](./quickstart-k8s.md) instead unless you have a reason
not to. `sysbox` is the default and the stronger isolation, and this mode gives
some of that up.

## When this mode is the only option

Installing sysbox means writing the node's containerd configuration and
restarting kubelet. An immutable-rootfs distribution does not allow it:

- **Talos Linux** has no shell, no package manager, and a read-only `/`. The
  installer cannot run at all.
- **Flatcar Container Linux** and **Fedora CoreOS** have the same read-only
  `/usr` and expect node configuration to arrive through Ignition rather than a
  DaemonSet that mutates the running host.
- **GKE Autopilot** blocks privileged containers and most hostPath mounts, so
  neither the sysbox installer nor this mode works there.

On those clusters `dataPlane.mode: sysbox` is not slower or harder, it is
unavailable: the `sysbox-runc` RuntimeClass never exists, and the runner pod
stays `Pending` forever with no obvious cause.

## What you give up

Sysbox runs the runner inside a user namespace, so the inner Docker daemon
never holds real privileges on the node. `dind` gets those capabilities from the
kernel directly, and a privileged container can see the node's cgroup tree and
its devices.

That is a defensible trade for a namespace running code you already control,
including AI-generated code from your own instance. It is not a defensible trade
for a shared or multi-tenant cluster. If you cannot run sysbox and you do need
that boundary, the honest answer is a separate cluster or a dedicated node pool
you are willing to treat as compromised, not this mode with extra settings.

## 1. Allow privileged pods in the namespace

Pod Security Admission denies them by default. The denial lands on the
StatefulSet as an event rather than on a pod, so without this the symptom is
that no runner pod is ever created and nothing obviously errors.

```bash
kubectl create namespace n8n-sandbox
kubectl label namespace n8n-sandbox pod-security.kubernetes.io/enforce=privileged
```

## 2. Install the chart

No node labels, no tolerations and no RuntimeClass are needed. Any node that can
run a privileged pod can run this.

```bash
helm install n8n-sandbox ./charts/n8n-sandbox-service \
  --namespace n8n-sandbox \
  --set dataPlane.mode=dind \
  --set auth.existingSecret=sandbox-auth
```

Configure the runner through the `dindRunner` block, which mirrors
`sysboxRunner` field for field. See [configuration.md](./configuration.md).

TLS between the API and the runner works exactly as in sysbox mode; see
[cert-manager-k8s.md](./cert-manager-k8s.md).

## 3. Verify

```bash
kubectl -n n8n-sandbox get pods
kubectl -n n8n-sandbox logs deploy/n8n-sandbox-n8n-sandbox-service-api | grep 'runner registered'
```

A registered runner reports its capacity. Then confirm a sandbox actually runs,
which is the check that distinguishes a runner that started from a runner that
works.

`KEY` is one of the API keys the service accepts, the same credential a client
such as n8n presents. It lives under the `api-keys` key of the auth Secret,
named by `auth.secretKeys.apiKeys`, and holds a comma-separated list. Read it
back rather than retyping it:

```bash
KEY=$(kubectl -n n8n-sandbox get secret sandbox-auth -o jsonpath='{.data.api-keys}' | base64 -d | cut -d, -f1)
```

```bash
API=n8n-sandbox-n8n-sandbox-service-api
ID=$(kubectl -n n8n-sandbox exec deploy/$API -- \
  wget -qO- --header "X-Api-Key: $KEY" --header 'Content-Type: application/json' \
  --post-data '{}' http://localhost:8080/sandboxes | sed 's/.*"id":"\([^"]*\)".*/\1/')

kubectl -n n8n-sandbox exec deploy/$API -- \
  wget -qO- --header "X-Api-Key: $KEY" --header 'Content-Type: application/json' \
  --post-data '{"command":"echo ok"}' "http://localhost:8080/sandboxes/$ID/executions"
```

The second call streams NDJSON ending in an `exit` event with
`"success":true`.

## Storage

The inner Docker daemon writes image layers to `/var/lib/docker`. Sysbox gives
the container its own; here the chart mounts one, an `emptyDir` capped by
`dindRunner.dockerDataRoot.emptyDirSizeLimit` (20Gi by default).

Set `dindRunner.dockerDataRoot.persistence.enabled=true` to use a
`volumeClaimTemplate` instead. That survives a restart and skips re-pulling the
sandbox image, at the cost of a PVC per runner replica.

## Troubleshooting

**No runner pod, no error.** The namespace label from step 1 is missing. Check
`kubectl -n n8n-sandbox describe statefulset` for a PodSecurity event.

**`dockerd` exits immediately.** The container did not get privileged. Confirm
with `kubectl -n n8n-sandbox get pod <runner> -o jsonpath='{.spec.containers[0].securityContext}'`.

**Runner pod stays `Pending`.** Usually a leftover sysbox `nodeSelector` or
toleration. `dindRunner.scheduling` defaults to empty for exactly this reason.
