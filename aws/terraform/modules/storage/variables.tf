variable "name_prefix" {
  description = "Prefix applied to the table and bucket names."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
