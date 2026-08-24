export interface OtpRecord {
  phoneNumber: string;
  code: string;
  appName?: string;
  sessionId: string;
  messageId?: string;
  attempts: number;
  maxAttempts: number;
  expiresAt: number; // timestamp in ms
  createdAt: number; // timestamp in ms
  lastSentAt: number; // timestamp in ms for cooldown calculation
}

export interface OtpVerificationResult {
  valid: boolean;
  status: 'verified' | 'invalid_code' | 'expired' | 'max_attempts_exceeded' | 'not_found';
  message: string;
  attemptsRemaining?: number;
}
