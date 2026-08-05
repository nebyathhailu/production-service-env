variable "name_prefix" {
  description = "e.g. \"devops-g1-iac\""
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16" # distinct from the existing default VPC's 172.31.0.0/16 — Gate 1 §2
}

variable "azs" {
  description = "Exactly two Availability Zones, per assignment requirement"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two AZs are required (assignment mandates at least two; this design targets exactly two)."
  }
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
