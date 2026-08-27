# One-time setup. Applied with LOCAL state, deliberately outside the remote backend this
# creates (bootstrapping the backend that would store its own state is a chicken-and-egg
# problem — see docs/terraform-gate1-design.md §7).
#
# This bucket must be globally unique across all of AWS, not just this account — check before
# apply with: aws s3api head-bucket --bucket devops-g1-iac-tfstate-new 2>&1
# If that returns anything other than "Not Found" / 404, pick a different name and update here
# AND in every environments/lab backend config that references it.

resource "aws_s3_bucket" "tfstate" {
  bucket = "devops-g1-iac-tfstate-new"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 — no extra IAM/KMS setup, no compliance need for CMK here
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
