locals {
  repository_name = "END-END_project_for_Dev_and_staging"
}

resource "github_repository" "repo_name" {
  name                      = local.repository_name
  description               = " This is a repository in which we will write the code for the end-to-end project. This repository will be used for both development and staging environments."

  description               = "This is a repository in which we will write the code for the end-to-end project. This repository will be used for both development and staging environments."
  visibility                = "public"
  has_issues                = true
  allow_merge_commit        = true
  allow_auto_merge          = true
  delete_branch_on_merge    = false
  vulnerability_alerts      = true

  security_and_analysis {
    secret_scanning {
                     status = "enabled"
    }

    secret_scanning_push_protection {
                     status = "enabled"
    }
  }
}
