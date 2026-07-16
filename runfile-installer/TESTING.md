# Testing

### Unit Testing

1. Run static analysis checks on the codebase that checks for formatting and linting errors on each PR and push into `main` or any branch in the format `release/therock-*`.

### Integration Testing

1. The runfile installer is built for the latest ROCm release candidate (https://rocm.prereleases.amd.com/packages-multi-arch/) for gfx1100 and the latest released amdgpu driver on each PR and push into `main` or any branch in the format `release/therock-*`.
2. Every day at 10AM UTC, the runfile installer is built for the latest ROCm nightly build (https://rocm.nightlies.amd.com/packages-multi-arch) on gfx1100 and the latest released amdgpu driver version.
