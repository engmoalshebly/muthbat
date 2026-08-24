# OpenWA - Dockerfile
# Multi-stage build for production-ready image

# ===== Stage 1: Builder =====
FROM node:22-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy root package files
COPY package*.json ./

# Install backend dependencies
RUN npm ci

# Copy source code
COPY . .

# Build the backend application
RUN npm run build

# Build Dashboard UI if present
RUN if [ -d "dashboard" ]; then \
        cd dashboard && npm ci --legacy-peer-deps && npm run build && cd ..; \
    fi

# Remove development dependencies
RUN npm prune --omit=dev && npm cache clean --force

# ===== Stage 2: Production =====
FROM node:22-slim AS production

# Install Chrome/Chromium and required dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    xdg-utils \
    dumb-init \
    && rm -rf /var/lib/apt/lists/*

# Set Chrome executable path for Puppeteer
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV NODE_ENV=production
ENV PORT=2785

# Create app user for security
RUN groupadd -r openwa && useradd -r -g openwa openwa

WORKDIR /app

# Copy package files
COPY package*.json ./

# Copy built application and node_modules from builder stage
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/dashboard/dist ./dashboard/dist

# Create data directories with proper permissions
RUN mkdir -p ./data/sessions ./data/media ./data/logs ./data/plugins && \
    chown -R openwa:openwa /app

# Expose port
EXPOSE 2785

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD node -e "require('http').get('http://localhost:2785/api/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

# Start with dumb-init to handle signals properly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/main"]

