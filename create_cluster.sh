NAME=my-cluster.com
KOPS_STATE_STORE=s3://my-cluster-kops-state-store

kops create cluster \
    --zones us-west-2a \
    --node-size m4.large \
    --master-size m4.large \
    --node-count 1 \
    --master-count 1 \
    --master-zones us-west-2a \
    ${NAME}

kops edit cluster ${NAME}
# then add specs from new_cluster.yaml

kops update cluster ${NAME} --yes