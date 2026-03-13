# Contributing to SixWays Sandbox

SixWays Sandbox provides hardened container images for secure AI agent execution. We welcome contributions that strengthen security, expand image variants, and keep base images current.

## Table of Contents

- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Commit Conventions](#commit-conventions)
- [License](#license)

---

## How to Contribute

We accept contributions in the following areas:

- **Security Hardening**: Reduce attack surface, tighten permissions, remove unnecessary packages
- **New Image Variants**: Add Dockerfile variants for additional runtimes or toolchains
- **Base Image Updates**: Keep base images current with upstream security patches
- **Documentation**: Improve build guides, security rationale docs, and inline comments

---

## Development Setup

Ensure you have Docker installed.

```bash
git clone https://github.com/sixways-ai/sixways-sandbox.git
cd sixways-sandbox
docker build -t sixways-sandbox .
```

For full development environment setup, see [docs/development.md](docs/development.md).

---

## Code Style

Follow Dockerfile best practices:

- **Minimal layers**: Combine related `RUN` commands to reduce image size
- **No sudo**: Do not install or use `sudo` inside the container
- **Non-root user**: All containers must run as a non-root user by default
- **Pinned versions**: Pin base image tags and package versions for reproducibility
- **Ordered instructions**: Place least-frequently-changed instructions first for better layer caching
- **No privilege escalation tools**: Do not include `su`, `sudo`, `doas`, or similar utilities

---

## Testing

Build the image and verify core functionality:

```bash
# Build the image
docker build -t sixways-sandbox:test .

# Verify SSH connectivity
docker run -d --name sandbox-test sixways-sandbox:test
docker exec sandbox-test ssh -V

# Verify no privilege escalation tools are present
docker exec sandbox-test which sudo && echo "FAIL: sudo found" || echo "PASS"
docker exec sandbox-test which su && echo "FAIL: su found" || echo "PASS"

# Verify non-root user
docker exec sandbox-test whoami  # Should not be root

# Clean up
docker rm -f sandbox-test
```

Ensure all verification steps pass before submitting a pull request.

---

## Pull Request Process

1. **Single Responsibility**: Each PR should address one logical change
2. **CI Passing**: All GitHub Actions checks must pass (build, security scan)
3. **Description**: Provide a clear explanation of the change and its security rationale
4. **Approval**: Requires 1 approval from a maintainer
5. **Merge**: Squash and merge to maintain clean history

### Review Criteria

- No introduction of privilege escalation vectors
- Image size is kept minimal
- Base images are from trusted sources
- Security hardening rationale is documented

---

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/) style:

```
feat: add Node.js 22 sandbox variant
fix: remove setuid binaries from base image
docs: document network isolation configuration
chore: update base image to debian:bookworm-slim
refactor: consolidate common layers into base stage
```

Keep the subject line under 72 characters. Use the body for additional context when needed.

---

## License

By contributing to SixWays Sandbox, you agree that your contributions will be licensed under the Apache License 2.0.

For details, see [LICENSE](LICENSE).

---

## Questions and Support

- **Bug Reports**: Open a GitHub Issue
- **General Questions**: Open a GitHub Discussion
- **Security Concerns**: Email security@sixways.ai

Thank you for contributing to SixWays Sandbox.
