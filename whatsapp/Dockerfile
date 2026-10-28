# Echo's WhatsApp bridge (docs/superpowers/specs/2026-10-28-whatsapp-design.md)
FROM node:22-alpine
WORKDIR /app
# Only for building behind a TLS-inspecting proxy (empty otherwise)
ARG NODE_EXTRA_CA_CERTS
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src
# The volume takes this owner when it is first created
RUN mkdir -p /data && chown node:node /data
ENV NODE_ENV=production DATA_DIR=/data PORT=3100
USER node
CMD ["node", "src/main.js"]
