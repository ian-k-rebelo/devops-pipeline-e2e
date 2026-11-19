# Python image: runs the converter of .github/scripts/update-k8s-schemas.sh, which turns the
# CRDs into the JSON schemas that kubeconform reads. This file is never built: the script reads
# the image from the FROM line below. It exists so that Dependabot can propose new Python
# versions (tag and digest), with the cooldown.
# Docker Official Image, pinned by digest. Python 3.14: the newest version with PyYAML wheels
# (tools/python/requirements.txt); moving to a new minor version is a planned change.
FROM python:3.14.10-slim-trixie@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f
