import 'package:flutter/material.dart';

import '../vault_controller.dart';

class DAGEnvironmentAuthoritySelector extends StatelessWidget {
  const DAGEnvironmentAuthoritySelector({super.key, required this.controller});

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.usesDAGEnvironmentAuthority) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final List<VaultEnvironment> choices =
        controller.dagEnvironmentAuthorityChoices;
    final String? currentId = controller.dagEnvironmentAuthorityId;
    final bool empty = choices.isEmpty;
    final String? value =
        currentId != null && choices.any((e) => e.id == currentId)
        ? currentId
        : null;
    final bool enabled = !controller.busy && !empty;
    final String hint = empty ? '当前没有可用的管理环境' : '请选择一个你可管理的环境';

    Widget label(String text, {Color? color}) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: color == null ? null : TextStyle(color: color),
    );

    final hintColor = theme.hintColor;

    return InputDecorator(
      isEmpty: value == null,
      decoration: InputDecoration(
        labelText: '授权环境',
        helperText: empty ? '当前没有可用的管理环境，暂时无法授权创建新环境。' : '将使用所选环境的管理权限来创建新环境。',
        helperMaxLines: 3,
        enabled: enabled,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          hint: label(hint, color: hintColor),
          disabledHint: label(
            value == null
                ? hint
                : choices.firstWhere((e) => e.id == value).name,
            color: theme.disabledColor,
          ),
          items: [
            for (final env in choices)
              DropdownMenuItem<String>(value: env.id, child: label(env.name)),
          ],
          selectedItemBuilder: (context) => [
            for (final env in choices) label(env.name),
          ],
          onChanged: enabled ? controller.selectDAGEnvironmentAuthority : null,
        ),
      ),
    );
  }
}
