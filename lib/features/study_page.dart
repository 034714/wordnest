import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/controller.dart';
import '../domain/models.dart';
import '../domain/scheduler.dart';
import '../data/offline_dictionary.dart';
import 'shared_widgets.dart';

class StudyPage extends StatefulWidget {
  const StudyPage({
    super.key,
    required this.controller,
    required this.mode,
    required this.onBack,
    required this.onRestart,
    required this.onSpeak,
    required this.onToggleCompact,
    this.compact = false,
    this.onStartRound,
    this.onStopSpeech,
    this.onPlaySound,
    this.paused = false,
    required this.onPause,
  });
  final StartRoundCallback? onStartRound;
  final Future<void> Function()? onStopSpeech;
  final Future<void> Function(String sound)? onPlaySound;
  final AppController controller;
  final String mode;
  final bool compact, paused;
  final VoidCallback onPause;
  final Future<void> Function() onBack, onRestart, onToggleCompact;
  final Future<void> Function(String) onSpeak;
  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  final input = TextEditingController();
  final note = TextEditingController();
  final keyboard = FocusNode();
  final typeFocus = FocusNode();
  final typingScroll = ScrollController();
  bool noteDialogOpen = false, leaving = false;
  int? selected;
  bool reveal = false,
      verified = false,
      typingSubmitted = false,
      typingCorrect = false,
      typingWrong = false;
  int lastIndex = -1;
  Timer? autoNext;
  String typed = '', localMode = '';
  String transition = '';
  ChoiceQuestion? question;
  bool questionZh2en = false;
  bool busy = false;
  int? roundCount;
  Map<String, dynamic> get history =>
      Map<String, dynamic>.from(c.state.session['history'] as Map? ?? {});
  Map<String, dynamic> get record =>
      Map<String, dynamic>.from(history['${c.sessionIndex}'] as Map? ?? {});
  Map<String, dynamic> patchRecord(Map<String, dynamic> patch) => {
    'history': {
      ...history,
      '${c.sessionIndex}': {...record, ...patch},
    },
  };
  AppController get c => widget.controller;
  AppCopy get copy => AppCopy(c.settings.copyStyle == 'cute');
  String get mode => localMode.isEmpty ? widget.mode : localMode;

