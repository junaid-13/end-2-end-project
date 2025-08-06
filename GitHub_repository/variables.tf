variable "github_token" {
  description = "The value for the GitHub Token used to authenticate with the GitHub."
  type = string
  sensitive = true
}

variable "github_owner" {
    description = "The GitHub owner for creating the repository in github account."
    type = string
    default = "junaid-13"
}

