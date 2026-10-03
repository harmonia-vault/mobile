import 'dart:async';

import 'package:flutter/material.dart';

/// 全局间距。页面与组件只使用这些档位，不散落数值。
abstract final class HSpace {
  static const double xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24;
  static const double xxl = 32, xxxl = 48;
}

/// 圆角层级：小图块 < 控件 < 卡片（22）；按钮、标签为胶囊。
abstract final class HRadius {
  static const double sm = 12, md = 16, lg = 22, pill = 999;
}

abstract final class HSize {
  static const double control = 56;
  static const double row = 64;
  static const double leading = 40;
  static const double leadingLarge = 52;
  static const double step = 28;
  static const double icon = 20;
  static const double iconSmall = 16;
  static const double hairline = 1;
  static const double stroke = 1.5;
  static const double formWidth = 520;
  static const double pageWidth = 720;
  static const double compact = 600;
  static const double wide = 700;
}

/// C 砂岩 Bento：暖纸米色 / 深煤黑底、深描边、奶油黄与灰绿卡、陶橙主色。
class _Palette {
  const _Palette({
    required this.bg,
    required this.surf,
    required this.ink,
    required this.mute,
    required this.line,
    required this.divider,
    required this.dev,
    required this.prod,
    required this.acc,
    required this.onAcc,
    required this.ok,
    required this.cardLine,
    required this.soft,
    required this.warn,
    required this.onWarn,
    required this.error,
    required this.errorBox,
    required this.onErrorBox,
  });

  final Color bg, surf, ink, mute, line, divider, dev, prod, acc, onAcc, ok;
  final Color cardLine, soft, warn, onWarn, error, errorBox, onErrorBox;
}

const _light = _Palette(
  bg: Color(0xFFF2EDE4),
  surf: Color(0xFFFFFAF2),
  ink: Color(0xFF1E1B16),
  mute: Color(0xFF6E675C),
  line: Color(0xFF1E1B16),
  divider: Color(0xFFDDD4C4),
  dev: Color(0xFFF5CF6B),
  prod: Color(0xFFBFD2B0),
  acc: Color(0xFFE2572B),
  onAcc: Color(0xFFFFFAF2),
  ok: Color(0xFF2F7D4F),
  cardLine: Color(0xFF1E1B16),
  soft: Color(0xFFE9E2D5),
  warn: Color(0xFFF6D6C2),
  onWarn: Color(0xFF5C2611),
  error: Color(0xFFB3261E),
  errorBox: Color(0xFFF7DAD3),
  onErrorBox: Color(0xFF5C140E),
);

const _dark = _Palette(
  bg: Color(0xFF17140F),
  surf: Color(0xFF221E18),
  ink: Color(0xFFF2EDE4),
  mute: Color(0xFFA69D8D),
  line: Color(0xFF4B4337),
  divider: Color(0xFF342E25),
  dev: Color(0xFFE9BD52),
  prod: Color(0xFFA3BD92),
  acc: Color(0xFFEC6A3C),
  onAcc: Color(0xFF17140F),
  ok: Color(0xFF79C792),
  cardLine: Color(0xFF0E0C09),
  soft: Color(0xFF2C271F),
  warn: Color(0xFF3F271B),
  onWarn: Color(0xFFF4C7AE),
  error: Color(0xFFFF8A75),
  errorBox: Color(0xFF47201A),
  onErrorBox: Color(0xFFFFD8CF),
);

/// 彩色卡片上的文字在明暗两套中都保持深墨色。
const _cardInk = Color(0xFF1E1B16);
const _monoFallback = ['Menlo', 'Roboto Mono', 'Courier'];

TextStyle hMono(TextStyle? s) => (s ?? const TextStyle()).copyWith(
  fontFamily: 'monospace',
  fontFamilyFallback: _monoFallback,
  letterSpacing: 0.3,
);

extension HColors on ColorScheme {
  _Palette get _p => brightness == Brightness.light ? _light : _dark;
  Color get hCanvas => _p.bg;
  Color get hCard => _p.surf;
  Color get hField => _p.surf;
  Color get hHairline => _p.line;
  Color get hSoft => _p.soft;
  Color get hDev => _p.dev;
  Color get hProd => _p.prod;
  Color get hOk => _p.ok;
  Color get hCardInk => _cardInk;
  Color get hCardLine => _p.cardLine;
}

