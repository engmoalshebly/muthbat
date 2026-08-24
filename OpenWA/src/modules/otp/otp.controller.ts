import { Controller, Post, Body, HttpCode, HttpStatus } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse, ApiHeader } from '@nestjs/swagger';
import { OtpService } from './otp.service';
import { SendOtpDto, VerifyOtpDto, SendOtpResponseDto, VerifyOtpResponseDto } from './dto';
import { RequireRole } from '../auth/decorators/auth.decorators';
import { ApiKeyRole } from '../auth/entities/api-key.entity';

@ApiTags('otp')
@Controller('otp')
export class OtpController {
  constructor(private readonly otpService: OtpService) {}

  @Post('send')
  @HttpCode(HttpStatus.OK)
  @RequireRole(ApiKeyRole.OPERATOR)
  @ApiOperation({
    summary: 'Send WhatsApp OTP verification code',
    description: 'Generates and delivers a secure OTP code to the recipient WhatsApp number with automatic session routing, phone validation, cooldown, and rich templates.',
  })
  @ApiHeader({ name: 'X-API-Key', description: 'API Key for authentication' })
  @ApiResponse({
    status: 200,
    description: 'OTP successfully generated and sent',
    type: SendOtpResponseDto,
  })
  @ApiResponse({
    status: 400,
    description: 'Invalid phone number, not registered on WhatsApp, or cooldown period active',
  })
  @ApiResponse({
    status: 503,
    description: 'WhatsApp session is not active or ready',
  })
  async sendOtp(@Body() dto: SendOtpDto): Promise<SendOtpResponseDto> {
    return this.otpService.sendOtp(dto);
  }

  @Post('verify')
  @HttpCode(HttpStatus.OK)
  @RequireRole(ApiKeyRole.OPERATOR)
  @ApiOperation({
    summary: 'Verify WhatsApp OTP code',
    description: 'Validates the submitted OTP code against the active record, checks expiration, tracks attempts, and invalidates code on success or max attempts.',
  })
  @ApiHeader({ name: 'X-API-Key', description: 'API Key for authentication' })
  @ApiResponse({
    status: 200,
    description: 'Verification result',
    type: VerifyOtpResponseDto,
  })
  async verifyOtp(@Body() dto: VerifyOtpDto): Promise<VerifyOtpResponseDto> {
    return this.otpService.verifyOtp(dto);
  }

  @Post('resend')
  @HttpCode(HttpStatus.OK)
  @RequireRole(ApiKeyRole.OPERATOR)
  @ApiOperation({
    summary: 'Resend WhatsApp OTP verification code',
    description: 'Enforces cooldown policy and sends a new OTP code to the recipient.',
  })
  @ApiHeader({ name: 'X-API-Key', description: 'API Key for authentication' })
  @ApiResponse({
    status: 200,
    description: 'OTP successfully resent',
    type: SendOtpResponseDto,
  })
  async resendOtp(@Body() dto: SendOtpDto): Promise<SendOtpResponseDto> {
    return this.otpService.sendOtp(dto);
  }
}
