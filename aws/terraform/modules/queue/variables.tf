variable "name_prefix" {
  description = "Prefix applied to queue names."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "max_receive_count" {
  description = "Deliveries attempted before a message is moved to the DLQ."
  type        = number
  default     = 5
}
