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