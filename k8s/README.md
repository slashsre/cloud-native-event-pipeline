# Kubernetes Stack (Cluster & Workloads)

If you want enable the environment please read the Makefile

## Tools
```bash
Docker    29.1.5
Bash      5.3.8
Kind      0.33.0
Python    3.14.3   # host; app images use python:3.13-slim
Helm      4.2.2
```

Runtime / cluster components:
```bash
kubectl        1.34.10
Kubernetes     1.33.0        # kindest/node:v1.33.0
ingress-nginx  1.15.1        # nginx 1.27.1
registry       3
OpenSSL        3.6.1
```

## Cluster creation and configuration

```bash
mkdir -p cluster
```

```bash
cat > cluster/kind-configuration.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  serviceSubnet: 10.244.0.0/16
  podSubnet: 172.24.0.0/16
containerdConfigPatches:
- |
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
    endpoint = ["http://kind-registry:5000"]
nodes:
- role: control-plane
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
```

### The kind configuration file estructure explain:

```bash
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  serviceSubnet: 10.244.0.0/16                                              <---- Service segment already defined
  podSubnet: 172.24.0.0/16                                                  <---- Pod segment already defined
containerdConfigPatches:
- |
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
    endpoint = ["http://kind-registry:5000"]                                <---- Registry Configuration
nodes:
- role: control-plane                                                       <---- Multinode Configuration at least one master node
- role: worker                                                              <---- Multinode Configuration at least one app nodes
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"                                    <---- Ingress label for expose service purpose
  extraPortMappings:
  - containerPort: 80                                                        <---- Node ports
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
```

### Execute the creation

```bash
kind create cluster \
--name event-pipeline-cluster \
--image kindest/node:v1.33.0 \
--config=cluster/kind-configuration.yaml
```

### Validate Local Cluster

```bash
kind get clusters
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
```

Note: In a production-grade cluster, this topology could be expanded to three control-plane nodes for high availability, two application nodes for workloads, and two dedicated infrastructure nodes for ingress-nginx. Dedicated ingress nodes isolate north-south traffic management from application workloads and provide a clear, scalable entry point for exposing microservices. For this local Kind environment, a single worker is sufficient; the `ingress-ready=true` label identifies the node eligible to run ingress-nginx.

## CoreDNS - DNS resolution for the server alternative names

The client must reach the server by its three names **using DNS resolution** (not `/etc/hosts`). `server` resolves natively through the Kubernetes Service; `server.example.com` and `server.local` are resolved with `rewrite` rules in CoreDNS that map them to the Service FQDN (`server.event-pipeline.svc.cluster.local`). This resolves to the Service's current ClusterIP without hardcoding any IP.

### Add the rewrite rules

```bash
kubectl -n kube-system edit configmap coredns
```

Add these two lines right after `ready` inside the `.:53 { ... }` block:

```bash
rewrite name server.example.com server.event-pipeline.svc.cluster.local
rewrite name server.local server.event-pipeline.svc.cluster.local
```

The versioned ConfigMap is stored in `cluster/coredns-configmap.yaml` and can be reapplied directly:

```bash
kubectl -n kube-system apply -f cluster/coredns-configmap.yaml
kubectl -n kube-system rollout restart deployment coredns
```

### Validate DNS resolution

```bash
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 -n event-pipeline \
  --command -- sh -c 'for n in server server.example.com server.local; do nslookup $n; done'
```

The three names must resolve to the current ClusterIP of the `server` Service.

### Create a local docker-registry

```bash
reg_name='kind-registry'
reg_port='5000'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
    registry:3
fi
```

### Verify that the Registry is running perfecttly
```
docker ps --filter "name=kind-registry"
```
output
```
CONTAINER ID        IMAGE               COMMAND                  CREATED             STATUS              PORTS                    NAMES
84ab536f99d9        registry:2          "/entrypoint.sh /etc…"   14 hours ago        Up 14 hours         0.0.0.0:5000->5000/tcp   kind-registry
```

