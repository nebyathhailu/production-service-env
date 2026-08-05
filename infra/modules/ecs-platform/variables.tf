variable "name_prefix" {
  type = string
}

variable "namespace_name" {
  description = "Service Connect namespace name, e.g. devops-g1-iac.internal (verified live against the existing environment — see Gate 1 doc §5)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
