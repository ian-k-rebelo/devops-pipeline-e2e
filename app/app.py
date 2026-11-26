from flask import Flask

app = Flask(__name__)

# Main page
@app.route("/")
def index():
    return "Hello from devops-pipeline-e2e!\n"

# Health check endpoint, used by Kubernetes probes
@app.route("/health")
def health():
    return {"status": "ok"}

# NEGATIVE TEST of CodeQL, in a pull request that is never merged: a shell command built from
# user input (command injection). CodeQL must report it, and the ruleset must block the merge
@app.route("/ping")
def ping():
    import subprocess
    from flask import request
    host = request.args.get("host", "localhost")
    return subprocess.run(f"ping -c 1 {host}", shell=True, capture_output=True, text=True).stdout