ColorScheme _scheme(Brightness b) {
  final p = b == Brightness.light ? _light : _dark;
  return ColorScheme(
    brightness: b,
    primary: p.acc,
    onPrimary: p.onAcc,
    primaryContainer: p.dev,
    onPrimaryContainer: _cardInk,
    secondary: p.ok,
    onSecondary: p.surf,
    secondaryContainer: p.prod,
    onSecondaryContainer: _cardInk,
    tertiary: p.ink,
    onTertiary: p.bg,
    tertiaryContainer: p.warn,
    onTertiaryContainer: p.onWarn,
    error: p.error,
    onError: p.bg,
    errorContainer: p.errorBox,
    onErrorContainer: p.onErrorBox,
    surface: p.bg,
    onSurface: p.ink,
    onSurfaceVariant: p.mute,
    surfaceDim: p.bg,
    surfaceBright: p.surf,
    surfaceContainerLowest: p.surf,
    surfaceContainerLow: p.surf,
    surfaceContainer: p.surf,
    surfaceContainerHigh: p.soft,
    surfaceContainerHighest: p.soft,
    outline: p.line,
    outlineVariant: p.divider,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: p.ink,
    onInverseSurface: p.bg,
    inversePrimary: p.dev,
    surfaceTint: Colors.transparent,
  );
}

