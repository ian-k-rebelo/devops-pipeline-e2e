# Base image: official Python, slim variant, fixed versions of Python and Debian;
# pinned by digest, so it only changes through a reviewed pull request (Dependabot,
# or a manual security update when a critical fix cannot wait for the cooldown)
# Declared once: the build stage and the final image both start from it
FROM python:3.12.16-slim-trixie@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b AS base

# Build stage: installs the libraries into a virtual environment, /opt/venv. This stage is not
# published: the final image gets only /opt/venv from it
FROM base AS build

# A virtual environment without pip: it only gets the packages of requirements.txt, installed
# into it by the pip of the base image (--python)
RUN python -m venv --without-pip /opt/venv

# requirements.txt is written by pip-compile (requirements.in): each file must match one of the
# hashes of its package (--require-hashes), and only wheels are installed (--only-binary=:all:):
# a package built from its source would run build tools that are not pinned
COPY requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install --no-cache-dir --disable-pip-version-check \
      --require-hashes --only-binary=:all: -r /tmp/requirements.txt

# Final image: the one that is published and runs
FROM base

# Temporary security fix (issue #45): libzstd1 from trixie-security (DSA-6657-1, CVE-2026-124851),
# until the base image has it. The step fails the build when the base image already has this
# version or a newer one: then remove it, in the pull request that updates the base image
RUN installed="$(dpkg-query --show --showformat="\${Version}" libzstd1)" \
 && if dpkg --compare-versions "${installed}" ge 1.5.7+dfsg-1+deb13u1; then \
      echo "libzstd1 ${installed} is already in the base image: remove this step" >&2; exit 1; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends libzstd1=1.5.7+dfsg-1+deb13u1 \
 && rm -rf /var/lib/apt/lists/*

# pip is only needed to install packages, in the build stage: it is removed from the final image,
# so it is not scanned, not updated, and cannot install anything while the app runs
RUN python -m pip uninstall --yes --no-input pip

# Python settings for containers: no .pyc files, logs written immediately; the programs of the
# virtual environment (gunicorn) come first in the PATH
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}"

# Working directory inside the image
WORKDIR /app

# Unprivileged user to run the application, instead of root
RUN useradd --create-home --uid 10001 appuser

# The libraries, from the build stage, then the application code, which changes most often
COPY --from=build /opt/venv /opt/venv
COPY app.py .

# From here on, run as the unprivileged user (numeric ID)
USER 10001

# Port the application listens on (documentation for whoever runs the image)
EXPOSE 8000

# Start the application with gunicorn, the production server. Without its control socket, a Unix
# socket for commands such as reload: Kubernetes changes the Pod through its Deployment instead
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--no-control-socket", \
     "--access-logfile", "-", "app:app"]
