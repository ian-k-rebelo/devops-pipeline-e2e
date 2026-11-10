# ShellCheck image: lints the shell scripts, on their own and inside the workflows (actionlint).
# This file is never built: the scripts read the image from the FROM line below.
# It exists so that Dependabot can propose new ShellCheck versions (tag and digest), with the cooldown.
# ShellCheck publishes no signatures: every pull request that changes it is checked by
# .github/workflows/verify-tools.yml, which compares the binary in the image with the binary of
# the GitHub release (two distribution channels that must agree).
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