/// 底导航：选中项整块浅色圆角底，图标与文字一起高亮。
class HNavBar extends StatelessWidget {
  const HNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<({Widget icon, Widget selectedIcon, String label})> items;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelMedium;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    return Material(
      color: s.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    selected: i == selectedIndex,
                    inMutuallyExclusiveGroup: true,
                    child: Material(
                      color: i == selectedIndex
                          ? s.surfaceContainerHigh
                          : Colors.transparent,
                      shape: shape,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        customBorder: shape,
                        onTap: () => onSelected(i),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: IconTheme.merge(
                              data: IconThemeData(
                                size: 24,
                                color: i == selectedIndex
                                    ? s.onSurface
                                    : s.onSurfaceVariant,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  i == selectedIndex
                                      ? items[i].selectedIcon
                                      : items[i].icon,
                                  const SizedBox(height: 3),
                                  Text(
                                    items[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: label?.copyWith(
                                      color: i == selectedIndex
                                          ? s.onSurface
                                          : s.onSurfaceVariant,
                                      fontWeight: i == selectedIndex
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

ThemeData harmoniaTheme(Brightness brightness) {
  final s = _scheme(brightness);
  final p = brightness == Brightness.light ? _light : _dark;
  final t = ThemeData(useMaterial3: true, colorScheme: s).textTheme;
  TextStyle? w(
    TextStyle? x,
    double size,
    double line,
    FontWeight weight, [
    double spacing = 0,
  ]) => x?.copyWith(
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    letterSpacing: spacing,
  );
  final text = t.copyWith(
    headlineLarge: w(t.headlineLarge, 44, 48, FontWeight.w800, -1),
    headlineMedium: w(t.headlineMedium, 32, 38, FontWeight.w800, -0.5),
    headlineSmall: w(t.headlineSmall, 26, 32, FontWeight.w800, -0.3),
    titleLarge: w(t.titleLarge, 20, 26, FontWeight.w800),
    titleMedium: w(t.titleMedium, 17, 24, FontWeight.w700),
    titleSmall: w(t.titleSmall, 14, 20, FontWeight.w700),
    bodyLarge: w(t.bodyLarge, 16, 24, FontWeight.w600),
    bodyMedium: w(t.bodyMedium, 14, 22, FontWeight.w400),
    bodySmall: w(t.bodySmall, 13, 19, FontWeight.w400),
    labelLarge: w(t.labelLarge, 16, 22, FontWeight.w700),
    labelMedium: w(t.labelMedium, 12, 16, FontWeight.w700),
    labelSmall: w(t.labelSmall, 12, 16, FontWeight.w700, 2),
  );
  const pill = StadiumBorder();
  const minimum = Size(64, HSize.control);
  const padding = EdgeInsets.symmetric(horizontal: HSpace.xl);
  final light = brightness == Brightness.light;
  WidgetStateProperty<BorderSide> stroke(Color c) =>
      WidgetStateProperty.resolveWith(
        (st) => BorderSide(
          color: st.contains(WidgetState.disabled)
              ? c.withValues(alpha: 0.35)
              : c,
          width: HSize.stroke,
        ),
      );
  OutlineInputBorder border(Color c, [double width = HSize.stroke]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(HRadius.lg),
        borderSide: BorderSide(color: c, width: width),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: s,
    textTheme: text,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.surf,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: p.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: minimum,
        padding: padding,
        shape: pill,
        textStyle: text.labelLarge,
        disabledBackgroundColor: p.soft,
        disabledForegroundColor: p.mute,
      ).copyWith(side: stroke(light ? p.line : Colors.transparent)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: minimum,
        padding: padding,
        shape: pill,
        textStyle: text.labelLarge,
        foregroundColor: p.ink,
        backgroundColor: p.surf,
        disabledForegroundColor: p.mute,
      ).copyWith(side: stroke(p.line)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: HSpace.md),
        shape: pill,
        foregroundColor: p.ink,
        textStyle: text.titleSmall,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surf,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: HSpace.lg + HSpace.xxs,
        vertical: HSpace.lg + HSpace.xs,
      ),
      labelStyle: TextStyle(color: p.mute, fontWeight: FontWeight.w600),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (st) => TextStyle(
          fontWeight: FontWeight.w700,
          color: st.contains(WidgetState.error)
              ? p.error
              : st.contains(WidgetState.focused)
              ? p.ink
              : p.mute,
        ),
      ),
      hintStyle: TextStyle(color: p.mute, fontWeight: FontWeight.w500),
      helperStyle: text.bodySmall?.copyWith(color: p.mute),
      prefixIconColor: p.ink,
      suffixIconColor: p.ink,
      helperMaxLines: 3,
      errorMaxLines: 3,
      border: border(p.line),
      enabledBorder: border(p.line),
      focusedBorder: border(p.acc, 2),
      errorBorder: border(p.error),
      focusedErrorBorder: border(p.error, 2),
      disabledBorder: border(p.line.withValues(alpha: 0.35)),
    ),
    dividerTheme: DividerThemeData(
      color: p.divider,
      thickness: HSize.hairline,
      space: HSize.hairline,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
      minTileHeight: HSize.row,
      iconColor: p.ink,
      titleTextStyle: text.bodyLarge?.copyWith(color: p.ink),
      subtitleTextStyle: text.bodyMedium?.copyWith(color: p.mute),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.soft,
      elevation: 0,
      height: 72,
      iconTheme: WidgetStateProperty.resolveWith(
        (st) => IconThemeData(
          size: 24,
          color: st.contains(WidgetState.selected) ? p.ink : p.mute,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected)
            ? text.labelMedium?.copyWith(
                color: p.ink,
                fontWeight: FontWeight.w800,
              )
            : text.labelMedium?.copyWith(
                color: p.mute,
                fontWeight: FontWeight.w600,
              ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.bg,
      indicatorColor: p.dev,
      indicatorShape: pill,
      selectedIconTheme: const IconThemeData(color: _cardInk),
      unselectedIconTheme: IconThemeData(color: p.mute),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w800,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(color: p.mute),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: p.acc, textColor: p.onAcc),
    chipTheme: ChipThemeData(
      shape: pill,
      side: BorderSide(color: p.line, width: HSize.stroke),
      backgroundColor: p.surf,
      selectedColor: p.dev,
      checkmarkColor: _cardInk,
      labelStyle: text.titleSmall,
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.sm,
        vertical: HSpace.xs + HSpace.xxs,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected) ? p.acc : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onAcc),
      side: BorderSide(color: p.line, width: HSize.stroke),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: p.soft,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.ink),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HRadius.lg),
        side: BorderSide(color: p.line, width: HSize.stroke),
      ),
      titleTextStyle: text.titleLarge?.copyWith(color: p.ink),
      contentTextStyle: text.bodyMedium?.copyWith(color: p.mute),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.bg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HRadius.md),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: Colors.transparent,
      color: p.acc,
    ),
  );
}

