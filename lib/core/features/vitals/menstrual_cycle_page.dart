import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../i18n/locale.dart';
/// ====== KEYS ======
const _kMcLastStart = 'mc.last_start_date'; // ISO yyyy-MM-dd
const _kMcAvgCycle = 'mc.avg_cycle_days';   // int
const _kMcAvgPeriod = 'mc.avg_period_days'; // int
const _kMcLastNotes = 'mc.last_notes';      // String
const _kMcSymptoms = 'mc.symptoms';         // comma-separated set

/// ====== MODEL ======
class MenstrualState {
  final DateTime? lastStart;
  final int avgCycleDays;
  final int avgPeriodDays;
  final Set<String> symptoms;
  final String notes;

  const MenstrualState({
    required this.lastStart,
    required this.avgCycleDays,
    required this.avgPeriodDays,
    required this.symptoms,
    required this.notes,
  });

  MenstrualState copyWith({
    DateTime? lastStart,
    int? avgCycleDays,
    int? avgPeriodDays,
    Set<String>? symptoms,
    String? notes,
  }) {
    return MenstrualState(
      lastStart: lastStart ?? this.lastStart,
      avgCycleDays: avgCycleDays ?? this.avgCycleDays,
      avgPeriodDays: avgPeriodDays ?? this.avgPeriodDays,
      symptoms: symptoms ?? this.symptoms,
      notes: notes ?? this.notes,
    );
  }

  static const empty = MenstrualState(
    lastStart: null,
    avgCycleDays: 28,
    avgPeriodDays: 5,
    symptoms: <String>{},
    notes: '',
  );
}

/// ====== CONTROLLER ======
final menstrualProvider =
    StateNotifierProvider<MenstrualController, AsyncValue<MenstrualState>>(
  (ref) => MenstrualController(),
);

class MenstrualController extends StateNotifier<AsyncValue<MenstrualState>> {
  MenstrualController() : super(const AsyncLoading()) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final iso = p.getString(_kMcLastStart);
    DateTime? lastStart;
    if (iso != null && iso.isNotEmpty) {
      lastStart = DateTime.tryParse(iso);
    }
    final avgCycle = p.getInt(_kMcAvgCycle) ?? 28;
    final avgPeriod = p.getInt(_kMcAvgPeriod) ?? 5;
    final symptomsRaw = p.getString(_kMcSymptoms) ?? '';
    final notes = p.getString(_kMcLastNotes) ?? '';
    final set = symptomsRaw.isEmpty
        ? <String>{}
        : symptomsRaw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();

    state = AsyncData(
      MenstrualState(
        lastStart: lastStart,
        avgCycleDays: avgCycle,
        avgPeriodDays: avgPeriod,
        symptoms: set,
        notes: notes,
      ),
    );
  }

  Future<void> _save(MenstrualState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMcLastStart, s.lastStart?.toIso8601String() ?? '');
    await p.setInt(_kMcAvgCycle, s.avgCycleDays);
    await p.setInt(_kMcAvgPeriod, s.avgPeriodDays);
    await p.setString(_kMcSymptoms, s.symptoms.join(','));
    await p.setString(_kMcLastNotes, s.notes);
  }

  Future<void> update({
    DateTime? lastStart,
    int? avgCycleDays,
    int? avgPeriodDays,
    Set<String>? symptoms,
    String? notes,
  }) async {
    final current = state.value ?? MenstrualState.empty;
    final next = current.copyWith(
      lastStart: lastStart,
      avgCycleDays: avgCycleDays,
      avgPeriodDays: avgPeriodDays,
      symptoms: symptoms,
      notes: notes,
    );
    state = AsyncData(next);
    await _save(next);
  }

  Future<void> markStartToday() async {
    final today = DateTime.now();
    await update(lastStart: DateTime(today.year, today.month, today.day));
  }
}

/// ====== UI ======
class MenstrualCyclePage extends ConsumerStatefulWidget {
  const MenstrualCyclePage({super.key});
  @override
  ConsumerState<MenstrualCyclePage> createState() => _MenstrualCyclePageState();
}

