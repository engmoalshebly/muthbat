import {
  Injectable,
  BadRequestException,
  NotFoundException,
  ServiceUnavailableException,
  OnModuleDestroy,
} from '@nestjs/common';
import { randomInt } from 'crypto';
import { SessionService } from '../session/session.service';
import { IWhatsAppEngine } from '../../engine/interfaces/whatsapp-engine.interface';
import { SessionStatus } from '../session/entities/session.entity';
import { createLogger } from '../../common/services/logger.service';
import { SendOtpDto, VerifyOtpDto, SendOtpResponseDto, VerifyOtpResponseDto } from './dto';
import { OtpRecord, OtpVerificationResult } from './interfaces/otp.interface';

const DEFAULT_COOLDOWN_SECONDS = 60;
const DEFAULT_MAX_ATTEMPTS = 5;

@Injectable()
export class OtpService implements OnModuleDestroy {
  private readonly logger = createLogger('OtpService');

  // In-memory OTP storage keyed by sanitized phone number
  private readonly otpStore = new Map<string, OtpRecord>();

  // Cleanup interval
  private readonly cleanupInterval: NodeJS.Timeout;

  constructor(private readonly sessionService: SessionService) {
    // Periodically clean up expired OTP records every 60 seconds
    this.cleanupInterval = setInterval(() => {
      this.cleanupExpiredRecords();
    }, 60000);
  }

