terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  backend "s3" {
    bucket       = "devops-g1-iac-tfstate"
    key          = "lab/terraform.tfstate"
    region       = "us-east-1"
    profile      = "devops-lab"
    use_lockfile = true # OpenTofu >= 1.10 native S3 locking, no DynamoDB table needed
  }
}
