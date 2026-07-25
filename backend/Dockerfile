FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY pyproject.toml .
RUN pip install --no-cache-dir .

# Copy application code
COPY . .

# Create audio storage directory and non-root user
RUN mkdir -p /data/audio && \
    groupadd -r echo && \
    useradd -r -g echo -d /app -s /sbin/nologin echo && \
    chown -R echo:echo /app /data/audio

# Run as non-root
USER echo

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
