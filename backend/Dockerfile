FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev gosu && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies (with the dev extras, so `make test-all` and `make lint`
# run inside the api container)
COPY pyproject.toml .
RUN pip install --no-cache-dir ".[dev]"

# Copy application code
COPY . .

# Create non-root user and audio directory
RUN groupadd -r echo && \
    useradd -r -g echo -d /app -s /sbin/nologin echo && \
    chown -R echo:echo /app && \
    mkdir -p /data/audio && chown -R echo:echo /data/audio

# Entrypoint fixes volume permissions then drops to non-root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
