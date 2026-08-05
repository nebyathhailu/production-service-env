variable "name_prefix" {
  type = string
}

variable "namespace_name" {
  description = "Service Connect namespace name, e.g. devops-g1-iac.internal (Gate 1 §5 — verified live, no collision with existing group1.internal)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
