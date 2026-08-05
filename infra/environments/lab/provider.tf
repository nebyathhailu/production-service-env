provider "aws" {
  region  = "us-east-1"
  profile = "devops-lab"

  allowed_account_ids = ["827478161993"] # hard-fail if the wrong AWS identity is ever picked up

  default_tags {
    tags = {
      Project     = "devops-mentorship"
      Group       = "group-1"
      Environment = "lab"
    }
  }
}
