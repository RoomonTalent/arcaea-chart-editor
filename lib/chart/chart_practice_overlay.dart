import 'package:flutter/material.dart';

import 'chart_feedback.dart';
import 'chart_skin.dart';

class ChartPracticeHud extends StatelessWidget {
  const ChartPracticeHud({
    super.key,
    required this.skin,
    required this.results,
    required this.scores,
    required this.onPause,
  });

  final ChartSkin skin;
  final PracticeJudgements results;
  final Listenable scores;
  final VoidCallback? onPause;

  @override
  Widget build(BuildContext context) {
    final pause = skin[ChartSprite.pauseButton];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton.filledTonal(
          tooltip: '暂停',
          onPressed: onPause,
          icon: pause == null
              ? const Icon(Icons.pause_rounded)
              : RawImage(image: pause.image, width: 26, height: 26),
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xDA181A2B),
            foregroundColor: Colors.white,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.topRight,
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: scores,
                builder: (context, _) => _stats(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _stats() => DecoratedBox(
    key: const ValueKey('practice-summary'),
    decoration: BoxDecoration(
      color: const Color(0xE7191B2D),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFF726C89)),
    ),
    child: Stack(
      children: [
        if (skin[ChartSprite.practiceStats] case final texture?)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: RawImage(
                  image: texture.image,
                  fit: BoxFit.fill,
                  opacity: const AlwaysStoppedAnimation(.22),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final (grade, label) in [
                (PracticeGrade.shiny, '大 P'),
                (PracticeGrade.pure, '小 P'),
                (PracticeGrade.far, 'FAR'),
                (PracticeGrade.lost, 'LOST'),
              ])
                _counter(label, results.count(grade), grade.color),
              _counter('EARLY', results.early, const Color(0xFFC8CBF8)),
              _counter('LATE', results.late, const Color(0xFFF9C7D9)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _counter(String label, int value, Color color) => Text.rich(
    TextSpan(
      text: '$label ',
      style: TextStyle(color: color, fontWeight: FontWeight.w500),
      children: [
        TextSpan(
          text: '$value',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 12),
  );
}

class ChartPracticeTransition extends StatelessWidget {
  const ChartPracticeTransition({
    super.key,
    required this.progress,
    required this.skin,
  });

  final Animation<double> progress;
  final ChartSkin skin;

  @override
  Widget build(BuildContext context) => AbsorbPointer(
    child: LayoutBuilder(
      builder: (context, bounds) {
        final panelWidth = bounds.maxWidth / 2 + 1;
        return AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            final elapsed = progress.value;
            final closed = elapsed < .32
                ? Curves.easeOutCubic.transform(elapsed / .32)
                : 1 -
                      Curves.easeInOutCubic.transform(
                        ((elapsed - .45) / .55).clamp(0.0, 1.0),
                      );
            return ClipRect(
              child: Stack(
                children: [
                  for (final left in [true, false])
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: left ? -panelWidth * (1 - closed) : null,
                      right: left ? null : -panelWidth * (1 - closed),
                      width: panelWidth,
                      child: _panel(left),
                    ),
                ],
              ),
            );
          },
        );
      },
    ),
  );

  Widget _panel(bool left) {
    final texture =
        skin[left ? ChartSprite.shutterLeft : ChartSprite.shutterRight];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: left ? Alignment.centerLeft : Alignment.centerRight,
          end: left ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [
            Color(0xFF141528),
            Color(0xFF4C3D60),
            Color(0xFF9383B2),
          ],
          stops: const [0, .93, 1],
        ),
      ),
      child: texture == null
          ? null
          : RawImage(image: texture.image, fit: BoxFit.fill),
    );
  }
}
