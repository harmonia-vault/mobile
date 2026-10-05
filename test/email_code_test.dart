import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia_mobile/email_code.dart';

void main() {
  test('邮件展示的连字符、空格及大小写统一为同一八位码', () {
    for (final input in [
      'K7QF9XMD',
      'K7QF-9XMD',
      'K7QF 9XMD',
      'k7qf-9xmd',
      ' k7qf - 9xmd ',
      'K7QF\u00a09XMD',
    ]) {
      expect(normalizeEmailCode(input), 'K7QF9XMD');
    }
  });
  test('去除展示分隔符不会接受旧六位码、错误长度或混淆字符', () {
    for (final input in [
      '123-456',
      'K7QF-9XM',
      'K7QF-9XMD2',
      'K7QF/9XMD',
      'K7QF-9XM0',
      'K7QF-9XMI',
      'ß7QF9XM',
      '２３４５-６７８９',
      '2345-6789',
      'ABCD-EFGH',
    ]) {
      expect(normalizeEmailCode(input), isNull);
    }
  });
}
