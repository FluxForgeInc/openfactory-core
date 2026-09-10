terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state for the first proof. Move to an S3 backend (+ DynamoDB lock) before
  # this is shared/CI-run — tracked as a follow-up.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "openfactory"
      ManagedBy = "terraform"
      Component = "fargate-sandbox"
    }
  }
}
