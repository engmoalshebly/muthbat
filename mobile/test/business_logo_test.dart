import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/sync/business_logo_upload.dart';
import 'package:muthbat/features/merchant/data/business_logo.dart';
import 'package:muthbat/features/merchant/data/merchant_api_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> makeImage(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0x8000ff00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  test(
    'logo is normalized to PNG, constrained proportionally, and keeps alpha',
    () async {
      final bytes = await prepareBusinessLogo(await makeImage(1200, 600));
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 512);
      expect(image.height, 256);
      final rgba = await image.toByteData();
      expect(rgba!.getUint8(3), inInclusiveRange(127, 129));
      image.dispose();
      codec.dispose();
    },
  );

  test('invalid or oversized files are rejected before queuing', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList(utf8.encode('<svg/>')),
      Uint8List(5 * 1024 * 1024 + 1),
    ]) {
      await expectLater(
        prepareBusinessLogo(bytes),
        throwsA(isA<MerchantApiException>()),
      );
    }
  });

  for (final duplicate in [false, true]) {
    test(
      'upload confirms via RPC after ${duplicate ? 'duplicate retry' : 'new upload'}',
      () async {
        final requests = <String>[];
        const path = 'business/logo/request.png';
        final client = SupabaseClient(
          'https://example.supabase.co',
          'test-key',
          httpClient: MockClient((request) async {
            requests.add(request.url.path);
            if (request.url.path.contains('/storage/')) {
              expect(
                request.body.toLowerCase(),
                contains('content-type: image/png'),
              );
              expect(request.headers['x-upsert'], 'false');
              return duplicate
                  ? http.Response(
                      jsonEncode({
                        'statusCode': '409',
                        'error': 'Duplicate',
                        'message': 'exists',
                      }),
                      409,
                    )
                  : http.Response(
                      jsonEncode({'Key': 'business-assets/$path'}),
                      200,
                    );
            }
            final payload = jsonDecode(request.body) as Map;
            expect(payload['p_object_path'], path);
            return http.Response(
              jsonEncode(path),
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.dispose);
        expect(
          await uploadBusinessLogo(
            client,
            businessId: 'business',
            requestId: 'request',
            bytes: Uint8List.fromList([1, 2]),
            extension: 'png',
          ),
          path,
        );
        expect(requests, hasLength(2));
      },
    );
  }

  test('upload permission errors do not proceed to confirmation', () async {
    var count = 0;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        count++;
        return http.Response(
          jsonEncode({
            'statusCode': '403',
            'error': 'Unauthorized',
            'message': 'denied',
          }),
          403,
        );
      }),
    );
    addTearDown(client.dispose);
    await expectLater(
      uploadBusinessLogo(
        client,
        businessId: 'business',
        requestId: 'request',
        bytes: Uint8List.fromList([1]),
        extension: 'png',
      ),
      throwsA(isA<StorageException>()),
    );
    expect(count, 1);
  });

  test(
    'an uploaded object is not success without matching RPC confirmation',
    () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        httpClient: MockClient(
          (request) async => http.Response(
            request.url.path.contains('/storage/')
                ? '{"Key":"uploaded"}'
                : '"different-path"',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.dispose);
      await expectLater(
        uploadBusinessLogo(
          client,
          businessId: 'business',
          requestId: 'request',
          bytes: Uint8List.fromList([1]),
          extension: 'png',
        ),
        throwsStateError,
      );
    },
  );
}
