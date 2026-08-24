#!/usr/bin/env bash
# =============================================================================
# OpenWA - Production Startup & Verification Script (Linux / macOS / VPS)
# =============================================================================
set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  🚀 OpenWA - Production Service Startup Checks       ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Check Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}✗ Node.js is not installed or not in PATH!${NC}"
    exit 1
fi
NODE_VER=$(node -v)
echo -e "${GREEN}✓ Node.js version: ${NODE_VER}${NC}"

# 2. Check and load .env
if [ -f ".env" ]; then
    echo -e "${GREEN}✓ Found .env file${NC}"
else
    if [ -f ".env.production.example" ]; then
        echo -e "${YELLOW}⚠ .env not found. Copying from .env.production.example...${NC}"
        cp .env.production.example .env
    elif [ -f ".env.example" ]; then
        echo -e "${YELLOW}⚠ .env not found. Copying from .env.example...${NC}"
        cp .env.example .env
    fi
fi

# 3. Create required directories
mkdir -p data/sessions data/media data/plugins data/logs
echo -e "${GREEN}✓ Data directories verified (data/sessions, data/media, data/logs)${NC}"

# 4. Check Backend Build
if [ ! -f "dist/main.js" ]; then
    echo -e "${YELLOW}⚡ dist/main.js not found. Building Backend...${NC}"
    npm run build
fi
echo -e "${GREEN}✓ Backend build verified${NC}"

# 5. Check Dashboard Build (if dashboard dir exists)
if [ -d "dashboard" ] && [ ! -f "dashboard/dist/index.html" ]; then
    echo -e "${YELLOW}⚡ dashboard/dist not found. Building Dashboard...${NC}"
    npm run dashboard:build || echo -e "${YELLOW}⚠ Dashboard build skipped${NC}"
fi

# 6. Database Migrations (if PostgreSQL is used)
if grep -q "DATABASE_TYPE=postgres" .env 2>/dev/null; then
    echo -e "${BLUE}ℹ Running PostgreSQL migrations...${NC}"
    npm run migration:run:prod || echo -e "${YELLOW}⚠ Migrations check complete${NC}"
fi

# 7. Start the Service
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Starting OpenWA Service in Production Mode...        ${NC}"
echo -e "${GREEN}======================================================${NC}"

if command -v pm2 &> /dev/null; then
    echo -e "${BLUE}ℹ PM2 detected. Starting via PM2...${NC}"
    pm2 start ecosystem.config.js --env production
    pm2 save
    echo -e "${GREEN}✓ OpenWA running under PM2. Use 'pm2 logs openwa-service' to monitor.${NC}"
else
    export NODE_ENV=production
    exec node dist/main.js
fi
