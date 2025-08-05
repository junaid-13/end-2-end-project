terraform {
  required_providers {
    github = {
        source = "integrations/github"
    }
  }
  required_version = ">= 5.9.0"
}

provider "github" {
    token = var.github_token
    owner = var.github_owner
}