# Pi Cluster TODOs


## flash_sd.sh: UI cleanup
Polish the interactive flow — specific items TBD.


## manifest versioning
Want to version k8s manifests. Investigate approach — image tags, manifest versioning, or both.

## bump GitHub Actions to Node 24
All service repo build.yml workflows use actions that warn about Node.js 20 deprecation.
Deadline: June 2, 2026. Bump to latest versions of: actions/checkout, actions/create-github-app-token,
docker/build-push-action, docker/login-action, docker/metadata-action, docker/setup-buildx-action, docker/setup-qemu-action.

## health endpoint: show service version
Each service's health endpoint should return its version so it's visible in diagnostics.

