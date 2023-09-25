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
    name       = "default"
    namespaces = ["kube-system", "default"]
  }
}

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
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Name = local.vpc_name
  }
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
      rolearn  = module.karpenter.role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    }
  ]

  tags = {
    Name = local.cluster_name
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 19.16.0"

  cluster_name = module.eks.cluster_name

  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]
}
