FROM python:3.14-slim

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN pip install uv

# Copy only pyproject.toml first (cache layer)
COPY pyproject.toml uv.lock* ./
RUN uv sync --frozen --no-install-project

# Copy source code
COPY . .

# Generate Fernet key on first run if missing
RUN python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" > /tmp/fernet_key 2>/dev/null || true

EXPOSE 8000

CMD ["uvicorn", "mcp_server.server:app", "--host", "0.0.0.0", "--port", "8000"]
