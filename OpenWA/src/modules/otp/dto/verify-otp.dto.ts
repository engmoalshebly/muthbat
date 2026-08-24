import { ApiProperty } from '@nestjs/swagger';
import { IsString, IsNotEmpty } from 'class-validator';

export class VerifyOtpDto {
  @ApiProperty({
    description: 'Phone number the OTP was sent to (e.g. 967771234567)',
    example: '967775451608',
  })
  @IsString()
  @IsNotEmpty()
  phoneNumber: string;

  @ApiProperty({
    description: 'The OTP code provided by the user',
    example: '849201',
  })
  @IsString()
  @IsNotEmpty()
  code: string;
}
