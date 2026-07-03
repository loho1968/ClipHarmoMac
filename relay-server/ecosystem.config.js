// PM2 进程管理配置
module.exports = {
  apps: [
    {
      name: 'clipboardsync-relay',
      script: 'src/index.js',
      cwd: __dirname,
      instances: 1,
      exec_mode: 'fork',
      watch: false,
      max_memory_restart: '200M',

      // 环境变量
      env: {
        NODE_ENV: 'production',
        RELAY_PORT: '3000',
        RELAY_HOST: '0.0.0.0',
      },

      // 日志
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      error_file: './logs/error.log',
      out_file: './logs/out.log',
      merge_logs: true,

      // 重启策略
      autorestart: true,
      max_restarts: 10,
      min_uptime: '10s',
      restart_delay: 3000,
    },
  ],
}