enum HTone { neutral, accent, success, warning, danger }

(Color, Color) _toneColors(ColorScheme s, HTone t) => switch (t) {
  HTone.neutral => (s.hSoft, s.onSurface),
  HTone.accent => (s.hDev, s.hCardInk),
  HTone.success => (s.hProd, s.hCardInk),
  HTone.warning => (s.tertiaryContainer, s.onTertiaryContainer),
  HTone.danger => (s.errorContainer, s.onErrorContainer),
};

IconData _toneIcon(HTone t) => switch (t) {
  HTone.warning => Icons.warning_amber_rounded,
  HTone.danger => Icons.error_outline,
  HTone.success => Icons.check_circle_outline,
  _ => Icons.info_outline,
};

List<Widget> _divided(List<Widget> children) => [
  for (var i = 0; i < children.length; i++) ...[
    if (i > 0) const Divider(indent: HSpace.lg, endIndent: HSpace.lg),
    children[i],
  ],
];

/// 胶囊小按钮（如“更换”），带深描边。
ButtonStyle hChipButton(ColorScheme s) => TextButton.styleFrom(
  minimumSize: const Size(48, 40),
  padding: const EdgeInsets.symmetric(horizontal: HSpace.md + HSpace.xxs),
  side: BorderSide(color: s.hHairline, width: HSize.stroke),
);

/// 页面骨架：统一页边距、最大宽度、滚动和块间距。
class HPage extends StatelessWidget {
  const HPage({super.key, required this.children, this.narrow = false});

  final List<Widget> children;
  final bool narrow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final side = box.maxWidth < HSize.compact ? HSpace.lg + HSpace.xxs : HSpace.xl;
      final width = narrow ? HSize.formWidth : HSize.pageWidth;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width + side * 2),
          child: ListView.separated(
            padding: EdgeInsets.fromLTRB(side, HSpace.sm, side, HSpace.xxl),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(height: HSpace.md),
            itemBuilder: (_, i) => children[i],
          ),
        ),
      );
    },
  );
}

/// 卡片外观：22 圆角、1.5 深描边。tone 为 accent/success 时为奶油黄/灰绿卡。
BoxDecoration _tileDecoration(ColorScheme s, HTone? tone) {
  final colored = tone == HTone.accent || tone == HTone.success;
  return BoxDecoration(
    color: colored ? _toneColors(s, tone!).$1 : s.hCard,
    borderRadius: BorderRadius.circular(HRadius.lg),
    border: Border.all(
      color: colored ? s.hCardLine : s.hHairline,
      width: HSize.stroke,
    ),
  );
}

/// Bento 卡：可着色、可点击，内容自适应高度。
class HTile extends StatelessWidget {
  const HTile({
    super.key,
    required this.child,
    this.tone,
    this.onTap,
    this.padding = const EdgeInsets.all(HSpace.lg + HSpace.xxs),
  });

  final Widget child;
  final HTone? tone;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(HRadius.lg);
    final body = Padding(padding: padding, child: child);
    return DecoratedBox(
      decoration: _tileDecoration(Theme.of(context).colorScheme, tone),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? body
            : InkWell(onTap: onTap, borderRadius: radius, child: body),
      ),
    );
  }
}

/// 卡片中的圆形图标，深描边；大号为品牌式实心圆。
class HIconTile extends StatelessWidget {
  const HIconTile(
    this.icon, {
    super.key,
    this.tone = HTone.neutral,
    this.large = false,
  });

  final IconData icon;
  final HTone tone;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    var (bg, fg) = _toneColors(s, tone);
    Color? line = s.hCardLine;
    if (tone == HTone.neutral) {
      bg = Colors.transparent;
      fg = s.onSurface;
      line = s.hHairline;
    } else if (large && tone == HTone.accent) {
      bg = s.onSurface;
      fg = s.hDev;
      line = null;
    }
    final size = large ? HSize.leadingLarge : HSize.leading;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: line == null
            ? null
            : Border.all(color: line, width: HSize.stroke),
      ),
      child: Icon(icon, color: fg, size: large ? HSize.icon + 4 : HSize.icon - 2),
    );
  }
}

