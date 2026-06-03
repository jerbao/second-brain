FROM python:3.14-slim

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN pip install uv

# Copy dependency files first to leverage Docker layer cache
COPY pyproject.toml uv.lock* ./
RUN uv sync --frozen --no-install-project

# Copy application source
COPY . .

# FERNET_KEY is supplied at runtime via the .env file (see .env.example).
# It is NOT generated here on purpose: a key baked into the image is a leaked
# secret, and a freshly generated key per build would invalidate data encrypted
# by the previous build. Users generate their own key once with:
#   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

EXPOSE 8000

CMD ["uvicorn", "mcp_server.server:app", "--host", "0.0.0.0", "--port", "8000"]