  onModuleDestroy(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
    }
  }

  /**
   * Sanitizes phone number string to pure digits.
   */
  sanitizePhoneNumber(phone: string): string {
    if (!phone) return '';
    let cleaned = phone.replace(/[^0-9]/g, '');
    // If number starts with 00 (international prefix), remove 00
    if (cleaned.startsWith('00')) {
      cleaned = cleaned.substring(2);
    }
    return cleaned;
  }

  /**
   * Generates a cryptographically secure random numeric code.
   */
  generateNumericCode(length: number = 6): string {
    const min = Math.pow(10, length - 1);
    const max = Math.pow(10, length) - 1;
    return randomInt(min, max + 1).toString();
  }

  /**
   * Resolves the active session and its ready WhatsApp engine.
   */
  async resolveEngine(requestedSessionId?: string): Promise<{ sessionId: string; engine: IWhatsAppEngine }> {
    if (requestedSessionId) {
      const session = await this.sessionService.findOne(requestedSessionId);
      const engine = this.sessionService.getEngine(session.id);
      if (!engine || session.status !== SessionStatus.READY) {
        throw new ServiceUnavailableException(`Session '${session.name}' (${session.id}) is not ready`);
      }
      return { sessionId: session.id, engine };
    }

    // Auto-discover ready session
    const allSessions = await this.sessionService.findAll();
    const readySession = allSessions.find(s => s.status === SessionStatus.READY);

    if (!readySession) {
      throw new ServiceUnavailableException('No active WhatsApp session is currently ready. Please start a session first.');
    }

    const engine = this.sessionService.getEngine(readySession.id);
    if (!engine) {
      throw new ServiceUnavailableException(`Engine for session '${readySession.name}' is not initialized`);
    }

    return { sessionId: readySession.id, engine };
  }

  /**
   * Formats the OTP WhatsApp message with rich, localized typography and emojis.
   */
  buildMessage(code: string, appName: string = 'OpenWA', expiresInMinutes: number = 5, lang: 'ar' | 'en' = 'ar', customTemplate?: string): string {
    if (customTemplate) {
      return customTemplate
        .replace(/{code}/g, code)
        .replace(/{appName}/g, appName)
        .replace(/{expiresIn}/g, expiresInMinutes.toString());
    }

    if (lang === 'en') {
      return (
        `🔐 *${appName} Verification Code*\n\n` +
        `Your verification code is: *${code}*\n\n` +
        `⏳ Valid for *${expiresInMinutes} minutes*.\n` +
        `⚠️ For security reasons, do *NOT* share this code with anyone.`
      );
    }

    // Default Arabic template
    return (
      `🔐 *رمز التحقق - ${appName}*\n\n` +
      `رمز الدخول الخاص بك هو: *${code}*\n\n` +
      `⏳ صالح للاستخدام لمدة *${expiresInMinutes} دقائق*.\n` +
      `⚠️ تنبيه أمني: لا تشارك هذا الرمز مع أي شخص للحفاظ على سرية حسابك.`
    );
  }

  /**
   * Sends an OTP to the given phone number via WhatsApp.
   */
  async sendOtp(dto: SendOtpDto): Promise<SendOtpResponseDto> {
    const rawNumber = dto.phoneNumber;
    const cleanNumber = this.sanitizePhoneNumber(rawNumber);

    if (!cleanNumber || cleanNumber.length < 8) {
      throw new BadRequestException(`Invalid phone number format: '${rawNumber}'`);
    }

    const { sessionId, engine } = await this.resolveEngine(dto.sessionId);

    // Cooldown check
    const existing = this.otpStore.get(cleanNumber);
    const now = Date.now();

    if (existing && existing.lastSentAt) {
      const elapsedSeconds = Math.floor((now - existing.lastSentAt) / 1000);
      if (elapsedSeconds < DEFAULT_COOLDOWN_SECONDS) {
        const waitSeconds = DEFAULT_COOLDOWN_SECONDS - elapsedSeconds;
        throw new BadRequestException(
          `Cooldown active: Please wait ${waitSeconds} seconds before requesting a new OTP code.`,
        );
      }
    }

    // Check if phone number exists on WhatsApp
    try {
      const exists = await engine.checkNumberExists(cleanNumber);
      if (!exists) {
        throw new BadRequestException(`The phone number +${cleanNumber} is not registered on WhatsApp.`);
      }
    } catch (err: any) {
      if (err instanceof BadRequestException) throw err;
      this.logger.warn(`WhatsApp number check warning for ${cleanNumber}: ${err?.message || err}`);
    }

    // Generate code
    const length = dto.codeLength || 6;
    const code = dto.code || this.generateNumericCode(length);
    const appName = dto.appName || 'OpenWA';
    const ttlSeconds = dto.expiresInSeconds || 300;
    const expiresInMinutes = Math.max(1, Math.ceil(ttlSeconds / 60));
    const lang = dto.language || 'ar';

    const messageText = this.buildMessage(code, appName, expiresInMinutes, lang, dto.customTemplate);
    const targetChatId = `${cleanNumber}@c.us`;

    this.logger.log(`Sending OTP to ${targetChatId} via session ${sessionId}`);

    const sendResult = await engine.sendTextMessage(targetChatId, messageText);

    const record: OtpRecord = {
      phoneNumber: cleanNumber,
      code,
      appName,
      sessionId,
      messageId: sendResult.id,
      attempts: 0,
      maxAttempts: DEFAULT_MAX_ATTEMPTS,
      expiresAt: now + ttlSeconds * 1000,
      createdAt: now,
      lastSentAt: now,
    };

    this.otpStore.set(cleanNumber, record);

    return {
      success: true,
      phoneNumber: cleanNumber,
      chatId: targetChatId,
      sessionId,
      messageId: sendResult.id,
      expiresInSeconds: ttlSeconds,
      expiresAt: record.expiresAt,
      cooldownSeconds: DEFAULT_COOLDOWN_SECONDS,
      message: 'OTP sent successfully via WhatsApp',
    };
  }

  /**
   * Verifies an OTP code for a phone number.
   */
  async verifyOtp(dto: VerifyOtpDto): Promise<VerifyOtpResponseDto> {
    const cleanNumber = this.sanitizePhoneNumber(dto.phoneNumber);
    const submittedCode = (dto.code || '').trim();

    const record = this.otpStore.get(cleanNumber);
    const now = Date.now();

    if (!record) {
      return {
        valid: false,
        status: 'not_found',
        message: 'No active OTP request found for this phone number.',
        phoneNumber: cleanNumber,
      };
    }

    if (now > record.expiresAt) {
      this.otpStore.delete(cleanNumber);
      return {
        valid: false,
        status: 'expired',
        message: 'The OTP code has expired. Please request a new code.',
        phoneNumber: cleanNumber,
      };
    }

    if (record.attempts >= record.maxAttempts) {
      this.otpStore.delete(cleanNumber);
      return {
        valid: false,
        status: 'max_attempts_exceeded',
        message: 'Maximum verification attempts exceeded. Code has been invalidated.',
        phoneNumber: cleanNumber,
      };
    }

    if (record.code !== submittedCode) {
      record.attempts += 1;
      const attemptsRemaining = Math.max(0, record.maxAttempts - record.attempts);

      if (attemptsRemaining === 0) {
        this.otpStore.delete(cleanNumber);
        return {
          valid: false,
          status: 'max_attempts_exceeded',
          message: 'Incorrect code. Maximum attempts reached. Code invalidated.',
          phoneNumber: cleanNumber,
          attemptsRemaining: 0,
        };
      }

      return {
        valid: false,
        status: 'invalid_code',
        message: `Incorrect OTP code. ${attemptsRemaining} attempt(s) remaining.`,
        phoneNumber: cleanNumber,
        attemptsRemaining,
      };
    }

    // Success: Invalidate OTP so it cannot be reused
    this.otpStore.delete(cleanNumber);

    return {
      valid: true,
      status: 'verified',
      message: 'OTP verification succeeded.',
      phoneNumber: cleanNumber,
    };
  }

  /**
   * Removes expired OTP entries from memory.
   */
  private cleanupExpiredRecords(): void {
    const now = Date.now();
    for (const [phone, record] of this.otpStore.entries()) {
      if (now > record.expiresAt) {
        this.otpStore.delete(phone);
      }
    }
  }
}
