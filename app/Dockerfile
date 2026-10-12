# Base image: official Python, slim variant, fixed versions of Python and Debian
FROM python:3.12.15-slim-trixie

# Python settings for containers: no .pyc files, logs written immediately
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Working directory inside the image
WORKDIR /app

# Install dependencies first, so this layer is cached while only the code changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Unprivileged user to run the application, instead of root
RUN useradd --create-home --uid 10001 appuser

# Application code: changes often, so it is copied last
COPY app.py .

# From here on, run as the unprivileged user (numeric ID)
USER 10001

# Port the application listens on (documentation for whoever runs the image)
EXPOSE 8000

# Start the application with gunicorn, the production server
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--access-logfile", "-", "app:app"]