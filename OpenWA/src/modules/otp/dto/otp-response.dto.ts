import { ApiProperty } from '@nestjs/swagger';

export class SendOtpResponseDto {
  @ApiProperty({ example: true })
  success: boolean;

  @ApiProperty({ example: '967775451608' })
  phoneNumber: string;

  @ApiProperty({ example: '967775451608@c.us' })
  chatId: string;

  @ApiProperty({ example: '00000000-0000-4000-8000-000000000000' })
  sessionId: string;

  @ApiProperty({ example: 'true_967775451608@c.us_3EB0123456789' })
  messageId: string;

  @ApiProperty({ example: 300, description: 'Expiry duration in seconds' })
  expiresInSeconds: number;

  @ApiProperty({ example: 1786907096000, description: 'Timestamp when OTP expires' })
  expiresAt: number;

  @ApiProperty({ example: 60, description: 'Cooldown period in seconds before a new OTP can be requested' })
  cooldownSeconds: number;

  @ApiProperty({ example: 'OTP sent successfully via WhatsApp' })
  message: string;
}

export class VerifyOtpResponseDto {
  @ApiProperty({ example: true })
  valid: boolean;

  @ApiProperty({ example: 'verified', enum: ['verified', 'invalid_code', 'expired', 'max_attempts_exceeded', 'not_found'] })
  status: string;

  @ApiProperty({ example: 'OTP verification succeeded' })
  message: string;

  @ApiProperty({ example: '967775451608' })
  phoneNumber: string;

  @ApiProperty({ example: 4, required: false })
  attemptsRemaining?: number;
}
