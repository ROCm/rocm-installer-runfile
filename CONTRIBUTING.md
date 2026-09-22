# Contributing to rocm-repo-template

We are enthusiastic about contributions to our code and documentation. Please
feel free to file issues where documentation or functionality is lacking or,
even better, volunteer to contribute to help close these gaps!

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
We use an open-source toolchain so that workflows can be easily replicated in any fork.

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

### Code style

Follow the [ROCm/TheRock style guides](https://github.com/ROCm/TheRock/tree/main/docs/development/style_guides):

- [Bash style guide](https://github.com/ROCm/TheRock/blob/main/docs/development/style_guides/bash_style_guide.md)
- [CMake style guide](https://github.com/ROCm/TheRock/blob/main/docs/development/style_guides/cmake_style_guide.md)
- [GitHub Actions style guide](https://github.com/ROCm/TheRock/blob/main/docs/development/style_guides/github_actions_style_guide.md)
- [Python style guide](https://github.com/ROCm/TheRock/blob/main/docs/development/style_guides/python_style_guide.md)

### New feature or test development

Discussion about new features and test areas is welcome via:

- Filing a [GitHub issue](https://github.com/ROCm/rocm-installer-runfile/issues)

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
- Successful completion of required status checks.
- Compliance with repository security and quality requirements.

### Branching

- Do not commit directly to protected branches.
- Create a feature branch for all changes.
- Keep changes focused and atomic.
- Rebase or update branches regularly to minimize merge conflicts.

### Commit Messages

- Use clear and descriptive commit messages.

### Testing

Contributors are expected to:

- Execute relevant unit and integration tests.
- Verify that existing functionality is not impacted.
- Include test coverage for new functionality when applicable.
- Document any known limitations or test exclusions.

#### Running unit tests

Unit tests for the UI source live in `runfile-installer/tests/` and use the [cmocka](https://cmocka.org/) framework. The test project builds independently from the production binary.

**Requirements:** `libcmocka-dev` (apt) / `libcmocka-devel` (dnf/zypper)

```bash
cd runfile-installer/tests
cmake -B build -DCMAKE_BUILD_TYPE=Debug .
cmake --build build
ctest --test-dir build --output-on-failure
```

After the initial configure step, only the build and test commands are needed for subsequent runs.


#### Formatting using pre-commit hooks

We enforce formatting for certain languages using
[_pre-commit_](https://pre-commit.com/) with hooks defined in
[`.pre-commit-config.yaml`](/.pre-commit-config.yaml).

To get started with pre-commit:

```bash
# Install Python (only tested this with python 3.12.11)
# Create venv folder
python3 -m venv venv

source venv/bin/activate

# Download.
pip install pre-commit

# Run locally on staged files.
pre-commit run

# Run locally on all files.
pre-commit run --all-files

# (Optional but recommended)
# Install git hook. Now pre-commit runs on every git commit.
pre-commit install
```

#### CodeQL Analysis

Runs Github's CodeQL tool to analyse the C code in `runfile-installer/UI/src`.

```shell
cd runfile-installer/tests/codeql-test
bash run-codeql-analysis.sh --config configs/rocm-ui.conf
```

### Documentation

Changes that impact functionality, configuration, APIs, or user workflows should include corresponding documentation updates.

### Security Requirements

Contributors must not:

- Commit secrets, tokens, passwords, or credentials.
- Introduce vulnerable dependencies without justification.
- Bypass security controls or required security reviews.

All contributions may be subject to automated security scanning.

