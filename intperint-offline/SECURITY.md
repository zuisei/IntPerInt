# Security guidance for intperint-offline

- This stack is designed for fully offline local operation.
- Logs: written under `logs/` only; avoid sensitive data in prompts.
- NSFW/illegal content: comply with local laws and model licenses; this repo provides no filters by default.
- Licensing: ensure all models and wheels you place locally are licensed for your use.
- Networking: only localhost ports are used; no outbound connections are performed by code.
