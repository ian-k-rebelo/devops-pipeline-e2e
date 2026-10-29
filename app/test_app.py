from app import app

# The main page responds successfully
def test_index():
    client = app.test_client()
    response = client.get("/")
    assert response.status_code == 200

# The health endpoint responds successfully with the expected body
def test_health():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


# The main page body ends with a newline, so command-line clients print it on its own line
def test_index_body_ends_with_newline():
    client = app.test_client()
    response = client.get("/")
    assert response.get_data(as_text=True) == "Hello from devops-pipeline-e2e!\n"
