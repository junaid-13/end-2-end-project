locals {
  repository_name     = "END-END_project_for_Dev_and_staging"
  default_branch_name = "main"
}

resource "github_repository" "repo_name" {
  name                      = local.repository_name
  description               = " This is a repository in which we will write the code for the end-to-end project. This repository will be used for both development and staging environments."
  visibility                = "private"
  has_issues                = true
  allow_merge_commit        = true
  allow_auto_merge          = true
  delete_branch_on_merge    = false
  vulnerability_alerts      = true
  has_projects              = false

  security_and_analysis {
    secret_scanning {
                     status = "enabled"
    }

    secret_scanning_push_protection {
                     status = "enabled"
    }
  }
}

resource "github_repository_file" "readme_file" {
  repository           = github_repository.repo_name.name
  file                 = "README.md"
  content              = "This is the README file for the END-END_project_for_Dev_and_staging"
}

resource "github_branch" "default_branch" {
  repository            = github_repository.repo_name.name
  branch                = local.default_branch_name
}