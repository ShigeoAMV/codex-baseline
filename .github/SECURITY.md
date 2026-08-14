# Security policy

## Supported versions

The latest `0.1.x` public preview on the default branch receives security
fixes. Older commits and unverified forks are not supported release channels.

## Report a vulnerability

Use GitHub's private vulnerability reporting flow under **Security** ->
**Report a vulnerability**. Do not open a public issue for a suspected secret
exposure, path escape, credential leak, unsafe recovery, or sandbox boundary
failure.

Include the affected commit, platform, Codex version, reproduction steps,
expected and observed behavior, and whether any real credential or external
system was involved. Use synthetic credentials whenever possible and do not
attach live authentication or session files.

The maintainer will acknowledge a complete report through GitHub, assess its
severity and affected versions, and coordinate disclosure after a fix or safe
mitigation exists. No response-time SLA is promised for this preview.

## Provenance boundary

The repository is Apache-2.0 licensed, but v0.1.0 remains an unsigned public
source preview. Payload manifests and SHA-256 digests prove checkout integrity
relative to tracked metadata; they do not authenticate the publisher. Follow
[`docs/RELEASE.md`](../docs/RELEASE.md) for the exact trust boundary.
