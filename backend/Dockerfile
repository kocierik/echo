FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev gosu libopus0 && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies (with the dev extras, so `make test-all` and `make lint`
# run inside the api container)
COPY pyproject.toml .
RUN pip install --no-cache-dir ".[dev]"

# Voice fingerprint model (WeSpeaker ResNet34, VoxCeleb; ~26 MB), checked against its hash
ARG VOICE_MODEL_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx
ARG VOICE_MODEL_SHA256=e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012
RUN mkdir -p /opt/models && \
    python -c "import hashlib, sys, urllib.request; \
data = urllib.request.urlopen(sys.argv[1], timeout=120).read(); \
assert hashlib.sha256(data).hexdigest() == sys.argv[2], 'voice model hash mismatch'; \
open('/opt/models/voice_embedding.onnx', 'wb').write(data)" "$VOICE_MODEL_URL" "$VOICE_MODEL_SHA256"

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
