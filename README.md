# AWS EKS Better Practice with Terraform

## Update kubeconfig **frequently**

### Pre-requisite

- awscli
- kubectx

```sh
export AWS_PROFLIE=YOUR_PROFILE
export CLUSTER_NAME=YOUR_CLUSTER_NAME

# TODO: more elegant way e.g. cli, krew?
# Set a simple context and user name,
# each with CLUSTER_NAME and AWS_PROFLIE, not the verbose arn
aws eks update-kubeconfig --name $CLUSTER_NAME --alias $AWS_PROFILE@$CLUSTER_NAME--user-alias $AWS_PROFILE
# Set a simple cluster name over the verbose arn
sed -i s%$(aws eks describe-cluster --name $CLUSTER_NAME | jq -r .cluster.arn | awk -F/ '{ print $1"/" }')%% -- $HOME/.kube/config

# Cleanup
# caveat: the cluster and context would be removed but the USER would NOT
k ctx -d $AWS_PROFILE@$CLUSTER_NAME
```

