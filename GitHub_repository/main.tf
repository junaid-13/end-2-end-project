locals {
  repository_name = "END-END project for Dev and staging"
}

resource "github_repository" "repo_name" {
  name = local.repository_name
  description = <<EOF
                        This is a repository in which we will write the code for the end-to-end project.
                        This repository will be used for both development and staging environments.
                    EOF
}

resource "github_branch_default" "main_branch" {
  repository = github_repository.repo_name.name
  branch     = "main"
}