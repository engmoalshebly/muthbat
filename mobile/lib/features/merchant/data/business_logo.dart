import 'dart:typed_data';
import 'dart:ui' as ui;

import 'merchant_api_exception.dart';

/// Decode and re-encode selected images so content and MIME type always agree.
Future<Uint8List> prepareBusinessLogo(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
    throw const MerchantApiException(
      code: 'invalid_logo_size',
      message: 'اختر صورة لا يتجاوز حجمها 5 ميجابايت.',
    );
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 8192 ||
        descriptor.height > 8192 ||
        descriptor.width * descriptor.height > 24000000) {
      throw const FormatException('image_dimensions');
    }
    final scale =
        512 /
        (descriptor.width > descriptor.height
            ? descriptor.width
            : descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1
          ? (descriptor.width * scale).round().clamp(1, 512)
          : descriptor.width,
      targetHeight: scale < 1
          ? (descriptor.height * scale).round().clamp(1, 512)
          : descriptor.height,
    );
    image = (await codec.getNextFrame()).image;
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null) throw const FormatException('image_encoding');
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } catch (_) {
    throw const MerchantApiException(
      code: 'invalid_logo_image',
      message: 'تعذر قراءة الصورة. اختر صورة سليمة بصيغة PNG أو JPG أو WebP.',
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
