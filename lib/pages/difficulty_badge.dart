import 'package:flutter/material.dart';

import '../models/difficulty.dart';

class DifficultyBadge extends StatelessWidget {
  final Difficulty difficulty;
  final bool highlighted;

  const DifficultyBadge({
    super.key,
    required this.difficulty,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final classColor = switch (difficulty.ratingClass) {
      RatingClass.past => const Color(0xFF5BB9A8),
      RatingClass.present => const Color(0xFFEDBB45),
      RatingClass.future => const Color(0xFFE16E72),
      RatingClass.beyond => const Color(0xFFB891E0),
      RatingClass.eternal => const Color(0xFF69B8F1),
      _ => colors.outline,
    };
    final background = highlighted
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final foreground = highlighted
        ? colors.onPrimaryContainer
        : colors.onSurface;
    final label = TextStyle(
      fontSize: 10,
      height: 1.3,
      fontWeight: FontWeight.w700,
      color: foreground,
    );

    return Semantics(
      label:
          '${RatingClass.toFullName(difficulty.ratingClass)} ${difficulty.ratingDisplay}',
      selected: highlighted,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(3, 2, 4, 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: highlighted
                ? colors.primary
                : classColor.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: highlighted
                    ? colors.primary
                    : classColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  difficulty.difficultyName,
                  style: label.copyWith(
                    color: highlighted ? colors.onPrimary : foreground,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 3),
            Text(difficulty.ratingDisplay, style: label),
          ],
        ),
      ),
    );
  }
}