  /// `zh2en` prompts with the Chinese meaning and offers English word options;
  /// any other value keeps the classic word-to-meaning layout.
  bool get _zh2en => c.settings.questionDirection == 'zh2en';
  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _sync();
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    if (widget.onStopSpeech != null) unawaited(widget.onStopSpeech!());
    input.dispose();
    note.dispose();
    keyboard.dispose();
    typeFocus.dispose();
    typingScroll.dispose();
    autoNext?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StudyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      transition = '';
    }
    if (widget.paused || !c.settings.autoAdvance) autoNext?.cancel();
    _sync();
    if (oldWidget.paused && !widget.paused && mode == 'typing') {
      _scheduleTypingFocus();
    }
  }

  void _changed() {
    if (!mounted) return;
    _sync();
    setState(() {});
  }

  void _sync() {
    final key =
        '${c.state.session['startedAt']}/${c.sessionIndex}/${widget.mode}';
    if (transition == key) return;
    transition = key;
    autoNext?.cancel();
    reset(c.sessionIndex);
    question = null;
    final ids = c.sessionIds;
    if (c.sessionIndex >= ids.length) {
      if (widget.onStopSpeech != null) unawaited(widget.onStopSpeech!());
      return;
    }
    final entry = c.state.entries[ids[c.sessionIndex]];
    if (entry == null) return;
    if (mode == 'formal') _prepareQuestion(entry);
    if (mode == 'typing') _scheduleTypingFocus();
    final expected = transition;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || transition != expected) return;
      await widget.onStopSpeech?.call();
      if (!mounted || transition != expected || widget.paused) return;
      if (c.settings.tts && c.settings.autoTts) {
        await widget.onSpeak(entry.word);
      }
    });
  }

  void _prepareQuestion(WordEntry entry) {
    final labels = record['optionLabels'];
    final correctIndex = record['correctIndex'];
    if (labels is List &&
        correctIndex is int &&
        labels.isNotEmpty &&
        correctIndex >= 0 &&
        correctIndex < labels.length) {
      final frozen = labels.cast<String>();
      question = ChoiceQuestion(entry, frozen, correctIndex);
      // A correct label equal to the word itself identifies a zh2en question,
      // so frozen history keeps rendering in the direction it was asked in.
      questionZh2en = frozen[correctIndex].trim() == entry.word.trim();
      return;
    }
    questionZh2en = _zh2en;
    question = _question(entry);
    final q = question;
    if (q == null) return;
    final zh2en = questionZh2en;
    final expected = transition;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || transition != expected || record['options'] != null) {
        return;
      }
      final optionIds = q.options
          .asMap()
          .entries
          .map(
            (item) => item.key == q.correctIndex
                ? entry.id
                : c.state.entries.values
                      .firstWhere(
                        (candidate) =>
                            candidate.id != entry.id &&
                            (zh2en
                                ? candidate.word == item.value
                                : candidate.coreMeaning == item.value),
                        orElse: () => entry,
                      )
                      .id,
          )
          .toList();
      await c.patchSession(
        patchRecord({
          'entryId': entry.id,
          'mode': 'formal',
          'options': optionIds,
          'optionLabels': q.options,
          'correctIndex': q.correctIndex,
        }),
      );
    });
  }

  /// Formal question for [entry]. In zh2en the distractor meanings chosen by
  /// [createQuestion] are shown as their English words instead.
  ChoiceQuestion? _question(WordEntry entry) {
    final base = createQuestion(
      entry,
      c.state.entries.values,
      count: c.settings.optionCount,
      seed: c.sessionIndex,
    );
    if (base == null || !_zh2en) return base;
    final byMeaning = <String, String>{};
    for (final candidate in c.state.entries.values) {
      byMeaning.putIfAbsent(candidate.coreMeaning, () => candidate.word);
    }
    final target = base.options[base.correctIndex];
    final options = <String>[];
    var correctIndex = -1;
    for (final label in base.options) {
      final isTarget = label == target;
      final word = isTarget ? entry.word : byMeaning[label] ?? '';
      if (word.trim().isEmpty) continue;
      if (isTarget) {
        if (options.contains(word)) return null;
        correctIndex = options.length;
        options.add(word);
      } else if (word != entry.word && !options.contains(word)) {
        options.add(word);
      }
    }
    if (correctIndex < 0 || options.length < 2) return null;
    return ChoiceQuestion(entry, options, correctIndex);
  }

  bool get _typingActive {
    if (!mounted ||
        leaving ||
        noteDialogOpen ||
        widget.paused ||
        mode != 'typing' ||
        c.sessionMode != widget.mode ||
        c.sessionIndex >= c.sessionIds.length ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    // AnimatedSwitcher keeps the previous page mounted while it fades out.
    // Do not let that outgoing editor reopen the keyboard on the new page.
    var outgoing = false;
    context.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is FadeTransition &&
          ancestor.opacity.status == AnimationStatus.reverse) {
        outgoing = true;
        return false;
      }
      return true;
    });
    return !outgoing;
  }

  void _focusTyping() {
    if (!_typingActive) return;
    typeFocus.requestFocus();
    // requestFocus alone does not reopen an Android keyboard dismissed by Back.
    final editorContext = typeFocus.context;
    final editor = editorContext?.findAncestorStateOfType<EditableTextState>();
    editor?.requestKeyboard();
  }

  void _scheduleTypingFocus() {
    final expected = transition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || transition != expected) return;
      _focusTyping();
    });
  }

  Future<void> _back() async {
    leaving = true;
    autoNext?.cancel();
    typeFocus.unfocus();
    await widget.onStopSpeech?.call();
    await widget.onBack();
  }

  Widget _typingEditor(WordEntry entry) {
    final theme = Theme.of(context);
    final expectedLetters = entry.word.characters.toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseSize = widget.compact ? 30.0 : 42.0;
        final scale = MediaQuery.textScalerOf(context);
        final measurement = TextPainter(
          text: TextSpan(
            text: entry.word,
            style: TextStyle(
              fontSize: baseSize,
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
          textScaler: scale,
          textDirection: TextDirection.ltr,
        )..layout();
        final available = (constraints.maxWidth - 20).clamp(
          1.0,
          double.infinity,
        );
        final fontSize = measurement.width > available
            ? (baseSize * available / measurement.width).clamp(20.0, baseSize)
            : baseSize;
        measurement.dispose();
        final style = TextStyle(
          fontSize: fontSize,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
          height: 1.5,
        );
        return Semantics(
          label: '英文拼写，${expectedLetters.length} 个字符',
          child: Container(
            key: const ValueKey('typing-slots'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: .04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: typingWrong
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary.withValues(alpha: .25),
              ),
            ),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: input,
              builder: (context, value, _) {
                final letters = value.text.characters.toList();
                final count = letters.length > expectedLetters.length
                    ? letters.length
                    : expectedLetters.length;
                var offset = 0;
                final spans = <InlineSpan>[];
                for (var index = 0; index < count; index++) {
                  final filled = index < letters.length;
                  final letter = filled
                      ? letters[index]
                      : index == 0 && c.settings.typingReveal
                      ? expectedLetters[index]
                      : '_';
                  final correct =
                      filled &&
                      index < expectedLetters.length &&
                      wordKey(letter) == wordKey(expectedLetters[index]);
                  final end = offset + (filled ? letter.length : 0);
                  final composing =
                      filled &&
                      value.composing.isValid &&
                      !value.composing.isCollapsed &&
                      value.composing.start < end &&
                      value.composing.end > offset;
                  spans.add(
                    TextSpan(
                      text: letter,
                      style: TextStyle(
                        color: !filled
                            ? theme.colorScheme.onSurfaceVariant
                            : correct
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                        decoration: composing ? TextDecoration.underline : null,
                        decorationColor: theme.colorScheme.primary,
                      ),
                    ),
                  );
                  offset = end;
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: ClipRect(
                            child: AnimatedBuilder(
                              animation: typingScroll,
                              builder: (context, _) => OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: 0,
                                maxWidth: double.infinity,
                                child: Transform.translate(
                                  offset: Offset(
                                    typingScroll.hasClients
                                        ? -typingScroll.offset
                                        : 0,
                                    0,
                                  ),
                                  child: RichText(
                                    key: const ValueKey('typing-slot-glyphs'),
                                    textDirection: TextDirection.ltr,
                                    textScaler: scale,
                                    maxLines: 1,
                                    text: TextSpan(
                                      style: style,
                                      children: spans,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    TextField(
                      key: const ValueKey('typing-input'),
                      controller: input,
                      focusNode: typeFocus,
                      scrollController: typingScroll,
                      autofocus: _typingActive,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.none,
                      textDirection: TextDirection.ltr,
                      showCursor: true,
                      cursorColor: theme.colorScheme.primary,
                      style: style.copyWith(color: Colors.transparent),
                      decoration: null,
                      inputFormatters: [
                        TextInputFormatter.withFunction(
                          (oldValue, newValue) =>
                              typingSubmitted ||
                                  busy ||
                                  c.saving ||
                                  widget.paused
                              ? oldValue
                              : newValue,
                        ),
                      ],
                      // Keep the real editor connected after Done/Enter,
                      // including correct submissions and immediate retries.
                      onEditingComplete: () {},
                      onSubmitted: (_) => _submitTyping(entry),
                      onTapOutside: (_) {},
                      onChanged: (text) {
                        if (c.settings.sound) {
                          unawaited(
                            widget.onPlaySound?.call('key') ??
                                Future<void>.value(),
                          );
                        }
                        setState(() {
                          typed = text;
                          typingWrong = false;
                        });
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _navigate(int index) async {
    autoNext?.cancel();
    if (busy ||
        c.saving ||
        widget.paused ||
        index < 0 ||
        index > c.sessionIds.length) {
      return;
    }
    await c.navigateTo(index);
    if (mounted && mode == 'typing') {
      _scheduleTypingFocus();
    } else if (mounted && !widget.compact) {
      keyboard.requestFocus();
    }
  }

  Future<void> _startRound() async {
    autoNext?.cancel();
    leaving = widget.onStartRound != null;
    if (leaving) typeFocus.unfocus();
    await widget.onStopSpeech?.call();
    if (widget.onStartRound != null) {
      await widget.onStartRound!(
        widget.mode,
        resume: false,
        limit: roundCount ?? c.settings.roundSize,
      );
    } else {
      await c.begin(
        widget.mode,
        resume: false,
        limit: roundCount ?? c.settings.roundSize,
      );
    }
  }

  void reset(int index) {
    lastIndex = index;
    selected = null;
    reveal = false;
    typingSubmitted = false;
    typingCorrect = false;
    typingWrong = false;
    verified = false;
    localMode = '';
    input.clear();
    typed = '';
    final result = record['result'];
    if (result is Map && result['index'] == index) {
      selected = result['selected'] as int?;
      verified = true;
      reveal = true;
      localMode = 'formal';
    } else if (c.state.session['verificationIndex'] == index) {
      localMode = 'formal';
    }
    final typingResult = record['typingResult'];
    if (typingResult is Map && typingResult['index'] == index) {
      if (typingResult['correct'] == true) {
        input.text = typingResult['input'] as String? ?? '';
        typed = input.text;
        typingSubmitted = true;
        typingCorrect = true;
        reveal = true;
      } else {
        typingWrong = true;
      }
    }
  }

  Future<void> _verify() async {
    if (c.saving || widget.paused) return;
    final ok = await c.patchSession({'verificationIndex': c.sessionIndex});
    busy = false;
    if (ok && mounted) {
      setState(() {
        localMode = 'formal';
        reveal = false;
        final entry = c.state.entries[c.sessionIds[c.sessionIndex]];
        if (entry != null) _prepareQuestion(entry);
      });
    }
  }

  Future<void> _choose(int index, ChoiceQuestion q) async {
    if (verified || busy || c.saving || widget.paused) return;
    busy = true;
    final correct = index == q.correctIndex;
    final ok = await c.review(
      q.entry.id,
      kind: 'formal',
      correct: correct,
      advanceSession: false,
      idempotencyKey:
          '${c.state.session['startedAt']}-${c.sessionIndex}-formal',
      sessionPatch: patchRecord({
        'answered': true,
        'result': {
          'index': c.sessionIndex,
          'selected': index,
          'correct': correct,
        },
      }),
    );
    busy = false;
    if (!mounted || !ok) return;
    setState(() {
      selected = index;
      verified = true;
      reveal = true;
    });
    if (correct && c.settings.autoAdvance && !widget.paused) {
      final expected = transition;
      autoNext = Timer(const Duration(seconds: 2), () {
        if (mounted &&
            transition == expected &&
            !widget.paused &&
            c.settings.autoAdvance) {
          unawaited(_next());
        }
      });
    }
  }

  Future<void> _next() async {
    autoNext?.cancel();
    if (busy || c.saving || widget.paused) return;
    await c.advance();
    if (mounted) setState(() {});
  }

  Future<void> _view(WordEntry e, bool familiar) async {
    if (busy || c.saving || widget.paused) return;
    if (record['quickResult'] != null) {
      await _next();
      return;
    }
    busy = true;
    final ok = await c.review(
      e.id,
      kind: 'view',
      familiar: familiar,
      sessionPatch: patchRecord({
        'quickResult': {'familiar': familiar},
      }),
      idempotencyKey: '${c.state.session['startedAt']}-${c.sessionIndex}-view',
    );
    busy = false;
    if (mounted && ok) setState(() {});
  }

  Future<void> _toggleNotebook(WordEntry entry) async {
    if (busy || c.saving || widget.paused) return;
    busy = true;
    await c.toggleNotebook(entry.id);
    busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _submitTyping(WordEntry entry) async {
    if (widget.paused || busy || c.saving || !_typingActive) return;
    if (typingSubmitted) {
      await _next();
      return;
    }
    if (input.text.trim().isEmpty) {
      _scheduleTypingFocus();
      return;
    }
    busy = true;
    final expected = transition;
    final typedText = input.text;
    final correct = wordKey(typedText) == wordKey(entry.word);
    final patch = patchRecord({
      'typingResult': {
        'index': c.sessionIndex,
        'input': typedText,
        'correct': correct,
      },
    });
    // The learning event is recorded once per word; retries only refresh the
    // persisted attempt so no duplicate events reach the statistics.
    final recorded = record['typingResult'] is Map;
    final ok = recorded
        ? await c.patchSession(patch)
        : await c.review(
            entry.id,
            kind: 'typing',
            correct: correct,
            advanceSession: false,
            idempotencyKey:
                '${c.state.session['startedAt']}-${c.sessionIndex}-typing',
            sessionPatch: patch,
          );
    busy = false;
    if (!mounted || transition != expected) return;
    if (!ok) {
      _scheduleTypingFocus();
      return;
    }
    if (correct) {
      if (c.settings.sound) {
        unawaited(widget.onPlaySound?.call('correct') ?? Future<void>.value());
      }
      setState(() {
        typingSubmitted = true;
        typingCorrect = true;
        typingWrong = false;
        reveal = true;
      });
      // Show the correct word briefly, then continue automatically.
      if (c.settings.autoAdvance && !widget.paused) {
        autoNext?.cancel();
        autoNext = Timer(const Duration(milliseconds: 900), () {
          if (!mounted || transition != expected || widget.paused) return;
          unawaited(_next());
        });
      }
      _scheduleTypingFocus();
      return;
    }
    if (c.settings.sound) {
      unawaited(widget.onPlaySound?.call('incorrect') ?? Future<void>.value());
    }
    setState(() {
      typingWrong = true;
      typingCorrect = false;
      typingSubmitted = false;
      input.clear();
      typed = '';
    });
    _scheduleTypingFocus();
  }

  /// Space submits in typing mode only when the answer cannot contain a space
  /// and no IME composition is pending; otherwise the key belongs to the text.
  bool get _typingSpaceSubmits {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return false;
    }
    final composing = input.value.composing;
    if (composing.isValid && !composing.isCollapsed) return false;
    final ids = c.sessionIds;
    if (c.sessionIndex >= ids.length) return false;
    final entry = c.state.entries[ids[c.sessionIndex]];
    return entry != null && !entry.word.contains(' ');
  }

  void _step(int delta) {
    final target = c.sessionIndex + delta;
    if (target < 0 || target > c.sessionIds.length) return;
    unawaited(_navigate(target));
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.paused || c.saving) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyP &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      final ids = c.sessionIds;
      if (c.sessionIndex < ids.length) {
        unawaited(widget.onSpeak(c.state.entries[ids[c.sessionIndex]]!.word));
      }
      return KeyEventResult.handled;
    }
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    // Unified pagination: ↑/↓ move to the previous/next item in every mode and
    // are always consumed, so focus can never fall through to the bottom
    // NavigationBar. ←/→ never page words anymore.
    if (up || down) {
      _step(up ? -1 : 1);
      return KeyEventResult.handled;
    }
    final ids = c.sessionIds;
    if (c.sessionIndex >= ids.length) return KeyEventResult.ignored;
    final entry = c.state.entries[ids[c.sessionIndex]];
    if (entry == null) return KeyEventResult.ignored;
    final left = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    final right = event.logicalKey == LogicalKeyboardKey.arrowRight;
    final space = event.logicalKey == LogicalKeyboardKey.space;
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (mode == 'typing') {
      if (!_typingActive) return KeyEventResult.ignored;
      // ←/→ stay with the text caret inside the input field.
      if (left || right) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => reveal = !reveal);
        return KeyEventResult.handled;
      }
      if (space && _typingSpaceSubmits) {
        unawaited(_submitTyping(entry));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (mode == 'quick') {
      if (right || event.logicalKey == LogicalKeyboardKey.digit1) {
        unawaited(_view(entry, true));
        return KeyEventResult.handled;
      }
      if (left || event.logicalKey == LogicalKeyboardKey.digit2) {
        unawaited(_view(entry, false));
        return KeyEventResult.handled;
      }
      if (space) {
        setState(() => reveal = !reveal);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (mode == 'formal') {
      final q = question;
      if (q == null) {
        if (space || enter) {
          unawaited(_next());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (verified) {
        if (space || enter) {
          unawaited(_next());
          return KeyEventResult.handled;
        }
      } else if (space) {
        // Never let space reach the surrounding buttons before the answer is
        // submitted; it only continues once the result is revealed.
        return KeyEventResult.handled;
      }
      final i = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ].indexOf(event.logicalKey);
      if (i >= 0 && i < q.options.length) {
        unawaited(_choose(i, q));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ids = c.sessionIds;
    final theme = Theme.of(context);
    if (ids.isEmpty || c.sessionIndex >= ids.length) {
      return _finished(context, ids.isEmpty);
    }
    final entry = c.state.entries[ids[c.sessionIndex]];
    if (entry == null) return _finished(context, true);
    final card = c.card(entry.id);
    final q = mode == 'formal' ? question : null;
    final showMeaning = mode == 'quick'
        ? (!card.seen || c.settings.showChinese || reveal)
        : mode == 'typing' || verified;
    final showDetails = mode != 'typing' || reveal;
    // zh2en prompts with the Chinese meaning and hides word plus phonetics
    // until the answer is submitted.
    final zh2enPrompt = mode == 'formal' && questionZh2en && q != null;
    final inNotebook = c.isNotebook(entry.id);
    // The user can file a word into the notebook at any time; it is their own
    // collection, not an answer. Only auto-add needs a graded answer.
    final notebookReady = true;
    final autoAdded =
        mode == 'formal' &&
        verified &&
        q != null &&
        selected != null &&
        selected != q.correctIndex &&
        c.settings.notebookAutoAddErrors &&
        inNotebook;
    final padding = widget.compact
        ? 18.0
        : MediaQuery.sizeOf(context).width < 600
        ? 20.0
        : 32.0;
    final labels = {'quick': '轻量记词', 'formal': '回忆验证', 'typing': '键盘强化'};
    return Focus(
      focusNode: keyboard,
      autofocus: mode != 'typing',
      onKeyEvent: _key,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: mode == 'typing' ? _focusTyping : null,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.compact ? 480 : 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: _back,
                        tooltip: '回到今日',
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.compact ? '词栖 · 轻量小窗' : labels[mode]!,
                          style: TextStyle(
                            fontSize: widget.compact ? 16 : 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.compact)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '${c.sessionIndex + 1}/${ids.length}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (widget.compact)
                        IconButton(
                          onPressed: widget.onPause,
                          tooltip: widget.paused ? '继续轮播' : '暂停轮播',
                          icon: Icon(
                            widget.paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                          ),
                        ),
                      if (widget.compact)
                        IconButton(
                          onPressed: widget.onToggleCompact,
                          tooltip: '展开主窗口',
                          icon: const Icon(Icons.open_in_full_rounded),
                        ),
                      if (!widget.compact)
                        Text(
                          '${c.sessionIndex + 1} / ${ids.length}',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  if (!widget.compact) ...[
                    const SizedBox(height: 12),
                    RoundCountChips(
                      value: roundCount ?? c.settings.roundSize,
                      enabled: !busy && !c.saving,
                      onChanged: (value) => setState(() => roundCount = value),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: busy || c.saving ? null : _startRound,
                          child: Text(copy.start),
                        ),
                        IconButton(
                          tooltip: '上一词 · ↑',
                          onPressed:
                              c.sessionIndex > 0 && !c.saving && !widget.paused
                              ? () => _navigate(c.sessionIndex - 1)
                              : null,
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        IconButton(
                          tooltip: '下一词 · ↓',
                          onPressed: !c.saving && !widget.paused
                              ? () => _navigate(c.sessionIndex + 1)
                              : null,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: c.sessionIndex / ids.length,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 22),
                  if (!widget.compact)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Text(
                        mode == 'quick'
                            ? '随时停下，进度会保留。认识一个，也是进步。'
                            : mode == 'formal'
                            ? '先回忆，再选择。答案会在提交后揭晓。'
                            : '把单词敲出来。打字结果与回忆正确率分别记录。',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(
                        widget.compact || MediaQuery.sizeOf(context).width < 600
                            ? 22
                            : 36,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer
                                      .withValues(alpha: .45),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  mode == 'typing'
                                      ? '键盘练习'
                                      : card.seen
                                      ? '复习词'
                                      : copy.newWord,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (c.settings.tts)
                                IconButton(
                                  onPressed: () => widget.onSpeak(entry.word),
                                  tooltip: '朗读 · Ctrl+P',
                                  icon: const Icon(
                                    Icons.volume_up_outlined,
                                    size: 22,
                                  ),
                                ),
                              if (!widget.compact)
                                IconButton(
                                  onPressed:
                                      (mode == 'formal' && !verified) ||
                                          (mode == 'typing' && !reveal)
                                      ? null
                                      : () => _editNote(entry),
                                  tooltip: '添加个人笔记',
                                  icon: const Icon(Icons.edit_note_rounded),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (mode == 'typing') ...[
                            if (reveal && !typingSubmitted) ...[
                              Text(
                                entry.word,
                                key: const ValueKey('typing-answer'),
                                style: TextStyle(
                                  fontSize: widget.compact ? 26 : 34,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            _typingEditor(entry),
                          ] else if (zh2enPrompt && !verified)
                            SelectableText(
                              entry.hasMeaning ? entry.meaning : entry.word,
                              key: const ValueKey('zh2en-prompt'),
                              textAlign: TextAlign.start,
                              style: TextStyle(
                                fontSize: widget.compact ? 24 : 32,
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                              ),
                            )
                          else
                            SelectableText(
                              entry.word,
                              style: TextStyle(
                                fontSize: widget.compact ? 32 : 46,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'Segoe UI',
                                letterSpacing: .5,
                              ),
                            ),
                          if (c.settings.showPhonetic &&
                              (mode != 'formal' || verified)) ...[
                            const SizedBox(height: 9),
                            Text(
                              entry.uk.isNotEmpty
                                  ? '/${entry.uk}/'
                                  : entry.us.isNotEmpty
                                  ? '/${entry.us}/'
                                  : '',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontFamily: 'Segoe UI',
                                fontSize: 14,
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          if (showMeaning) ...[
                            Text(
                              entry.hasMeaning
                                  ? entry.meaning
                                  : '这个词暂时没有释义。可在词书中补充内容。',
                              style: TextStyle(
                                fontSize: widget.compact ? 16 : 19,
                                height: 1.7,
                              ),
                            ),
                            if (showDetails && entry.usage.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 15),
                                child: Text(
                                  entry.usage,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: theme.colorScheme.primary,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                            if (c.settings.showExample &&
                                entry.example.isNotEmpty &&
                                !widget.compact &&
                                mode != 'typing') ...[
                              const SizedBox(height: 24),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: .04,
                                  ),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.example,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        height: 1.6,
                                        fontFamily: 'Segoe UI',
                                      ),
                                    ),
                                    if (entry
                                        .exampleTranslation
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        entry.exampleTranslation,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.5,
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            if (showDetails &&
                                c.settings.showRoot &&
                                (entry.root.isNotEmpty ||
                                    OfflineMorphology.hints(entry.word)
                                        .isNotEmpty))
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                  entry.root.isNotEmpty
                                      ? '构词  ${entry.root}'
                                      : '构词提示  ${OfflineMorphology.hints(entry.word).join(' · ')}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            if (showDetails &&
                                c.settings.showSynonyms &&
                                entry.synonyms.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  '相关词  ${entry.synonyms}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            if (showDetails &&
                                c.settings.showNotes &&
                                (c.state.notes[entry.id] ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                  '我的笔记  ${c.state.notes[entry.id]}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ] else if (mode == 'quick')
                            TextButton.icon(
                              onPressed: () => setState(() => reveal = true),
                              icon: const Icon(
                                Icons.visibility_outlined,
                                size: 18,
                              ),
                              label: const Text('想一想，再看释义'),
                            ),
                          if (mode == 'typing') ...[
                            const SizedBox(height: 12),
                            Text(
                              copy.cute
                                  ? '直接敲出单词，字母会填进上面的小空位。'
                                  : '直接输入英文，字母会填入上方空位。',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (typingWrong)
                              Padding(
                                padding: const EdgeInsets.only(top: 11),
                                child: Text(
                                  copy.typingWrong,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                            if (typingSubmitted)
                              Padding(
                                padding: const EdgeInsets.only(top: 11),
                                child: Text(
                                  copy.spellingCorrect,
                                  style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                          ],
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Tooltip(
                                message: inNotebook
                                    ? '从生词本中移除'
                                    : '加入生词本，随时单独复习',
                                child: TextButton.icon(
                                  key: const ValueKey('notebook-toggle'),
                                  onPressed:
                                      notebookReady &&
                                          !busy &&
                                          !c.saving &&
                                          !widget.paused
                                      ? () => _toggleNotebook(entry)
                                      : null,
                                  icon: Icon(
                                    inNotebook
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    inNotebook
                                        ? copy.inNotebook
                                        : copy.addNotebook,
                                  ),
                                ),
                              ),
                              if (autoAdded)
                                Text(
                                  copy.notebookAutoAdded,
                                  key: const ValueKey('notebook-auto-added'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (mode == 'quick') ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: c.saving || widget.paused
                                ? null
                                : () => _view(entry, false),
                            child: Text(copy.unfamiliar),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: c.saving || widget.paused
                                ? null
                                : () => _view(entry, true),
                            child: Text(card.seen ? '认识' : copy.remember),
                          ),
                        ),
                      ],
                    ),
                    if (card.seen)
                      TextButton(
                        onPressed: _verify,
                        child: const Text('不确定 · 来一道验证题'),
                      ),
                  ],
                  if (mode == 'formal')
                    if (q == null) ...[
                      const Text('暂时无法生成不歧义的选项。请导入更多带释义的词条，或先进行轻量学习。'),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _next, child: const Text('跳过此题')),
                    ] else ...[
                      for (var i = 0; i < q.options.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 11),
                          child: Material(
                            color: verified && i == q.correctIndex
                                ? theme.colorScheme.primaryContainer.withValues(
                                    alpha: .6,
                                  )
                                : verified && i == selected
                                ? theme.colorScheme.errorContainer
                                : theme.colorScheme.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: verified && i == q.correctIndex
                                    ? theme.colorScheme.primary
                                    : theme.dividerColor.withValues(alpha: .14),
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: verified || c.saving || widget.paused
                                  ? null
                                  : () => _choose(i, q),
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 28,
                                      height: 28,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: .05),
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      child: Text(
                                        '${i + 1}',
                                        style: TextStyle(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        q.options[i],
                                        style: const TextStyle(
                                          fontSize: 15,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                    if (verified && i == q.correctIndex)
                                      Icon(
                                        Icons.check_circle_rounded,
                                        color: theme.colorScheme.primary,
                                      ),
                                    if (verified &&
                                        i == selected &&
                                        i != q.correctIndex)
                                      Icon(
                                        Icons.cancel_outlined,
                                        color: theme.colorScheme.error,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (verified && copy.cute)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            selected == q.correctIndex
                                ? copy.correct
                                : copy.incorrect,
                          ),
                        ),
                      if (verified)
                        FilledButton(
                          onPressed: c.saving ? null : _next,
                          child: const Text('下一词 · Enter'),
                        ),
                    ],
                  if (mode == 'typing') ...[
                    FilledButton(
                      onPressed: c.saving || widget.paused
                          ? null
                          : () => _submitTyping(entry),
                      child: Text(
                        typingSubmitted ? '下一词 · Enter' : '检查拼写 · Enter',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() => reveal = !reveal),
                          icon: Icon(
                            reveal
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 18,
                          ),
                          label: Text(
                            reveal ? copy.hideAnswer : copy.showAnswer,
                          ),
                        ),
                        TextButton(
                          onPressed: _next,
                          child: const Text('跳过这个词'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    widget.paused
                        ? '已暂停 · 不自动换词'
                        : mode == 'quick'
                        ? '↑↓ 换词 · ← 不熟悉 · → 认识 · 空格 显示释义'
                        : mode == 'formal'
                        ? '数字 1–4 选择 · ↑↓ 换词 · 空格/Enter 下一词'
                        : '↑↓ 换词 · 空格/Enter 提交 · Tab 显示/隐藏答案 · Ctrl+P 朗读',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    mode == 'formal' ? '调度依据是正式答题对错。' : '轻量过词与拼写练习不会计入正式回忆正确率。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _finished(BuildContext context, bool empty) => Focus(
    focusNode: keyboard,
    autofocus: mode != 'typing',
    // Keep ↑/↓ consumed on the completion screen too, so focus never walks
    // down into the bottom NavigationBar.
    onKeyEvent: (node, event) =>
        event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                event.logicalKey == LogicalKeyboardKey.arrowDown)
        ? KeyEventResult.handled
        : KeyEventResult.ignored,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                empty ? Icons.spa_outlined : Icons.check_rounded,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              empty ? copy.empty : copy.success,
              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Text(
              empty
                  ? '没有待处理任务。可以导入词书、开始新一轮，\n或稍后回来处理到期复习。'
                  : '进度已保存在本地。\n刚看过的词，之后还会回来验证。',
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.9,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 30),
            FilledButton(onPressed: _back, child: const Text('回到今日')),
            if (!empty) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: _startRound, child: const Text('再来一小轮')),
            ],
          ],
        ),
      ),
    ),
  );
  Future<void> _editNote(WordEntry entry) async {
    if (noteDialogOpen || (mode == 'typing' && !reveal)) return;
    noteDialogOpen = true;
    typeFocus.unfocus();
    note.text = c.state.notes[entry.id] ?? '';
    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${entry.word} · 我的笔记'),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: note,
              minLines: 3,
              maxLines: 8,
              maxLength: 5000,
              decoration: const InputDecoration(hintText: '自己的助记、常用搭配或例句…'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (result == true && mounted) await c.note(entry.id, note.text.trim());
    } finally {
      noteDialogOpen = false;
      if (mounted) _scheduleTypingFocus();
    }
  }
}
