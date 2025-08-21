import os
import sys
from fastapi.testclient import TestClient

sys.path.insert(0, '.')
import src.llm20_service as svc  # noqa: E402

class MockLlama:
    def __init__(self, *args, **kwargs):
        pass
    def __call__(self, prompt, **kwargs):
        return {"choices": [{"text": f"MOCK_REPLY:{prompt}"}]}

def test_gen_mock():
    # Force mock LLM regardless of local environment
    svc.LLM = MockLlama()
    client = TestClient(svc.app)
    r = client.post('/gen', json={'prompt': 'test prompt'})
    assert r.status_code == 200
    data = r.json()
    assert 'text' in data
    assert 'MOCK_REPLY:' in data['text']
