# scloud Platform PKI

Internal public-key infrastructure for the 2SCloud platform.

## Trust chain

```
  ┌──────────────────────────────────┐
  │  scloud-selfsigned-bootstrap     │  ClusterIssuer (self-signed)
  │  (bootstrap only — never issues  │
  │   workload certs directly)       │
  └────────────────┬─────────────────┘
                   │ signs
                   ▼
  ┌──────────────────────────────────┐
  │  scloud-internal-root-ca         │  Certificate (CA)
  │  Secret: scloud-internal-root-ca │
  │  Namespace: cert-manager         │
  └────────────────┬─────────────────┘
                   │ referenced by
                   ▼
  ┌──────────────────────────────────┐
  │  scloud-internal-ca              │  ClusterIssuer (CA)
  │  (used by every workload)        │
  └────────────────┬─────────────────┘
                   │ signs
                   ▼
     Workload certificates
     (edge-gateway public TLS, future mTLS, …)
```

## Usage

To issue a cert for a workload, create a `Certificate` referencing
`scloud-internal-ca`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-service-tls
  namespace: my-namespace
spec:
  secretName: my-service-tls
  duration: 2160h     # 90 days
  renewBefore: 720h   # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  dnsNames:
    - my-service.my-namespace.svc.cluster.local
    - my-service.my-namespace.svc
  issuerRef:
    name: scloud-internal-ca
    kind: ClusterIssuer
    group: cert-manager.io
```

## Trusting the root from clients

Clients that need to verify workload certs (the edge-gateway when
proxying to internal HTTPS backends, operators running `kdig +https`,
etc.) must trust the root CA:

```bash
kubectl get secret scloud-internal-root-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > scloud-internal-ca.crt
```

Then pass `--cacert scloud-internal-ca.crt` to `curl`, or
`+tls-ca=scloud-internal-ca.crt` to `kdig`.

## Production migration

For production, replace `scloud-internal-root-ca` with a Certificate
signed by your corporate PKI (Vault, Venafi, AWS Private CA, etc.).
The `scloud-internal-ca` ClusterIssuer keeps the same name so no
workload manifests need to change — only the root secret rotates.

For public-facing certs (gateway on an internet-reachable hostname),
add a separate ClusterIssuer using ACME / Let's Encrypt and reference
it from the relevant Certificate resources.
