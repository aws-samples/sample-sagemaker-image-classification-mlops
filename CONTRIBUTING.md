# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.


## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The version of our code being used
* Any modifications you've made relevant to the bug
* Anything unusual about your environment or deployment


## Contributing via Pull Requests
Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local checks pass (see [Local checks](#local-checks) below).
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional documentation on [forking a repository](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/fork-a-repo) and
[creating a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request).


## Local checks

This project is Terraform plus Python. Run the local checks before opening a pull request; they
mirror the GitHub Actions workflow in [.github/workflows/ci.yml](.github/workflows/ci.yml), so
catching failures locally saves a review round-trip.

```bash
make fmt validate lint test
```

| Target | What it runs |
| --- | --- |
| `fmt` | `terraform fmt -recursive` and `ruff format .` (rewrites files) |
| `validate` | `terraform init -backend=false` and `terraform validate` in every stack |
| `lint` | `terraform fmt -check`, `ruff check`, `ruff format --check` and `checkov` (uses `.checkov.yaml`) |
| `test` | `pytest` over `tests/` |

Requirements: Terraform `~> 1.15` (pinned in each stack's `versions.tf`), Python `>= 3.13`
(declared in `pyproject.toml`), and `checkov`. `pip install --group dev` (pip 25.1 or later)
installs ruff, pytest and the test dependencies. `validate` needs no credentials or access to the
remote state bucket.

If you edit `scripts/mlops_common/`, run `scripts/sync_mlops_common.sh` to refresh the inference
Lambda's copy; a test fails when the two differ.

If you add or rename a Terraform variable, output, or resource, refresh the generated
documentation tables rather than hand-editing them. Each stack and module README has a
`BEGIN_TF_DOCS` / `END_TF_DOCS` block that is injected from the `.tf` files:

```bash
terraform-docs -c .terraform-docs.yml <directory>
```

Please keep unrelated formatting churn out of the diff. When a change alters cost, IAM
permissions, or the responsible-AI safeguards, call that out explicitly in the pull request
description.


## Finding contributions to work on
Looking at the existing issues is a great way to find something to contribute on. As our projects, by default, use the default GitHub issue labels (enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any 'help wanted' issues is a great place to start.


## Code of Conduct
This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.


## Security issue notifications
If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public github issue.


## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.
