terraform {
  required_version = ">= 1.11" # write-only arguments + ephemeral resources keep the DB password out of state
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.primary_region
  default_tags { tags = local.tags }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags { tags = local.tags }
}

# CloudFront-scoped WAF and its logs must live in us-east-1.
provider "aws" {
  alias  = "edge"
  region = "us-east-1"
  default_tags { tags = local.tags }
}
