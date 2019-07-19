aws s3 mb s3://${NAME}

kops create cluster \
    --zones us-west-2a \
    --node-size m4.large \
    --master-size m4.large \
    --node-count 3 \
    --master-count 3 \
    --master-zones us-west-2a,us-west-2b,us-west-2c \
    ${NAME}

kops edit cluster ${NAME}
# then add specs from new_cluster.yaml

kops update cluster ${NAME} --yes