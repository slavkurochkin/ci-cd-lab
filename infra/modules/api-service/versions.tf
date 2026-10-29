terraform {
  required_version = ">= 1.7" # mock_provider in tests/

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 7.0"
    }
  }
}
