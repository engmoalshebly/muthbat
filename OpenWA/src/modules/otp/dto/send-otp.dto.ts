import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsString, IsNotEmpty, IsOptional, IsInt, Min, Max, Matches } from 'class-validator';

export class SendOtpDto {
  @ApiProperty({
    description: 'Recipient phone number (e.g. 967771234567 or +967 77 123 4567)',
    example: '967775451608',
  })
  @IsString()
  @IsNotEmpty()
  phoneNumber: string;

  @ApiPropertyOptional({
    description: 'Optional custom OTP code (if omitted, a cryptographically secure numeric code is generated)',
    example: '849201',
  })
  @IsOptional()
  @IsString()
  @Matches(/^\d{4,8}$/, { message: 'Code must be between 4 and 8 digits' })
  code?: string;

  @ApiPropertyOptional({
    description: 'Code length if auto-generated (default: 6)',
    example: 6,
    default: 6,
  })
  @IsOptional()
  @IsInt()
  @Min(4)
  @Max(8)
  codeLength?: number = 6;

  @ApiPropertyOptional({
    description: 'Application / Brand name shown in the OTP template',
    example: 'دفتري - Dafter',
    default: 'OpenWA',
  })
  @IsOptional()
  @IsString()
  appName?: string;

  @ApiPropertyOptional({
    description: 'Time to live (TTL) in seconds for the OTP code (default: 300 = 5 minutes)',
    example: 300,
    default: 300,
  })
  @IsOptional()
  @IsInt()
  @Min(60)
  @Max(3600)
  expiresInSeconds?: number = 300;

  @ApiPropertyOptional({
    description: 'Specific OpenWA session ID (if omitted, auto-routes to active ready session)',
    example: '00000000-0000-4000-8000-000000000000',
  })
  @IsOptional()
  @IsString()
  sessionId?: string;

  @ApiPropertyOptional({
    description: 'Language of the message template: "ar" (Arabic) or "en" (English)',
    example: 'ar',
    default: 'ar',
  })
  @IsOptional()
  @IsString()
  language?: 'ar' | 'en' = 'ar';

  @ApiPropertyOptional({
    description: 'Custom message template containing {code}, {appName}, and {expiresIn}',
    example: 'رمز الدخول إلى {appName} هو: {code}. صالح لمدة {expiresIn} دقائق.',
  })
  @IsOptional()
  @IsString()
  customTemplate?: string;
}
