from flask import Flask

app = Flask(__name__)

# Main page
@app.route("/")
def index():
    return "Hello from devops-pipeline-e2e!"

# Health check endpoint, used by Kubernetes probes
@app.route("/health")
def health():
    return {"status": "ok"}