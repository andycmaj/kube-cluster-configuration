# Kubernetes

This repo contains scripts and instructions for configuring our standard Kubernetes cluster in AWS.

## Cluster Management

We create and manage clusters using [kops](https://github.com/kubernetes/kops/blob/master/docs/high_availability.md)

## Cluster Creation

:construction: See `create_cluster.sh` and `new_cluster.yaml`, and `new_instancegroup.yaml`.

1. run cluster creation command
2. update cluster config with `spec` additions from `new_cluster.yaml`.
3. modify `new_instancegroup.yaml`: replace `$NAME` with your cluster name, usually in env var `${NAME}`.
4. update instancegroup config with `spec` additions from `new_instancegroup.yaml`.
5. update cluster

## Addons

To install all addons, run [`configure-addons.sh`](configure-addons.sh).

* required environment variables:
  * `NAME`: kops cluster name, eg. `kubernertes.my-cluster.com`.
  * `KOPS_STATE_STORE`: kops s3 state bucket name, eg. `s3://my-cluster-state-store`
* cli arguments
  * `EXTERNAL_DNS_DOMAIN`: domain you'll be using for application ingress, eg. `my-cluster.com`.
  * `EXTERNAL_DNS_CERT_ARN`: arn of ACM cert to be used for `EXTERNAL_DNS_DOMAIN`
  * `DESIRED_REPLICAS`: the number of replicas of core pods. Usually should match the number of desired instances.

```bash
$ ./configure-addons.sh -d {EXTERNAL_DNS_DOMAIN} -c {EXTERNAL_DNS_CERT_ARN} -r {DESIRED_REPLICAS}
```

### [Dashboard](https://github.com/kubernetes/kops/blob/master/docs/addons.md#dashboard)

[Kubernetes Dashboard](https://github.com/kubernetes/dashboard) is a general purpose, web-based UI for Kubernetes clusters. It allows users to manage applications running in the cluster and troubleshoot them, as well as manage the cluster itself.

* Installed using the [kops addon](https://github.com/kubernetes/kops/blob/master/docs/addons.md#dashboard).
* [Heapster](https://github.com/kubernetes/kops/blob/master/docs/addons.md#monitoring-with-heapster---standalone) [needed for viewing cpu/memory metrics on dashboard](https://github.com/kubernetes/dashboard/wiki/Integrations#heapster).

#### access dashboard

```bash
$ kubectl create -f dashboard_user.yaml
$ kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep admin-user | awk '{print $1}')
```

### [Prometheus Operator + Kube-prometheus](https://github.com/coreos/prometheus-operator/tree/master/helm)

The Prometheus Operator makes the Prometheus configuration Kubernetes native and manages and operates Prometheus and Alertmanager clusters. It is a piece of the puzzle regarding full end-to-end monitoring.

kube-prometheus combines the Prometheus Operator with a collection of manifests to help getting started with monitoring Kubernetes itself and applications running on top of it.

* Installed using the [kube-prometheus helm chart](https://github.com/coreos/prometheus-operator/tree/master/helm)
* :construction: **TODO** add public access to Grafana UI

### [nginx-ingress controller](https://kubernetes.github.io/ingress-nginx)

We use `nginx-ingress`, an `Ingress` Controller to route external traffic to `Service`s running in the cluster, by routing the domain in the header of a request to the appropriate `Service`.

We deploy `nginx-ingress` roughly following the guide [here](https://kubernetes.github.io/ingress-nginx/deploy/). We use [L7 Termination](https://github.com/helm/charts/tree/master/stable/nginx-ingress#aws-l7-elb-with-ssl-termination) and [connect `nginx-ingress-controller` to Prometheus and Grafana](https://github.com/coreos/prometheus-operator/issues/890#issuecomment-406867556) for ingress metrics.

### [external-dns](https://github.com/kubernetes-incubator/external-dns)

External DNS is used to create and manage Route53 DNS records for Kubernetes resources, mainly domains routed to specific `Ingress`es and `Service`s. DNS records will alias to the Load Balancer in front of the `ingress-nginx` Ingress Controller.

We roughly use [this guide](tps://github.com/kubernetes-incubator/external-dns) for our deployment.

### [cluster auto-scaler](https://github.com/helm/charts/tree/master/stable/cluster-autoscaler#auto-discovery)

The Cluster autoscaler is be used to ensure that worker node groups can be expanded or
contracted as necessary to support all `Pods` being scheduled on a node group.

We use [this helm chart](https://github.com/helm/charts/tree/master/stable/cluster-autoscaler#auto-discovery), in "auto-discovery" mode, to install the cluster auto-scaler.

> No min/max values are provided when using Auto-Discovery, cluster-autoscaler will respect the current min and max values of the ASG being targeted, and it will adjust only the "desired" value.

## FAQ

### How does kops manage Route53 records for `services`?

> This answer is specific to the legacy annotation, `dns.alpha.kubernetes.io/external`. See [external-dns](#external-dns) for `Ingress` DNS management.

`Services` can have annotations, such as
`dns.alpha.kubernetes.io/external: foo.my-cluster.com`, that kops watches for. It will ensure these `services` get Route53 records attached
to their `LoadBalancers` in EC2.

When you bootstrap a kops cluster, a [`dns-controller`](https://github.com/kubernetes/kops/tree/master/dns-controller) deployment is automatically
created. This `deployment` manages the `dns-controller` `pods` that watch for and attach records to these `dns.alpha.kubernetes.io` annotations.

To see the `dns-controller` in action, try this command.

```bash
$ kubectl logs --namespace=kube-system dns-controller-54dc4bc55-smvqn --tail=10
I1015 19:37:37.243678       1 dnscontroller.go:610] Update desired state: service/my-namespace/my-svc-public: []
I1015 19:37:37.361678       1 dnscontroller.go:610] Update desired state: service/my-namespace/my-other-svc: []
I1015 19:37:41.203659       1 dnscontroller.go:435] Deleting all records for {CNAME my-other-svc-dev.my-cluster.com.}
I1015 19:37:41.203692       1 dnscontroller.go:421] Querying all dnsprovider records for zone "my-cluster.com."
I1015 19:37:41.495961       1 dnscontroller.go:494] Deleting resource record my-other-svc-dev.my-cluster.com. CNAME
I1015 19:37:41.496017       1 dnscontroller.go:435] Deleting all records for {CNAME my-svc-dev.my-cluster.com.}
I1015 19:37:41.496080       1 dnscontroller.go:494] Deleting resource record my-svc-dev.my-cluster.com. CNAME
I1015 19:37:41.496124       1 dnscontroller.go:301] applying DNS changeset for zone my-cluster.com.::ZIEGZM18G4G2S
I1015 19:51:36.164386       1 node.go:107] node watch channel closed
I1015 20:16:41.367104       1 service.go:108] service watch channel closed
```

## Deploying Applications on our Cluster

### Using `external-dns` in your applications

Any `Service` or `Ingress` that has the correct annotation will automatically work, and external-dns will create an A and a TXT record in the Route 53 domain zone you specified.

For Ingresses, `external-dns` looks for the `kubernetes.io/ingress.class` annotation. In our case, since we have deployed `ingress-nginx`, this will be `nginx`.

This is a hubexchange `Ingress` that will work after Bootstrapping a dev environment to the cluster. We have deployed a dev environment to the namespace `my-namespace`, and so we create the `Ingress` in the `my-namespace` namespace:

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: my-svc-ingress
  namespace: my-namespace
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: my-svc-ingress.my-cluster.com
    http:
      paths:
      - backend:
          serviceName: my-svc-public
          servicePort: 443
        path: /
```

A similar `Ingress` can be created for my-other-svc:

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: my-other-svc-ingress
  namespace: my-namespace
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: my-other-svc-ingress.my-cluster.com
    http:
      paths:
      - backend:
          serviceName: my-other-svc
          servicePort: 443
        path: /
```

For a `Service`, you will need the annotation `external-dns.alpha.kubernetes.io/hostname`. Here is an example of a `Service` with that annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    external-dns.alpha.kubernetes.io/hostname: nginx.external-dns-test.my-org.com.
spec:
  type: LoadBalancer
  ports:
  - port: 80
    name: http
    targetPort: 80
  selector:
    app: nginx
---

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: nginx
spec:
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - image: nginx
        name: nginx
        ports:
        - containerPort: 80
          name: http
```

Once either the `Ingress` or `Service` is created, `external-dns` should create the required DNS records based on the host you specify.
