# Contributing to rocm-installer-runfile

______________________________________________________________________

> **Security vulnerabilities** — do not open a public GitHub Issue. See [SECURITY.md](SECURITY.md) for the private reporting process.

______________________________________________________________________

## Developer policies

These policies apply to all forms of activity and engagement in this project.

> [!IMPORTANT]
> AMD employees must also follow the ROCm open source software
> contributing policies at http://u.amd.com/rocm-oss-policies.

### Governance

This project is covered by the
[ROCm Project Governance](https://github.com/ROCm/TheRock/blob/main/GOVERNANCE.md),
which also defines the code of conduct.

### Licensing

Code contributions to this project are covered under the terms of the
[LICENSE](LICENSE) file.

### Communication channels

Issue tracking, project planning, and code contributions are managed in GitHub.

______________________________________________________________________

## Development workflows

### Issue tracking

Before filing a new issue, search through
[existing issues](https://github.com/ROCm/rocm-installer-runfile/issues) to avoid duplicates.

General guidelines:

- If your issue is already listed, upvote it and add a comment with reproduction details.
- When in doubt, file a new issue — we'll mark duplicates accordingly.
- Provide as much information as possible: command output, GPU model, ROCm version, and
  OS version. This significantly reduces triage time.
- Check your issue regularly — we may ask follow-up questions.

### New feature or test development

Discussion about new features and test areas is welcome via filing a [GitHub issue](https://github.com/ROCm/rocm-installer-runfile/issues)

### Pull Requests

All contributions should be submitted through a Pull Request (PR).

Before submitting a PR:

- Ensure the change addresses an existing issue or documented requirement.
- Run all applicable tests and validate the results.
- Update documentation as needed.
- Ensure all required GitHub Actions checks pass.
- Resolve review feedback before requesting approval.

PRs require:

- Approval from the appropriate CODEOWNERS.
- Successful completion of required status checks which are documented in [TESTING.md](/runfile-installer/TESTING.md)
- Compliance with repository security and quality requirements.

### Branching

- Do not commit directly to protected branches.
- Create a feature branch for all changes.
- Keep changes focused and atomic.
- Rebase or update branches regularly to minimize merge conflicts.

### Commit Messages

- Use clear and descriptive commit messages.

### Testing Practices

Project testing practices are documented in [TESTING.md](/runfile-installer/TESTING.md).

### Documentation

Changes that impact functionality, configuration, APIs, or user workflows should include corresponding documentation updates.

### Security Requirements

Contributors must not:

- Commit secrets, tokens, passwords, or credentials.
- Introduce vulnerable dependencies without justification.
- Bypass security controls or required security reviews.

All contributions may be subject to automated security scanning.
