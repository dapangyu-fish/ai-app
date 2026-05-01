import requests
import json
import sseclient

def test():
    headers = {
        "Content-Type": "application/json",
        # Use an existing user token or bypass auth?
        # Actually I can't easily bypass auth without a token.
        # Let's see if auth is required.
    }
    # For local test, we can use the test-token if it exists, but the user is using `require_auth`
