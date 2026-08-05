variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "At least two, from modules/network — the assignment requires the ALB to span at least two public subnets"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "ALB must span at least two public subnets (assignment requirement)."
  }
}

variable "service_a_app_port" {
  description = "Service A's (ride-api) container port — the target group forwards here"
  type        = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
