# Base image: official Python, slim variant, fixed versions of Python and Debian;
# pinned by digest, so it only changes through a reviewed pull request (Dependabot,
# or a manual security update when a critical fix cannot wait for the cooldown)
FROM python:3.12.16-slim-trixie@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b

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

# Python settings for containers: no .pyc files, logs written immediately
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Working directory inside the image
WORKDIR /app

# Unprivileged user to run the application, instead of root
RUN useradd --create-home --uid 10001 appuser

# Install dependencies first, so this layer is cached while only the code changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code: changes often, so it is copied last
COPY app.py .

# From here on, run as the unprivileged user (numeric ID)
USER 10001

# Port the application listens on (documentation for whoever runs the image)
EXPOSE 8000

# Start the application with gunicorn, the production server
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--access-logfile", "-", "app:app"]