class _MenstrualCyclePageState extends ConsumerState<MenstrualCyclePage> {
  final _avgCycleCtrl = TextEditingController();
  final _avgPeriodCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  @override
  void dispose() {
    _avgCycleCtrl.dispose();
    _avgPeriodCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(localeProvider);
    final t = T(lang);
    final theme = Theme.of(context);
    final sAsync = ref.watch(menstrualProvider);

    ref.listen<AsyncValue<MenstrualState>>(menstrualProvider, (prev, next) {
      next.whenOrNull(data: (s) {
        _avgCycleCtrl.text = s.avgCycleDays.toString();
        _avgPeriodCtrl.text = s.avgPeriodDays.toString();
        _notesCtrl.text = s.notes;
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(t.menstrualTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: sAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (s) {
          final pred = _predictionDates(s);
          final fertile = _fertileWindow(s);

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  _CardBlock(
                    icon: Icons.calendar_month_rounded,
                    title: t.cycleTracking,
                    child: Column(
                      children: [
                        _RowTile(
                          label: t.lastPeriodDate,
                          trailing: Text(
                            s.lastStart == null
                                ? '—'
                                : _formatDate(context, s.lastStart!),
                            style: theme.textTheme.bodyMedium,
                          ),
                          onTap: () async {
                            final now = DateTime.now();
                            final initial = s.lastStart ?? now;
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: initial,
                              firstDate: DateTime(now.year - 3),
                              lastDate: DateTime(now.year + 2),
                              helpText: t.lastPeriodDate,
                            );
                            if (picked != null) {
                              final d = DateTime(picked.year, picked.month, picked.day);
                              await ref.read(menstrualProvider.notifier).update(lastStart: d);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _NumberField(
                                label: t.avgCycleLen,
                                controller: _avgCycleCtrl,
                                suffix: t.days,
                                onSubmitted: (v) {
                                  final n = int.tryParse(v.trim());
                                  if (n == null || n < 15 || n > 60) return;
                                  ref.read(menstrualProvider.notifier).update(avgCycleDays: n);
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _NumberField(
                                label: t.avgPeriodLen,
                                controller: _avgPeriodCtrl,
                                suffix: t.days,
                                onSubmitted: (v) {
                                  final n = int.tryParse(v.trim());
                                  if (n == null || n < 1 || n > 14) return;
                                  ref.read(menstrualProvider.notifier).update(avgPeriodDays: n);
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.flag_rounded),
                                onPressed: () => ref.read(menstrualProvider.notifier).markStartToday(),
                                label: Text(t.markStartToday),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.check_circle_outline),
                                onPressed: s.lastStart == null ? null : () {
                                  // Optional: mark end today does not change prediction;
                                  // kept for UX symmetry – you may extend to store last end if needed.
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(t.markEndToday)),
                                  );
                                },
                                label: Text(t.markEndToday),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _CardBlock(
                    icon: Icons.event_available_rounded,
                    title: t.predictedNextPeriod,
                    child: Column(
                      children: [
                        _TwoCols(
                          leftLabel: t.predictedStart,
                          leftValue: pred.$1 == null ? '—' : _formatDate(context, pred.$1!),
                          rightLabel: t.predictedEnd,
                          rightValue: pred.$2 == null ? '—' : _formatDate(context, pred.$2!),
                        ),
                        const SizedBox(height: 12),
                        _RowTile(
                          label: t.fertileWindow,
                          trailing: Text(
                            (fertile.$1 == null || fertile.$2 == null)
                                ? '—'
                                : '${_formatDate(context, fertile.$1!)} — ${_formatDate(context, fertile.$2!)}',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _CardBlock(
                    icon: Icons.medical_information_outlined,
                    title: t.symptoms,
                    child: _SymptomsEditor(
                      t: t,
                      selected: s.symptoms,
                      onChanged: (set) => ref.read(menstrualProvider.notifier).update(symptoms: set),
                    ),
                  ),

                  const SizedBox(height: 16),

                  _CardBlock(
                    icon: Icons.sticky_note_2_outlined,
                    title: t.notes,
                    child: TextFormField(
                      controller: _notesCtrl,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: t.notes,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        isDense: true,
                        contentPadding: const EdgeInsets.all(12),
                      ),
                      onChanged: (v) =>
                          ref.read(menstrualProvider.notifier).update(notes: v),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Prediction: next period start = lastStart + avgCycleDays
  /// End = start + avgPeriodDays - 1
  (DateTime?, DateTime?) _predictionDates(MenstrualState s) {
    if (s.lastStart == null) return (null, null);
    final nextStart = s.lastStart!.add(Duration(days: s.avgCycleDays));
    final end = nextStart.add(Duration(days: s.avgPeriodDays - 1));
    return (DateTime(nextStart.year, nextStart.month, nextStart.day),
            DateTime(end.year, end.month, end.day));
  }

  /// Fertile window (approx.): ovulation ≈ lastStart + avgCycleDays - 14
  /// window = ovulation-5 .. ovulation+1
  (DateTime?, DateTime?) _fertileWindow(MenstrualState s) {
    if (s.lastStart == null) return (null, null);
    final ovul = s.lastStart!.add(Duration(days: s.avgCycleDays - 14));
    final from = ovul.subtract(const Duration(days: 5));
    final to = ovul.add(const Duration(days: 1));
    return (DateTime(from.year, from.month, from.day),
            DateTime(to.year, to.month, to.day));
  }

  String _formatDate(BuildContext c, DateTime d) {
    // Simple y-m-d; replace with intl if needed
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}

/// ===== WIDGETS =====
class _CardBlock extends StatelessWidget {
  const _CardBlock({required this.icon, required this.title, required this.child});
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({required this.label, this.trailing, this.onTap});
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: theme.textTheme.bodyMedium),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class _TwoCols extends StatelessWidget {
  const _TwoCols({
    required this.leftLabel,
    required this.leftValue,
    required this.rightLabel,
    required this.rightValue,
  });
  final String leftLabel, leftValue, rightLabel, rightValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(leftLabel, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(leftValue, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rightLabel, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(rightValue, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    this.suffix,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? suffix;
  final Function(String)? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      onFieldSubmitted: onSubmitted,
    );
  }
}

class _SymptomsEditor extends StatefulWidget {
  const _SymptomsEditor({
    required this.t,
    required this.selected,
    required this.onChanged,
  });

  final T t;
  final Set<String> selected;
  final Function(Set<String>) onChanged;

  @override
  State<_SymptomsEditor> createState() => _SymptomsEditorState();
}

class _SymptomsEditorState extends State<_SymptomsEditor> {
  late Set<String> _sel;

  @override
  void initState() {
    super.initState();
    _sel = {...widget.selected};
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;

    final items = <String, String>{
      'cramps': t.s_cramps,
      'headache': t.s_headache,
      'mood': t.s_mood,
      'acne': t.s_acne,
      'bloating': t.s_bloating,
      'fatigue': t.s_fatigue,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items.entries.map((e) {
            final selected = _sel.contains(e.key);
            return FilterChip(
              label: Text(e.value),
              selected: selected,
              onSelected: (v) {
                setState(() {
                  if (v) {
                    _sel.add(e.key);
                  } else {
                    _sel.remove(e.key);
                  }
                });
                widget.onChanged(_sel);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.savedSymptom)),
                );
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}
