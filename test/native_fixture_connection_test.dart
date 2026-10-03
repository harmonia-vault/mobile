import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/native/native_fixture_connection.dart';
import 'package:harmonia_mobile/native/native_vault_gateway.dart';
import 'package:harmonia_mobile/vault_controller.dart';

import 'native_gateway_mapping_test.dart' show PortFixture;

class FixturePort extends PortFixture implements NativeFixtureConnectionPort {
  FixturePort(this.attestation);
  final Map<String, Object?> attestation;
  int attestationCalls = 0;
  @override
  Future<Map<String, Object?>> fixtureConnectionInfo() async {
    attestationCalls++;
    return attestation;
  }
}

void main() {
  late Directory temporary;
  late HttpServer server;
  late String caPem, endpoint;
  var requests = 0;
  // 仅合成PEM头，无私钥体；拼接避免基础秘密扫描误报。
  const syntheticPrivateKeyHeader =
      '-----BEGIN '
      'PRIVATE KEY-----';
  Map<String, Object?> attestation(String target) => {
    'version': 1,
    'productFixture': true,
    'endpoint': target,
    'caPem': caPem,
  };
  Future<void> openssl(List<String> arguments) async {
    final result = await Process.run('openssl', arguments);
    if (result.exitCode != 0) {
      // 不把输出或临时私钥内容写入报告。
      throw StateError('临时合成TLS证书生成失败：${result.exitCode}');
    }
  }

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('harmonia-dart-tls-');
    String path(String file) => '${temporary.path}/$file';
    await openssl([
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-noenc',
      '-days',
      '1',
      '-subj',
      '/CN=Harmonia synthetic ephemeral CA',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
      '-keyout',
      path('ca.key'),
      '-out',
      path('ca.pem'),
    ]);
    await openssl([
      'req',
      '-new',
      '-newkey',
      'rsa:2048',
      '-noenc',
      '-subj',
      '/CN=127.0.0.1',
      '-keyout',
      path('server.key'),
      '-out',
      path('server.csr'),
    ]);
    await File(path('leaf.ext')).writeAsString(
      'basicConstraints=critical,CA:FALSE\n'
      'keyUsage=critical,digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n',
    );
    await openssl([
      'x509',
      '-req',
      '-in',
      path('server.csr'),
      '-CA',
      path('ca.pem'),
      '-CAkey',
      path('ca.key'),
      '-CAcreateserial',
      '-days',
      '1',
      '-extfile',
      path('leaf.ext'),
      '-out',
      path('server.pem'),
    ]);
    for (final file in ['ca.key', 'server.key']) {
      final permission = await Process.run('chmod', ['600', path(file)]);
      if (permission.exitCode != 0) throw StateError('无法限制临时密钥权限');
    }
    caPem = await File(path('ca.pem')).readAsString();
    final context = SecurityContext()
      ..useCertificateChain(path('server.pem'))
      ..usePrivateKey(path('server.key'));
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    endpoint = 'https://127.0.0.1:${server.port}';
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'product': 'harmonia',
          'status': 'experimental',
          'protocol': {
            'supportedMajors': [1],
            'capabilities': <String>[],
          },
          'initialRegistrationAvailable': true,
          'allowRegistration': false,
          'emailVerificationRequired': false,
        }),
      );
      await request.response.close();
    });
  });
  tearDownAll(() async {
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });

  test('真实TLS：没有局部测试CA则拒绝，不改变系统根', () async {
    final before = requests;
    await expectLater(
      inspectHarmoniaInstance(endpoint),
      throwsA(isA<GatewayFailure>()),
    );
    expect(requests, before);
  });
  test('真实TLS：debug固定endpoint追加公共CA，标准链验证后检查产品字段', () async {
    final fixture = ProductFixtureConnection.fromNative(
      attestation(endpoint),
      debugBuild: true,
    );
    final info = await inspectHarmoniaInstance(
      endpoint,
      clientFactory: () => fixture.clientFor(endpoint),
    );
    expect(info.initialRegistrationAvailable, true);
    expect(info.allowRegistration, false);
  });
  test('错误endpoint在网络前拒绝，不能把局部CA发给其他服务', () async {
    final fixture = ProductFixtureConnection.fromNative(
      attestation(endpoint),
      debugBuild: true,
    );
    final before = requests;
    expect(
      () => fixture.clientFor('$endpoint/other'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => fixture.clientFor('https://other.example.invalid'),
      throwsA(isA<GatewayFailure>()),
    );
    expect(requests, before);
  });
  test('真实TLS：受信CA也不能绕过hostname验证', () async {
    final wrongHost = 'https://localhost:${server.port}';
    final fixture = ProductFixtureConnection.fromNative(
      attestation(wrongHost),
      debugBuild: true,
    );
    final before = requests;
    await expectLater(
      inspectHarmoniaInstance(
        wrongHost,
        clientFactory: () => fixture.clientFor(wrongHost),
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(requests, before);
  });
  test('release/错误flavor/远程endpoint/私钥输入均拒绝', () {
    expect(
      () => ProductFixtureConnection.fromNative(
        attestation(endpoint),
        debugBuild: false,
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => ProductFixtureConnection.fromNative({
        ...attestation(endpoint),
        'productFixture': false,
      }, debugBuild: true),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => ProductFixtureConnection.fromNative(
        attestation('https://remote.example.invalid'),
        debugBuild: true,
      ),
      throwsA(isA<GatewayFailure>()),
    );
    expect(
      () => ProductFixtureConnection.fromNative({
        ...attestation(endpoint),
        'caPem': '$caPem\n$syntheticPrivateKeyHeader',
      }, debugBuild: true),
      throwsA(isA<GatewayFailure>()),
    );
  });
  test('正常gateway不调用fixture证明；仅明确productfixture才用真实TLS局部CA', () async {
    final normal = FixturePort(attestation(endpoint));
    final gateway = NativeVaultGateway(experimentalOptIn: true, port: normal);
    await gateway.initialize('');
    expect(normal.attestationCalls, 0);
    await expectLater(
      gateway.inspectInstance(endpoint),
      throwsA(isA<GatewayFailure>()),
    );
    final fixturePort = FixturePort(attestation(endpoint));
    final fixtureGateway = NativeVaultGateway(
      experimentalOptIn: true,
      productFixture: true,
      port: fixturePort,
    );
    await fixtureGateway.initialize('');
    expect(fixturePort.attestationCalls, 1);
    final info = await fixtureGateway.inspectInstance(endpoint);
    expect(info.initialRegistrationAvailable, true);
    await expectLater(
      fixtureGateway.inspectInstance('https://localhost:${server.port}'),
      throwsA(isA<GatewayFailure>()),
    );
    // capability来自已公开原生证据+runtime，CA证明仍不授账号或设备信任。
    expect(fixtureGateway.capabilities.contains('restoreSession'), true);
    await expectLater(fixtureGateway.pull(), throwsA(isA<GatewayFailure>()));
    expect(fixturePort.calls, isEmpty);
    expect(fixtureGateway.realVaultReady, false);
  });
}
