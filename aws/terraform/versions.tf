terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The API key crash that originally forced 3.76.1 is now worked around
      # (the API key is managed out-of-band via null_resource, see the
      # ingestion_api module), so we can run a modern provider. This also unlocks
      # newer Lambda runtimes (3.76.1's runtime validation caps python at 3.9).
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
