terraform {
  required_version = "~> 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.17.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11.0"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

data "aws_availability_zones" "available" {}

locals {
  # VPC
  vpc_name        = "ebp-vpc"
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  vpc_cidr        = "10.0.0.0/16"
  partition       = cidrsubnets(local.vpc_cidr, 1, 1)
  private_subnets = cidrsubnets(local.partition[0], 2, 2)
  public_subnets  = cidrsubnets(local.partition[1], 2, 2)

  # EKS
  cluster_name    = "ebp-eks"
  cluster_version = "1.27"
  fargate_profile = {
    name = "default"
    namespaces = [
      "kube-system",
      "default",
      "karpenter",
      "argocd"
    ]
  }

  helm_values = {
    # TODO: replace to argocd
    karpenter = {
      "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.karpenter_aws.irsa_arn
      "settings.aws.clusterName"                                  = module.eks.cluster_name
      "settings.aws.defaultInstanceProfile"                       = module.karpenter_aws.instance_profile_name
      "settings.aws.interruptionQueueName"                        = module.karpenter_aws.queue_name
      "controller.resources.requests.cpu"                         = "1"
      "controller.resources.requests.memory"                      = "1Gi"
      "controller.resources.limits.cpu"                           = "1"
      "controller.resources.limits.memory"                        = "1Gi"
    }
  }
}

# AWS
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1.2"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "karpenter.sh/discovery" = local.cluster_name
  }

  enable_nat_gateway = true
  single_nat_gateway = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16.0"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  fargate_profiles = {
    default = {
      name = local.fargate_profile.name
      selectors = [
        for namespace in local.fargate_profile.namespaces : {
          namespace = namespace
        }
      ]
    }
  }

  manage_aws_auth_configmap = true
  aws_auth_roles = [
    {
      rolearn  = module.karpenter_aws.role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    }
  ]

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }
}

module "karpenter_aws" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 19.16.0"

  cluster_name = module.eks.cluster_name

  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]
}

resource "aws_iam_service_linked_role" "ec2spot" {
  aws_service_name = "spot.amazonaws.com"
}

# Helm
# ref https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/#4-install-karpenter
# helm registry logout public.ecr.aws
# helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter --create-namespace \
#   --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
#   --set settings.aws.clusterName=${CLUSTER_NAME} \
#   --set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
#   --set settings.aws.interruptionQueueName=${CLUSTER_NAME} \
#   --set controller.resources.requests.cpu=1 \
#   --set controller.resources.requests.memory=1Gi \
#   --set controller.resources.limits.cpu=1 \
#   --set controller.resources.limits.memory=1Gi \
#   --wait

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "v0.30.0"

  dynamic "set" {
    for_each = local.helm_values.karpenter
    content {
      name  = set.key
      value = set.value
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "5.46.7"
}

resource "helm_release" "cluster_bootstrapping" {
  name             = "cluster-bootstrapping"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-apps"
  version          = "1.4.1"

  values = [
    "${file("${path.module}/cluster-bootstrapping-values.yaml")}"
  ]
}
