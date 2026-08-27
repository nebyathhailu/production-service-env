provider "aws" {
  region  = "us-east-1"
  profile = "devops-lab-new"

  # New AWS account migration (2026-08). allowed_account_ids is deliberately left EMPTY here —
  # nobody in this session has been given the new account ID, and hardcoding a guessed ID would
  # be worse than no check at all (a wrong ID would hard-fail against the CORRECT account). Fill
  # this in with the real new account ID as the first step of any real apply:
  #   allowed_account_ids = ["<NEW_ACCOUNT_ID>"]
  # Get it via: aws sts get-caller-identity --profile devops-lab-new

  default_tags {
    tags = {
      Project     = "devops-mentorship"
      Group       = "group-1"
      Environment = "lab"
    }
  }
}
