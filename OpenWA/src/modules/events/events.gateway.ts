import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayInit,
  OnGatewayConnection,
  OnGatewayDisconnect,
  SubscribeMessage,
  MessageBody,
  ConnectedSocket,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AuthService } from '../auth/auth.service';
import type {
  WSClientMessage,
  WSSubscribeRequest,
  WSUnsubscribeRequest,
  WSSubscribedResponse,
  WSUnsubscribedResponse,
  WSEventMessage,
  WSErrorResponse,
  WSPongResponse,
} from './dto/ws-messages.dto';
import { SUBSCRIBABLE_EVENTS, buildRoomName } from './dto/ws-messages.dto';

const MAX_CONNECTIONS_PER_IP = 10;
const CONNECTION_WINDOW_MS = 60_000;

@WebSocketGateway({
  namespace: '/events',
})
export class EventsGateway implements OnGatewayInit, OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private logger = new Logger('EventsGateway');
  private connectionTracker = new Map<string, number[]>();

  constructor(
    private readonly authService: AuthService,
    private readonly configService: ConfigService,
  ) {}

  afterInit(server: Server) {
    const rawOrigins = this.configService.get<string>('CORS_ORIGINS', 'http://localhost:2886');
    const origins = rawOrigins === '*' ? true : rawOrigins.split(',').map(o => o.trim());
    server.engine.opts.cors = {
      origin: origins,
      credentials: true,
    };
    this.logger.log('WebSocket Gateway initialized');
  }

  async handleConnection(client: Socket) {
    const ip = client.handshake.address;

    if (!this.checkRateLimit(ip)) {
      this.logger.warn(`Client ${client.id} rejected: too many connections from ${ip}`);
      client.emit('message', this.createError('RATE_LIMITED', 'Too many connections'));
      client.disconnect();
      return;
    }

    // Extract API key from header or query param
    const apiKey = (client.handshake.headers['x-api-key'] as string) || (client.handshake.query.apiKey as string);

    if (!apiKey) {
      this.logger.warn(`Client ${client.id} rejected: No API key provided`);
      client.emit('message', this.createError('UNAUTHORIZED', 'API key required'));
      client.disconnect();
      return;
    }

    try {
      const validKey = await this.authService.validateApiKey(apiKey);
      if (!validKey) {
        this.logger.warn(`Client ${client.id} rejected: Invalid API key`);
        client.emit('message', this.createError('UNAUTHORIZED', 'Invalid API key'));
        client.disconnect();
        return;
      }

      // Store API key info on socket for later use
      (client.data as { apiKey: unknown }).apiKey = validKey;
      this.logger.log(`Client connected: ${client.id} (key: ${validKey.name})`);
    } catch (error) {
      this.logger.warn(`Client ${client.id} rejected: Auth error`, {
        error: error instanceof Error ? error.message : String(error),
      });
      client.emit('message', this.createError('UNAUTHORIZED', 'Authentication failed'));
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Client disconnected: ${client.id}`);
  }

  @SubscribeMessage('message')
  handleMessage(@ConnectedSocket() client: Socket, @MessageBody() message: WSClientMessage) {
    switch (message.type) {
      case 'subscribe':
        return this.handleSubscribe(client, message);
      case 'unsubscribe':
        return this.handleUnsubscribe(client, message);
      case 'ping':
        return this.handlePing(client, message.requestId);
      default:
        return this.createError(
          'INVALID_MESSAGE',
          `Unknown message type`,
          (message as { requestId?: string }).requestId,
        );
    }
  }

  private checkRateLimit(ip: string): boolean {
    const now = Date.now();
    const timestamps = this.connectionTracker.get(ip) || [];
    const recent = timestamps.filter(t => now - t < CONNECTION_WINDOW_MS);
    if (recent.length >= MAX_CONNECTIONS_PER_IP) {
      return false;
    }
    recent.push(now);
    this.connectionTracker.set(ip, recent);
    return true;
  }

  private handleSubscribe(client: Socket, message: WSSubscribeRequest): WSSubscribedResponse | WSErrorResponse {
    const { sessionId, events, requestId } = message;

    // Validate sessionId
    if (!sessionId || typeof sessionId !== 'string') {
      return this.createError('INVALID_SESSION', 'sessionId is required', requestId);
    }

    // Validate events
    if (!events || !Array.isArray(events) || events.length === 0) {
      return this.createError('INVALID_EVENTS', 'events array is required', requestId);
    }

    // Validate each event type
    const validEvents = events.filter(
      e => e === '*' || SUBSCRIBABLE_EVENTS.includes(e as (typeof SUBSCRIBABLE_EVENTS)[number]),
    );
    if (validEvents.length === 0) {
      return this.createError(
        'INVALID_EVENTS',
        `No valid events. Valid: ${SUBSCRIBABLE_EVENTS.join(', ')}, *`,
        requestId,
      );
    }

    // Join rooms for each session/event combination
    const rooms: string[] = [];
    for (const event of validEvents) {
      const room = buildRoomName(sessionId, event);
      void client.join(room);
      rooms.push(room);
    }

    this.logger.debug(`Client ${client.id} subscribed to: ${rooms.join(', ')}`);

    return {
      type: 'subscribed',
      sessionId,
      events: validEvents,
      requestId,
      timestamp: new Date().toISOString(),
    };
  }

  private handleUnsubscribe(client: Socket, message: WSUnsubscribeRequest): WSUnsubscribedResponse {
    const { sessionId, requestId } = message;

    // Leave all rooms for this session
    const clientRooms = Array.from(client.rooms);
    const sessionPrefix = `session:${sessionId}:`;

    for (const room of clientRooms) {
      if (room.startsWith(sessionPrefix) || (sessionId === '*' && room.startsWith('session:'))) {
        void client.leave(room);
      }
    }

    this.logger.debug(`Client ${client.id} unsubscribed from session: ${sessionId}`);

    return {
      type: 'unsubscribed',
      sessionId,
      requestId,
      timestamp: new Date().toISOString(),
    };
  }

  private handlePing(_client: Socket, requestId?: string): WSPongResponse {
    return {
      type: 'pong',
      requestId,
      timestamp: new Date().toISOString(),
    };
  }

  private createError(code: string, message: string, requestId?: string): WSErrorResponse {
    return {
      type: 'error',
      code,
      message,
      requestId,
      timestamp: new Date().toISOString(),
    };
  }

  // ========== Event Emission Methods (room-based) ==========

  /**
   * Emit event to specific rooms based on sessionId and event type
   */
  private emitToRooms(sessionId: string, event: string, data: unknown): void {
    const eventMessage: WSEventMessage = {
      type: 'event',
      payload: { event, sessionId, data },
      timestamp: new Date().toISOString(),
    };

    // Emit to specific session + event room
    this.server.to(buildRoomName(sessionId, event)).emit('message', eventMessage);

    // Emit to wildcard rooms
    this.server.to(buildRoomName(sessionId, '*')).emit('message', eventMessage);
    this.server.to(buildRoomName('*', event)).emit('message', eventMessage);
    this.server.to(buildRoomName('*', '*')).emit('message', eventMessage);
  }

  /**
   * Emit session status change
   */
  emitSessionStatus(sessionId: string, status: string, data?: Record<string, unknown>) {
    this.emitToRooms(sessionId, 'session.status', { status, ...data });
  }

  /**
   * Emit QR code update for a session
   */
  emitQRCode(sessionId: string, qrCode: string) {
    this.emitToRooms(sessionId, 'session.qr', { qrCode });
  }

  /**
   * Emit new message notification
   */
  emitMessage(sessionId: string, message: Record<string, unknown>) {
    this.emitToRooms(sessionId, 'message.received', message);
  }

  /**
   * Emit message sent notification
   */
  emitMessageSent(sessionId: string, message: Record<string, unknown>) {
    this.emitToRooms(sessionId, 'message.sent', message);
  }

  /**
   * Emit message acknowledgment
   */
  emitMessageAck(sessionId: string, data: { messageId: string; ack: number; ackName: string }) {
    this.emitToRooms(sessionId, 'message.ack', data);
  }

  /**
   * Emit webhook delivery status (broadcast to all - no session context)
   */
  emitWebhookStatus(webhookId: string, success: boolean, error?: string) {
    this.server.emit('webhook:delivery', {
      webhookId,
      success,
      error,
      timestamp: new Date().toISOString(),
    });
  }
}
