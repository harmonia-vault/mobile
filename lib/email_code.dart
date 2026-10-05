/// Registration and reset share one ASCII format; Unicode case expansions fail.
String? normalizeEmailCode(String value) {
  final compact = value.replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^[2-9A-HJ-NP-Za-hj-np-z]{8}$').hasMatch(compact)) return null;
  final code = compact.toUpperCase();
  return RegExp(r'[2-9]').hasMatch(code) && RegExp(r'[A-Z]').hasMatch(code)
      ? code
      : null;
}
