provider "aws" {
  region  = "us-east-1"
  profile = "devops-lab-new"

  # Shared team account (AkiraChix). Confirmed:
  # aws sts get-caller-identity --profile devops-lab-new  →  240462142849
  allowed_account_ids = ["240462142849"]

  default_tags {
    tags = {
      Project     = "devops-mentorship"
      Group       = "group-1"
      Owner       = "platform-owner"
      Environment = "lab"
    }
  }
}
