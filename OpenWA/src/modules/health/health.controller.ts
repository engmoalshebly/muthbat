import { Controller, Get, HttpStatus, Optional, Res } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { ConfigService } from '@nestjs/config';
import type { Response } from 'express';
import { Public } from '../auth/decorators/auth.decorators';

export interface HealthCheckResult {
  status: 'ok' | 'error';
  timestamp: string;
  uptime: number;
  memory: {
    rssMb: number;
    heapUsedMb: number;
    heapTotalMb: number;
  };
  details: {
    mainDatabase: { status: 'up' | 'down'; error?: string };
    dataDatabase: { status: 'up' | 'down'; type?: string; error?: string };
    redis?: { status: 'up' | 'down' | 'disabled'; error?: string };
  };
}

@ApiTags('health')
@Controller('health')
@Public()
export class HealthController {
  constructor(
    @Optional()
    @InjectDataSource('main')
    private readonly mainDataSource?: DataSource,
    @Optional()
    @InjectDataSource('data')
    private readonly dataDataSource?: DataSource,
    @Optional()
    private readonly configService?: ConfigService,
  ) {}

  @Get()
  @ApiOperation({ summary: 'Basic health check' })
  @ApiResponse({ status: 200, description: 'Application is healthy' })
  check(): { status: string; version: string; uptime: number; timestamp: string } {
    return {
      status: 'ok',
      version: '0.1.6',
      uptime: Math.floor(process.uptime()),
      timestamp: new Date().toISOString(),
    };
  }

  @Get('live')
  @ApiOperation({ summary: 'Liveness probe for Kubernetes / Docker' })
  @ApiResponse({ status: 200, description: 'Application is alive' })
  liveness(): { status: string } {
    return { status: 'ok' };
  }

  @Get('ready')
  @ApiOperation({ summary: 'Readiness probe for Kubernetes / Load Balancers' })
  @ApiResponse({
    status: 200,
    description: 'Application is ready to accept traffic',
  })
  @ApiResponse({
    status: 503,
    description: 'Application dependencies are down',
  })
  async readiness(@Res({ passthrough: true }) res?: Response): Promise<HealthCheckResult> {
    const mem = process.memoryUsage();
    let isHealthy = true;

    // Check main DB
    let mainDbStatus: 'up' | 'down' = 'up';
    let mainDbError: string | undefined;
    if (this.mainDataSource) {
      try {
        if (!this.mainDataSource.isInitialized) {
          throw new Error('Main DataSource is not initialized');
        }
        await this.mainDataSource.query('SELECT 1');
      } catch (err) {
        mainDbStatus = 'down';
        mainDbError = err instanceof Error ? err.message : String(err);
        isHealthy = false;
      }
    }

    // Check data DB
    let dataDbStatus: 'up' | 'down' = 'up';
    let dataDbError: string | undefined;
    const dbType = this.configService?.get<string>('dataDatabase.type', 'sqlite') || 'sqlite';
    if (this.dataDataSource) {
      try {
        if (!this.dataDataSource.isInitialized) {
          throw new Error('Data DataSource is not initialized');
        }
        await this.dataDataSource.query('SELECT 1');
      } catch (err) {
        dataDbStatus = 'down';
        dataDbError = err instanceof Error ? err.message : String(err);
        isHealthy = false;
      }
    }

    const redisEnabled = this.configService?.get<boolean>('redis.enabled', false) ?? false;

    const result: HealthCheckResult = {
      status: isHealthy ? 'ok' : 'error',
      timestamp: new Date().toISOString(),
      uptime: Math.floor(process.uptime()),
      memory: {
        rssMb: Math.round(mem.rss / 1024 / 1024),
        heapUsedMb: Math.round(mem.heapUsed / 1024 / 1024),
        heapTotalMb: Math.round(mem.heapTotal / 1024 / 1024),
      },
      details: {
        mainDatabase: { status: mainDbStatus, ...(mainDbError && { error: mainDbError }) },
        dataDatabase: { status: dataDbStatus, type: dbType, ...(dataDbError && { error: dataDbError }) },
        ...(redisEnabled && { redis: { status: 'up' } }),
      },
    };

    if (!isHealthy && res) {
      res.status(HttpStatus.SERVICE_UNAVAILABLE);
    }

    return result;
  }
}