### Configure conection between kind-registry and kubernetes-kind-cluster

```bash
docker network connect kind kind-registry
```

## Certificates

```bash
mkdir -p certs
```

### Generate Openssl config file

```bash
cat > certs/san.cnf << EOF
[ req ]
default_bits        = 2048
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
req_extensions      = req_ext
x509_extensions     = v3_ca

[ req_distinguished_name ]
C                   = ES
ST                  = Madrid
L                   = Madrid
O                   = Event Pipeline
OU                  = Engineering
CN                  = server

[ req_ext ]
subjectAltName      = @alt_names

[ v3_ca ]
subjectAltName      = @alt_names
basicConstraints    = critical, CA:TRUE
keyUsage            = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage    = serverAuth, clientAuth

[ alt_names ]
DNS.1               = server
DNS.2               = server.example.com
DNS.3               = server.local
DNS.4               = localhost
DNS.5               = server.event-pipeline.svc.cluster.local
IP.1                = 127.0.0.1
EOF
```

### Generate self-signed certificates for microservices client/server

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/server.key \
  -out certs/server.crt \
  -config certs/san.cnf \
  -extensions v3_ca
```

Note: Generate crt and key certificates for tls-ingress, server and client with Openssl. Adding an additional DNS resolution "DNS.5 = server.default.svc.cluster.local" for internal resolucion between client and server.

### Helm Ingress Nginx install for testing purpose.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

```bash
   helm install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --create-namespace \
     --set controller.service.type=NodePort \
     --set controller.service.externalTrafficPolicy=Local \
     --set controller.hostPort.enabled=true \
     --set-string controller.nodeSelector.ingress-ready=true \
     --set controller.config.use-forwarded-headers=true \
     --set controller.config.compute-full-forwarded-for=true
```

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

Note: Flags that help to avoid the 127.0.0.1 in logs: "hostPort.enabled=true" and "externalTrafficPolicy=Local" this Flag: controller.nodeSelector.ingress-ready=true permit that ingress controller pod match with the kind configuration: "node-labels: "ingress-ready=true"".

## Apps

### Code Additionals for Client Service and 5 seconds or more loop

```bash
    def run_loop(self, interval=5):
        print(f'Starting client loop with interval of {interval}s...', flush=True)
        while True:
            self.run_once()
            time.sleep(interval)
```

```bash
    request_interval = int(os.getenv('REQUEST_INTERVAL', '5'))
```

```bash
    if request_interval > 0:
        client.run_loop(interval=request_interval)
    else:
        client.run_once()
```

### Build and Tagging

```bash
cd apps

# tag
docker build -t localhost:5000/client-app:1.0.0 client-app-1.0.0/
docker build -t localhost:5000/server-app:1.0.0 server-app-1.0.0/

#push
docker push localhost:5000/client-app:1.0.0
docker push localhost:5000/server-app:1.0.0
```

Note: Dockerfile prepared with basic layers, non root users, dependencies file. Pushed to our local registry.

## Deploy Microservices with manifest

```bash
.
├── client-app-1.0.0
│   ├── client-secret.yaml
│   ├── client.sh
│   ├── deployment.yaml
│   └── service.yaml
├── client-secret.yaml
├── delete.sh
├── deploy.sh
├── namespace.yaml
└── server-app-1.0.0
    ├── deployment.yaml
    ├── ingress.yaml
    ├── secret-tls.yaml
    ├── server-backend-ca.yaml
    ├── server.sh
    └── service.yaml
```

### Deployment Client

Note: Adding support for External Environment Variables. Important to check that REQUEST_INTERVAL are

```bash
- name: SERVER_ADDRESSES
  value: "server,server.example.com,server.local"
- name: SERVER_PORT
  value: "5001"
- name: REQUEST_INTERVAL
  value: "5"
- name: CERT_PATH
  value: "/app/certs/server.crt"