/// 一级页面标题：HARMONIA 字标 + 粗体大标题。
class HPageTitle extends StatelessWidget {
  const HPageTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'HARMONIA',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: HSpace.xs),
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.headlineLarge)),
            ?trailing,
          ],
        ),
      ],
    );
  }
}

/// 品牌主卡：奶油黄底、和弦标记与粗体标题，用于连接与账号入口。
class HBrandHero extends StatelessWidget {
  const HBrandHero({super.key, this.caption, this.body});

  final String? caption;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final ink = s.hCardInk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'HARMONIA',
          style: theme.textTheme.labelSmall?.copyWith(
            color: s.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: HSpace.md),
        HTile(
          tone: HTone.accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: HSpace.md,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: HSpace.xs,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(
                        width: 2.5,
                        height: HSize.iconSmall,
                        decoration: BoxDecoration(
                          color: s.hDev,
                          borderRadius: BorderRadius.circular(HRadius.pill),
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                '和弦',
                style: theme.textTheme.headlineLarge?.copyWith(color: ink),
              ),
              if (caption != null)
                Text(
                  caption!,
                  style: theme.textTheme.titleMedium?.copyWith(color: ink),
                ),
              if (body != null)
                Text(
                  body!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: ink.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 统计小卡：标签 + 粗体数值，可带状态图标。
class HStat extends StatelessWidget {
  const HStat({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.tone = HTone.neutral,
  });

  final String label, value;
  final IconData? icon;
  final HTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final iconColor = switch (tone) {
      HTone.success => s.hOk,
      HTone.warning || HTone.danger => s.primary,
      _ => s.onSurfaceVariant,
    };
    return HTile(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.lg,
        vertical: HSpace.md + HSpace.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: HSpace.sm,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: s.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            spacing: HSpace.xs + HSpace.xxs,
            children: [
              if (icon != null) Icon(icon, size: 22, color: iconColor),
              Flexible(
                child: Text(
                  value,
                  style: icon == null
                      ? theme.textTheme.headlineSmall
                      : theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 彩色卡上的胶囊标签：实心深墨或描边。
class _CardTag extends StatelessWidget {
  const _CardTag(this.label, {this.icon, this.filled = true});

  final String label;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.hCardInk;
    final fg = filled ? _light.surf : ink;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.md - HSpace.xxs,
        vertical: HSpace.xs + HSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: filled ? ink : Colors.transparent,
        borderRadius: BorderRadius.circular(HRadius.pill),
        border: Border.all(color: ink, width: HSize.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: HSpace.xs,
        children: [
          if (icon != null) Icon(icon, size: HSize.iconSmall - 2, color: fg),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// 环境卡：名称、箭头、变量大数字与角色标签。只读用灰绿，其余用奶油黄。
class HEnvCard extends StatelessWidget {
  const HEnvCard({
    super.key,
    required this.name,
    required this.count,
    required this.role,
    this.roleIcon,
    this.readOnly = false,
    this.onTap,
  });

  final String name, role;
  final int count;
  final IconData? roleIcon;
  final bool readOnly;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.hCardInk;
    final big = theme.textTheme.headlineLarge?.copyWith(
      color: ink,
      fontSize: 40,
      height: 1,
    );
    return HTile(
      tone: readOnly ? HTone.success : HTone.accent,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: HSpace.lg + HSpace.xxs,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: HSpace.md,
            children: [
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.titleLarge?.copyWith(color: ink),
                ),
              ),
              if (onTap != null)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ink, width: HSize.stroke),
                  ),
                  child: Icon(Icons.north_east, size: 18, color: ink),
                ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: HSpace.sm,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: '$count',
                    style: big,
                    children: [
                      TextSpan(
                        text: ' 个变量',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: ink,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _CardTag(role, icon: roleIcon, filled: !readOnly),
            ],
          ),
        ],
      ),
    );
  }
}

/// 流程页标题：可选图标、标题与一句说明。
class HHeader extends StatelessWidget {
  const HHeader({
    super.key,
    required this.title,
    this.body,
    this.icon,
    this.tone = HTone.accent,
  });

  final String title;
  final String? body;
  final IconData? icon;
  final HTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            HIconTile(icon!, tone: tone, large: true),
            const SizedBox(height: HSpace.lg),
          ],
          Text(title, style: theme.textTheme.headlineSmall),
          if (body != null) ...[
            const SizedBox(height: HSpace.sm),
            Text(
              body!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 中性卡片容器（米白底 + 深描边），列表与表单共用。
class HSurface extends StatelessWidget {
  const HSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      HTile(padding: EdgeInsets.zero, child: child);
}

/// 分组：小标题 + 容器。`form` 时内容带内边距并竖向排列，否则为分隔列表。
class HSection extends StatelessWidget {
  const HSection({
    super.key,
    this.title,
    this.trailing,
    this.footer,
    this.form = false,
    required this.children,
  });

  final String? title;
  final Widget? trailing;
  final String? footer;
  final bool form;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null || trailing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(HSpace.xs, HSpace.xs, 0, HSpace.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title ?? '',
                    style: theme.textTheme.titleSmall?.copyWith(color: muted),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        HSurface(
          child: form
              ? Padding(
                  padding: const EdgeInsets.all(HSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: HSpace.md,
                    children: children,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _divided(children),
                ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(HSpace.xs, HSpace.sm, 0, 0),
            child: Text(
              footer!,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
  }
}

/// 列表行：内容自适应高度，长中文换行而不截断。`label` 为标题上方的小字。
class HRow extends StatelessWidget {
  const HRow({
    super.key,
    required this.title,
    this.label,
    this.subtitle,
    this.icon,
    this.tone = HTone.neutral,
    this.badge,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? label;
  final String? subtitle;
  final IconData? icon;
  final HTone tone;
  final Widget? badge;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final tap = enabled ? onTap : null;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: HSize.row),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HSpace.lg,
          vertical: HSpace.md,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              HIconTile(icon!, tone: tone),
              const SizedBox(width: HSpace.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (label != null)
                    Text(
                      label!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Wrap(
                    spacing: HSpace.sm,
                    runSpacing: HSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title, style: theme.textTheme.bodyLarge),
                      ?badge,
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: HSpace.xxs),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: HSpace.sm),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: HSpace.sm),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurface),
            ],
          ],
        ),
      ),
    );
    final row = tap == null ? content : InkWell(onTap: tap, child: content);
    return enabled ? row : Opacity(opacity: 0.5, child: row);
  }
}

/// 标签-值，竖排以容纳长地址与长名称。
class HKeyValue extends StatelessWidget {
  const HKeyValue(
    this.label,
    this.value, {
    super.key,
    this.mono = false,
    this.selectable = false,
  });

  final String label, value;
  final bool mono, selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge;
    final style = mono ? hMono(base) : base;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.lg,
        vertical: HSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: HSpace.xxs),
          selectable
              ? SelectableText(value, style: style)
              : Text(value, style: style),
        ],
      ),
    );
  }
}

