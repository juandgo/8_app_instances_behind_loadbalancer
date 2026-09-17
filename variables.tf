variable "aws_region" {
  type        = string
  description = "AWS Region where resources are deployed"
  default     = "eu-west-1"
}

variable "project_prefix" {
  type        = string
  description = "Project resource prefix name"
}

variable "tags" {
  type        = map(string)
  description = "Default tags to apply to all resources"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the Launch Template"
}