```


# Extended Features & Integrations


## Client Traffic Generation Loop

### Also added at the Client Service App

```bash
    def run_loop(self, interval=5):
        print(f'Starting client loop with interval of {interval}s...', flush=True)
        while True:
            self.run_once()
            time.sleep(interval)
```

```bash
    request_interval = int(os.getenv('REQUEST_INTERVAL', '5'))
```

```bash
    if request_interval > 0:
        client.run_loop(interval=request_interval)
    else:
        client.run_once()
```

Client periodically performs internal requests in a scheduled loop.

## AWS ALB Ingress Architecture

AWS ALB Ingress controller example manifest available at `manifests/ingress-aws-alb.yaml`.

## AWS Event Pipeline Integration

### Firts - Server service code

Check comments server.py code

### Second - Deployment configs

```bash
        # --- Ingestion pipeline wiring (AWS Event Ingestion Pipeline) ---
        - name: INGEST_ENABLED
          value: "true"
        - name: INGEST_URL
          value: "https://host.docker.internal:8443/events"
        - name: INGEST_CA_PATH          # validate the endpoint's TLS, never -k
          value: "/app/ingest-ca/ca.pem"
        - name: INGEST_API_KEY          # sourced from Secrets Manager -> k8s Secret
          valueFrom:
            secretKeyRef:
              name: ingestion-api-key
              key: api-key
              optional: true            # pod starts even if AWS isn't up yet
```

### Third - Secrets configs

```bash
./manifests/server-app-1.0.0/gen-ingestion-secrets.sh
```

Note: The secrets are necessary for the TLS and ApiKey connection of the Pipeline Ingestion Service.


## TEST ----------

The goal is to reach the server over HTTPS validating its certificate (never `-k`)
and to observe the request traces in the server service.

### 1. Follow the server traces

In one terminal, stream the server logs so you can watch requests arrive live:

```bash
kubectl logs -n event-pipeline -l app=server -f
```

Each request is logged as:

```
<client-ip> - - [date] "GET / HTTP/1.1" 200 -
```

- Requests coming **through the ingress** show the ingress pod IP as client (the proxy).
- Requests coming **internally from the client pod** show the client pod IP.

### 2. Test through the Ingress from the host (trusted TLS)

CoreDNS resolves the three names **inside** the cluster. From your host (Mac),
map them to `localhost` so curl can reach the ingress (it publishes 443 via
`hostPort`). Add once to `/etc/hosts`:

```bash
127.0.0.1  server server.example.com server.local
```

Then curl each name validating the server certificate with the CA (no `-k`,
real validation):

```bash
curl --cacert certs/server.crt https://server/
curl --cacert certs/server.crt https://server.example.com/
curl --cacert certs/server.crt https://server.local/
```

Expected: a `200` response from each, and a matching line in the server logs
(step 1) with the ingress pod IP as the origin.

### 3. Test internal DNS resolution + cert (from inside the cluster)

To prove the request uses **DNS resolution** (not `/etc/hosts`) and the trusted
cert, run it from inside the cluster. The client pod already mounts the CA at
`/app/certs/server.crt`:

```bash
kubectl exec -n event-pipeline deploy/client -- python -c \
"import requests
for h in ['server','server.example.com','server.local']:
    r = requests.get(f'https://{h}:5001', verify='/app/certs/server.crt')
    print(h, '->', r.text.strip())"
```

Expected: the three names resolve via CoreDNS to the server ClusterIP and return
`Domain: <name>:5001, Client IP: <client-pod-ip>`. These same calls happen
automatically every 5s via the client loop (periodic loop).

### 4. Inspect the certificate served by the server (SANs)

```bash
openssl s_client -connect server.local:443 -servername server.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

Expected SANs: `server`, `server.example.com`, `server.local`, `localhost`,
`server.event-pipeline.svc.cluster.local`.

### 5. Confirm the real origin IP in the nginx logs (no 127.0.0.1)

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=10
```

The `$remote_addr` field must show a real IP (the Docker network gateway, e.g.
`172.19.0.1` / `192.168.65.1`), never `127.0.0.1`.
