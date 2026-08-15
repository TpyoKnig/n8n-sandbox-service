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

`enforce` is the label that matters. If your cluster also sets `warn` and
`audit` to `restricted`, every install prints a paragraph of PodSecurity
warnings about the runner's `privileged: true`. They are advisory and the
install proceeds. Set all three to keep the output readable:

```bash
kubectl label namespace n8n-sandbox   pod-security.kubernetes.io/warn=privileged   pod-security.kubernetes.io/audit=privileged
```

## 2. Create the auth Secret

The chart reads four keys from one Secret. `runner-api-key` and
`runner-api-keys` must hold the **same** value: the API presents the first when
calling a runner, and the runner accepts the second.

```bash
RUNNER_KEY=$(openssl rand -hex 24)

kubectl -n n8n-sandbox create secret generic sandbox-auth   --from-literal=api-keys="$(openssl rand -hex 24)"   --from-literal=runner-registration-token="$(openssl rand -hex 24)"   --from-literal=runner-api-key="$RUNNER_KEY"   --from-literal=runner-api-keys="$RUNNER_KEY"
```

The generated-secret path (`auth.generated.*`) works too, but puts the values
in your Helm release. Prefer the Secret.

## 3. Provide the mTLS certificates

The API and runner authenticate to each other with mTLS, and the chart's
default `tls.mode: existingSecret` expects four TLS Secrets that it does not
create. Left unset, both pods sit in `ContainerCreating` waiting for volumes
that never appear.

The shortest working path is `tls.mode: certManager`, which renders all four
`Certificate` resources for you. It needs an issuer. If you already run a CA
`Issuer` or `ClusterIssuer`, use it and skip this. Otherwise bootstrap a
self-signed one:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: sandbox-selfsigned
  namespace: n8n-sandbox
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sandbox-ca
  namespace: n8n-sandbox
spec:
  isCA: true
  commonName: n8n-sandbox-ca
  secretName: sandbox-ca
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: sandbox-selfsigned
    kind: Issuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: sandbox-ca
  namespace: n8n-sandbox
spec:
  ca:
    secretName: sandbox-ca
EOF
```

See [cert-manager-k8s.md](./cert-manager-k8s.md) for what each of the four
certificates is for, and for wiring an existing CA instead.

## 4. Install the chart

No node labels, no tolerations and no RuntimeClass are needed. Any node that can
run a privileged pod can run this.

```bash
helm install n8n-sandbox ./charts/n8n-sandbox-service   --namespace n8n-sandbox   --set dataPlane.mode=dind   --set auth.existingSecret=sandbox-auth   --set tls.mode=certManager   --set tls.certManager.issuerRef.name=sandbox-ca   --set tls.certManager.issuerRef.kind=Issuer
```

Configure the runner through the `dindRunner` block, which mirrors
`sysboxRunner` field for field. See [configuration.md](./configuration.md).

## 5. Verify

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

## Verified on

This path was installed and exercised end to end on:

| | |
| --- | --- |
| Distribution | Talos Linux v1.13.7, kernel `6.18.39-talos` |
| Kubernetes | v1.36.3, containerd 2.2.6 |
| Chart | `n8n-sandbox-service` 0.3.0, `dataPlane.mode: dind` |
| TLS | `tls.mode: certManager`, self-signed CA per the step above |

The runner registered over mTLS and reported capacity, and a sandbox created
through `POST /sandboxes` executed Python and shell, returning `exit_code: 0`.
`uname -r` inside the sandbox reported the Talos kernel, which is the point:
the inner Docker daemon is running on a host where sysbox cannot be installed
at all.

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

**`operation not permitted` dialing the API, in the runner log at startup.**
Expected, and it clears itself. The runner comes up before its inner Docker
daemon has finished setting up networking, so the first registration attempts
fail and back off. Registration succeeded on the third try in testing, about 12
seconds in. Only worry if `runner registered` never appears in the API log.

**Pods stuck in `ContainerCreating`.** Almost always a missing Secret, because
the kubelet blocks on the volume rather than reporting a config error. Check
which one:

```bash
kubectl -n n8n-sandbox describe pod <pod> | tail -20
kubectl -n n8n-sandbox get secret
```

Expect `sandbox-auth` from step 2 and the four TLS Secrets from step 3. If the
TLS ones are absent, cert-manager has not issued them: `kubectl -n n8n-sandbox
get certificate` shows `READY: False` with the reason.