/// 有底色的提示块：状态、错误、能力不可用。
class HNotice extends StatelessWidget {
  const HNotice(
    this.text, {
    super.key,
    this.tone = HTone.neutral,
    this.icon,
    this.title,
    this.actions = const [],
  });

  final String text;
  final HTone tone;
  final IconData? icon;
  final String? title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = _toneColors(theme.colorScheme, tone);
    final body = tone == HTone.neutral
        ? theme.colorScheme.onSurfaceVariant
        : fg;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.lg,
        vertical: HSpace.md,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(HRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HSpace.xxs),
            child: Icon(icon ?? _toneIcon(tone), size: HSize.icon, color: fg),
          ),
          const SizedBox(width: HSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: theme.textTheme.titleSmall?.copyWith(color: fg),
                  ),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(color: body),
                ),
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: HSpace.sm),
                    child: Wrap(
                      spacing: HSpace.sm,
                      runSpacing: HSpace.xs,
                      alignment: WrapAlignment.end,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 无底色的弱提示，用于脚注与禁用原因。
class HHint extends StatelessWidget {
  const HHint(this.text, {super.key, this.icon = Icons.info_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HSpace.xxs),
            child: Icon(icon, size: HSize.iconSmall, color: muted),
          ),
          const SizedBox(width: HSpace.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// 胶囊标签：中性为描边，accent 为深墨实心，其余为语义底色。
class HPill extends StatelessWidget {
  const HPill(this.label, {super.key, this.icon, this.tone = HTone.neutral});

  final String label;
  final IconData? icon;
  final HTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    var (bg, fg) = _toneColors(s, tone);
    var side = fg.withValues(alpha: 0.4);
    if (tone == HTone.neutral) {
      bg = Colors.transparent;
      fg = s.onSurface;
      side = s.hHairline;
    } else if (tone == HTone.accent) {
      bg = s.onSurface;
      fg = s.surface;
      side = bg;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.md - HSpace.xxs,
        vertical: HSpace.xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(HRadius.pill),
        border: Border.all(color: side, width: HSize.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: HSize.iconSmall - 2, color: fg),
            const SizedBox(width: HSpace.xs),
          ],
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

class HStep extends StatelessWidget {
  const HStep(this.n, this.title, this.body, {super.key, this.done = false});

  final int n;
  final String title, body;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final fg = done ? s.hCardInk : s.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: HSize.step,
          height: HSize.step,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? s.hDev : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: done ? s.hCardLine : s.hHairline,
              width: HSize.stroke,
            ),
          ),
          child: done
              ? Icon(Icons.check, size: HSize.iconSmall, color: fg)
              : Text(
                  '$n',
                  style: theme.textTheme.labelMedium?.copyWith(color: fg),
                ),
        ),
        const SizedBox(width: HSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: HSpace.xxs),
              Text(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: s.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 空状态与“找不到”状态。
class HEmpty extends StatelessWidget {
  const HEmpty({super.key, required this.icon, required this.title, this.body});

  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.xl,
        vertical: HSpace.xxl,
      ),
      child: Column(
        children: [
          HIconTile(icon, large: true),
          const SizedBox(height: HSpace.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (body != null) ...[
            const SizedBox(height: HSpace.xs),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 折叠的次要信息，默认收起。
class HDetails extends StatelessWidget {
  const HDetails({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => HSurface(
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
        tilePadding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
        minTileHeight: HSize.row,
        shape: const Border(),
        collapsedShape: const Border(),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: _divided(children),
      ),
    ),
  );
}

/// 密文遮罩：默认圆点，揭示后等宽显示。
class HSecret extends StatelessWidget {
  const HSecret(this.value, {super.key, required this.revealed});

  final String value;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      revealed ? value : '••••••••',
      maxLines: revealed ? 6 : 1,
      overflow: TextOverflow.ellipsis,
      style: hMono(theme.textTheme.bodyMedium).copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 行内两步确认；确认后仍交给原回调，不自行假定成功。
class HDangerButton extends StatefulWidget {
  const HDangerButton({
    super.key,
    required this.label,
    required this.warning,
    required this.onConfirm,
    this.icon = Icons.delete_outline,
  });

  final String label;
  final String warning;
  final Future<void> Function()? onConfirm;
  final IconData icon;

  @override
  State<HDangerButton> createState() => _HDangerButtonState();
}

class _HDangerButtonState extends State<HDangerButton> {
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final run = widget.onConfirm;
    if (!_armed) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: s.error,
          side: BorderSide(
            color: s.error.withValues(alpha: run == null ? 0.35 : 1),
            width: HSize.stroke,
          ),
        ),
        onPressed: run == null ? null : () => setState(() => _armed = true),
        icon: Icon(widget.icon),
        label: Text(widget.label),
      );
    }
    return HNotice(
      widget.warning,
      tone: HTone.danger,
      title: '确认${widget.label}？',
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: s.onErrorContainer),
          onPressed: () => setState(() => _armed = false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: s.error,
            foregroundColor: s.onError,
            side: BorderSide(color: s.error, width: HSize.stroke),
          ),
          onPressed: run == null
              ? null
              : () {
                  setState(() => _armed = false);
                  unawaited(run());
                },
          child: Text('确认${widget.label}'),
        ),
      ],
    );
  }
}
