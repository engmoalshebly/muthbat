// OpenWA - PM2 Production Configuration
// Run with: pm2 start ecosystem.config.js --env production

module.exports = {
  apps: [
    {
      name: 'openwa-service',
      script: 'dist/main.js',
      cwd: './',
      instances: 1, // Single instance per host to maintain in-memory WhatsApp Web sessions
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '1500M', // Restart if Chromium/Puppeteer leaks exceed 1.5GB
      restart_delay: 4000,
      max_restarts: 10,
      min_uptime: '10s',
      kill_timeout: 10000, // Allow 10s for graceful shutdown and browser teardown
      listen_timeout: 15000,
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
      error_file: './data/logs/pm2-error.log',
      out_file: './data/logs/pm2-out.log',
      merge_logs: true,
      env: {
        NODE_ENV: 'production',
        PORT: 2785,
        LOG_LEVEL: 'info',
      },
      env_production: {
        NODE_ENV: 'production',
        PORT: 2785,
        LOG_LEVEL: 'info',
      },
    },
  ],
};
