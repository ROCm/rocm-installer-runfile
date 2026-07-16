# Testing

### Integration Testing

1. The runfile installer is built for the latest release ROCm version for gfx1100 and the latest amdgpu driver on each PR and push into `main` or any branches in the format `release/therock-*`.
2. Everydy at 10AM UTC time, the runfile installer is built for the latest ROCm nightly build on gfx1100 and the latest released amdgpu driver version.