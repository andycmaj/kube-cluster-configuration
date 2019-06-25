#!/usr/bin/env bash

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# Define default arguments.
SCRIPT_ARGUMENTS=()
CLUSTER_NAME=$NAME
KOPS_STATE_STORE=$KOPS_STATE_STORE
REPLICA_COUNT=2
EXTERNAL_DNS_DOMAIN=
SSL_CERT_ARN=

# Parse arguments.
for i in "$@"; do
    case $1 in
        -n|--name) CLUSTER_NAME="$2"; shift ;;
        -s|--state-store) KOPS_STATE_STORE="$2"; shift ;;
        -r|--replica-count) REPLICA_COUNT="$2"; shift ;;
        -d|--external-dns-domain) EXTERNAL_DNS_DOMAIN="$2"; shift ;;
        -c|--ingress-cert-arn) SSL_CERT_ARN="$2"; shift ;;
        *) SCRIPT_ARGUMENTS+=("$1") ;;
    esac
    shift
done

echo "Using cluster '${CLUSTER_NAME}' and kops state store '${KOPS_STATE_STORE}'"

# Dashboard
echo "adding Heapster (https://github.com/kubernetes/dashboard/wiki/Integrations#heapster)..."
kubectl create -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/monitoring-standalone/v1.11.0.yaml

echo "adding Dashboard (https://github.com/kubernetes/dashboard#getting-started)..."
kubectl create clusterrolebinding kube-system-default-admin --clusterrole=cluster-admin --serviceaccount=kube-system:default
kubectl create clusterrolebinding kube-system-kubernetes-dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v1.10.1/src/deploy/recommended/kubernetes-dashboard.yaml
echo "run `kubectl -n kube-system describe secret kubernetes-dashboard-token-\{TAB\}` to get your dashboard token"

# Prometheus Operator. Run before any other services to create CRDs
helm tiller run -- helm repo add coreos https://s3-eu-west-1.amazonaws.com/coreos-charts/stable/
helm tiller run -- helm upgrade prometheus-operator --install coreos/prometheus-operator --namespace monitoring

# Nginx-ingress with L7 termination at ELB (https://github.com/helm/charts/tree/master/stable/nginx-ingress#aws-l7-elb-with-ssl-termination)
echo "adding Nginx-ingress (https://github.com/helm/charts/tree/master/stable/nginx-ingress#aws-l7-elb-with-ssl-termination)..."
cat > nginx-ingress-values.yaml << EOF
controller:
  image:
    tag: 0.21.0
  publishService:
    enabled: true
  stats:
    enabled: true
  metrics:
    enabled: true
  replicaCount: 2
  minAvailable: 2
  config:
    use-proxy-protocol: 'true'
  service:
    targetPorts:
      http: http
      https: http
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:us-west-2:002751257357:certificate/a3c01b1b-dcef-4f8b-9a2d-ff96dbd11cbe"
      service.beta.kubernetes.io/aws-load-balancer-backend-protocol: http
      service.beta.kubernetes.io/aws-loadbalancer-ssl-ports: https
      service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: '3600'
EOF
helm tiller run -- helm upgrade nginx-ingress --install stable/nginx-ingress --namespace ingress-nginx \
    -f nginx-ingress-values.yaml
# add ServiceMonitor and fix
# https://github.com/coreos/prometheus-operator/issues/890#issuecomment-406867556

# Nginx-ingress dashboard config
kubectl apply -f configmap_grafana-dashboard_nginx.yaml --namespace monitoring
# Nginx-ingress ServiceMonitor. imports nginx metrics into prometheus
kubectl apply -f service-monitor_nginx-ingress.yaml --namespace monitoring

# Prometheus Server, Grafana, etc.
helm tiller run -- helm upgrade kube-prometheus --install coreos/kube-prometheus --namespace monitoring \
    --set grafana.image.tag=5.3.1 \
    --set grafana.serverDashboardConfigmaps={nginx-ingress-dashboard-configmap}
kubectl apply -f ingress_grafana.yml --namespace monitoring

# External-dns
echo "adding External-dns (https://github.com/kubernetes-incubator/external-dns)..."
helm tiller run -- helm upgrade external-dns --install stable/external-dns --namespace kube-system \
    --set domainFilters={$EXTERNAL_DNS_DOMAIN} \
    --set txtOwnerId=$CLUSTER_NAME \
    --set aws.region=us-west-2 \
    --set aws.zoneType=public \
    --set logLevel=debug \
    --set rbac.create=true

# Cluster auto-scaling
# No min/max values are provided when using Auto-Discovery, cluster-autoscaler will respect the current min and max values of the ASG being targeted, and it will adjust only the "desired" value.
echo "to add Cluster-autoscaling, run cluster_autoscaling.sh (https://github.com/helm/charts/tree/master/stable/cluster-autoscaler#auto-discovery)..."
helm tiller run -- helm upgrade cluster-autoscaler --install stable/cluster-autoscaler --namespace kube-system \
    --set autoDiscovery.clusterName=$CLUSTER_NAME \
    --set awsRegion=us-west-2 \
    --set image.tag=v1.13.1



