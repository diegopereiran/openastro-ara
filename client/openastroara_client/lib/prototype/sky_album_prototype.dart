// PROTOTYPE — throwaway. Three structurally different Sky Album layouts on one
// screen, switched by the floating bar (or ← →). Real Messier/Caldwell rows
// from the bundled catalog; collection state is fake and deterministic.
// Assumption: no host page exists yet, so this is a standalone entrypoint on
// the real theme rather than a route inside the Simple shell.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bundled_catalogs.dart';
import '../services/dso_catalog_service.dart';
import '../theme/ara_colors.dart';

enum Tier { none, bronze, silver, gold }

class FakeCard {
  final PlanningDso dso;
  final int number;
  final Tier tier;
  final double hours;
  final int frames;
  final DateTime? first;
  final List<String> filters;
  final double? score;
  final bool wellPlacedTonight;
  FakeCard(this.dso, this.number, this.tier, this.hours, this.frames,
      this.first, this.filters, this.score, this.wellPlacedTonight);
  String get label => dso.messierNum != null ? 'M $number' : 'C $number';
}

List<FakeCard> fakeBook(List<PlanningDso> all, {required bool messier}) {
  final rows = all
      .where((d) => messier ? d.messierNum != null : d.caldwellNum != null)
      .toList()
    ..sort((a, b) => (messier ? a.messierNum! : a.caldwellNum!)
        .compareTo(messier ? b.messierNum! : b.caldwellNum!));
  final rnd = math.Random(messier ? 31 : 109);
  return [
    for (final d in rows)
      () {
        final n = messier ? d.messierNum! : d.caldwellNum!;
        final r = rnd.nextDouble();
        final tier = r < 0.55
            ? Tier.none
            : r < 0.75
                ? Tier.bronze
                : r < 0.92
                    ? Tier.silver
                    : Tier.gold;
        final hours = switch (tier) {
          Tier.none => 0.0,
          Tier.bronze => rnd.nextDouble() * 0.9,
          Tier.silver => 1 + rnd.nextDouble() * 3.9,
          Tier.gold => 5 + rnd.nextDouble() * 10,
        };
        return FakeCard(
          d,
          n,
          tier,
          hours,
          tier == Tier.none ? 0 : (hours * 20).ceil() + 1,
          tier == Tier.none
              ? null
              : DateTime(2026, 1 + rnd.nextInt(10), 1 + rnd.nextInt(27)),
          tier == Tier.none
              ? const []
              : (rnd.nextBool() ? ['L', 'R', 'G', 'B'] : ['Ha', 'OIII']),
          tier == Tier.none ? null : 0.5 + rnd.nextDouble() * 0.5,
          rnd.nextDouble() < 0.25,
        );
      }(),
  ];
}

IconData silhouette(String type) => switch (type) {
      'G' || 'GPair' || 'GTrpl' || 'GGroup' => Icons.blur_circular,
      'OCl' => Icons.grain,
      'GCl' => Icons.blur_on,
      'PN' => Icons.radio_button_checked,
      'SNR' => Icons.flare,
      'DrkN' => Icons.cloud_outlined,
      _ => Icons.cloud,
    };

Color tierColor(Tier t) => switch (t) {
      Tier.none => AraColors.border,
      Tier.bronze => const Color(0xFFB87333),
      Tier.silver => const Color(0xFFC0C0C0),
      Tier.gold => const Color(0xFFFFD54F),
    };

String tierName(Tier t) => switch (t) {
      Tier.none => 'Missing',
      Tier.bronze => 'Bronze',
      Tier.silver => 'Silver',
      Tier.gold => 'Gold',
    };

/// Stand-in for the user's best frame: a seeded gradient, since the prototype
/// has no frames. Grey silhouette when the card is missing.
class CardArt extends StatelessWidget {
  const CardArt(this.c, {super.key, this.radius = 10});
  final FakeCard c;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final missing = c.tier == Tier.none;
    final seed = c.number * 7919;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        decoration: BoxDecoration(
          gradient: missing
              ? null
              : RadialGradient(colors: [
                  HSLColor.fromAHSL(1, (seed % 360).toDouble(), 0.5, 0.35)
                      .toColor(),
                  const Color(0xFF0B0B14),
                ], radius: 0.9),
          color: missing ? AraColors.bgPanelAlt : null,
        ),
        child: Center(
          child: Icon(silhouette(c.dso.type),
              size: 36,
              color: missing ? AraColors.textDisabled : Colors.white24),
        ),
      ),
    );
  }
}

void showCardBack(BuildContext context, FakeCard c, void Function(FakeCard) go) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AraColors.bgPanel,
    builder: (_) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 72, height: 100, child: CardArt(c)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c.label} · ${c.dso.name}', style: Theme.of(context).textTheme.titleMedium),
            Text(c.dso.type, style: const TextStyle(color: AraColors.textSecondary)),
            const SizedBox(height: 6),
            Chip(label: Text(tierName(c.tier)), backgroundColor: tierColor(c.tier).withValues(alpha: 0.25)),
          ])),
        ]),
        const SizedBox(height: 12),
        if (c.tier == Tier.none)
          const Text('Not collected yet.', style: TextStyle(color: AraColors.textSecondary))
        else ...[
          _kv('First capture', '${c.first!.year}-${c.first!.month.toString().padLeft(2, '0')}-${c.first!.day.toString().padLeft(2, '0')}'),
          _kv('Integration', '${c.hours.toStringAsFixed(1)} h · ${c.frames} lights'),
          _kv('Filters', c.filters.join(', ')),
          _kv('Gear profile', 'Backyard refractor'),
          _kv('Best frame score', c.score!.toStringAsFixed(2)),
          _kv('Next tier', c.tier == Tier.gold ? 'Reached' : '${(c.tier == Tier.bronze ? 1 - c.hours : 5 - c.hours).toStringAsFixed(1)} h to go'),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () { Navigator.pop(context); go(c); },
          icon: const Icon(Icons.play_arrow),
          label: Text(c.tier == Tier.none ? 'Image this target' : 'Add more time'),
        ),
      ]),
    ),
  );
}

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 130, child: Text(k, style: const TextStyle(color: AraColors.textSecondary))),
        Text(v),
      ]),
    );

// ───────────────────────── Variant A: Binder ─────────────────────────
// Trading-card binder: book tabs, 2.5:3.5 cards in a grid, tier foil border.
class VariantA extends StatelessWidget {
  const VariantA(this.cards, this.go, {super.key});
  static const name = 'Binder grid';
  final List<FakeCard> cards;
  final void Function(FakeCard) go;
  @override
  Widget build(BuildContext context) {
    final have = cards.where((c) => c.tier != Tier.none).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Text('${have} / ${cards.length} collected', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          for (final t in [Tier.gold, Tier.silver, Tier.bronze])
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(children: [
                Icon(Icons.circle, size: 10, color: tierColor(t)),
                const SizedBox(width: 3),
                Text('${cards.where((c) => c.tier == t).length}'),
              ]),
            ),
        ]),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130, childAspectRatio: 2.5 / 3.5, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemCount: cards.length,
          itemBuilder: (_, i) {
            final c = cards[i];
            return GestureDetector(
              onTap: () => showCardBack(context, c, go),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tierColor(c.tier), width: c.tier == Tier.none ? 1 : 2.5),
                  boxShadow: c.tier == Tier.gold
                      ? [BoxShadow(color: tierColor(Tier.gold).withValues(alpha: 0.5), blurRadius: 10)]
                      : null,
                  color: AraColors.bgPanel,
                ),
                padding: const EdgeInsets.all(5),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: CardArt(c, radius: 8)),
                  const SizedBox(height: 4),
                  Text(c.label, style: TextStyle(fontWeight: FontWeight.bold, color: c.tier == Tier.none ? AraColors.textDisabled : AraColors.textPrimary)),
                  Text(c.dso.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.tier == Tier.none ? AraColors.textDisabled : AraColors.textSecondary)),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ───────────────────────── Variant B: Ledger ─────────────────────────
// Checklist by object type with per-group progress; rows, not cards.
class VariantB extends StatelessWidget {
  const VariantB(this.cards, this.go, {super.key});
  static const name = 'Ledger by type';
  final List<FakeCard> cards;
  final void Function(FakeCard) go;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<FakeCard>>{};
    for (final c in cards) {
      (groups[_groupName(c.dso.type)] ??= []).add(c);
    }
    final have = cards.where((c) => c.tier != Tier.none).length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 80), children: [
      Row(children: [
        SizedBox(
          width: 72, height: 72,
          child: Stack(fit: StackFit.expand, children: [
            CircularProgressIndicator(value: have / cards.length, strokeWidth: 7, color: AraColors.accentInfo, backgroundColor: AraColors.border),
            Center(child: Text('${(100 * have / cards.length).round()}%', style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text('$have of ${cards.length} collected\n${cards.where((c) => c.tier == Tier.gold).length} gold', style: Theme.of(context).textTheme.titleMedium)),
      ]),
      const SizedBox(height: 12),
      for (final e in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Row(children: [
            Text(e.key.toUpperCase(), style: const TextStyle(color: AraColors.textSecondary, letterSpacing: 1.2, fontSize: 12)),
            const SizedBox(width: 10),
            Expanded(child: LinearProgressIndicator(value: e.value.where((c) => c.tier != Tier.none).length / e.value.length, minHeight: 4, color: AraColors.accentInfo, backgroundColor: AraColors.border)),
            const SizedBox(width: 10),
            Text('${e.value.where((c) => c.tier != Tier.none).length}/${e.value.length}', style: const TextStyle(color: AraColors.textSecondary, fontSize: 12)),
          ]),
        ),
        for (final c in e.value)
          ListTile(
            dense: true,
            onTap: () => showCardBack(context, c, go),
            leading: SizedBox(width: 34, height: 48, child: CardArt(c, radius: 5)),
            title: Text('${c.label}  ${c.dso.name}', style: TextStyle(color: c.tier == Tier.none ? AraColors.textDisabled : null)),
            subtitle: c.tier == Tier.none ? null : Text('${c.hours.toStringAsFixed(1)} h · ${c.filters.join(' ')}'),
            trailing: c.tier == Tier.none
                ? (c.wellPlacedTonight ? const Icon(Icons.nightlight_round, color: AraColors.accentBusy, size: 18) : const Icon(Icons.check_box_outline_blank, color: AraColors.textDisabled))
                : Icon(Icons.verified, color: tierColor(c.tier)),
          ),
      ],
    ]);
  }

  static String _groupName(String t) => switch (t) {
        'G' || 'GPair' || 'GTrpl' || 'GGroup' => 'Galaxies',
        'OCl' => 'Open clusters',
        'GCl' => 'Globular clusters',
        'PN' => 'Planetary nebulae',
        'SNR' => 'Supernova remnants',
        _ => 'Nebulae',
      };
}

// ───────────────────────── Variant C: Shelves ─────────────────────────
// Tonight-first: horizontal shelves ranked by what to do next, grid demoted.
class VariantC extends StatelessWidget {
  const VariantC(this.cards, this.go, {super.key});
  static const name = 'Tonight-first shelves';
  final List<FakeCard> cards;
  final void Function(FakeCard) go;
  @override
  Widget build(BuildContext context) {
    final missingTonight = cards.where((c) => c.tier == Tier.none && c.wellPlacedTonight).toList();
    final nearTier = cards.where((c) => c.tier == Tier.bronze && c.hours > 0.6 || c.tier == Tier.silver && c.hours > 4).toList();
    final recent = (cards.where((c) => c.tier != Tier.none).toList()..sort((a, b) => b.first!.compareTo(a.first!))).take(12).toList();
    final missingRest = cards.where((c) => c.tier == Tier.none && !c.wellPlacedTonight).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 80), children: [
      _shelf(context, '${missingTonight.length} missing cards well placed tonight', missingTonight, primary: true),
      _shelf(context, 'Close to the next tier', nearTier),
      _shelf(context, 'Recently collected', recent),
      _shelf(context, 'Still missing (${missingRest.length})', missingRest, small: true),
    ]);
  }

  Widget _shelf(BuildContext context, String title, List<FakeCard> items, {bool primary = false, bool small = false}) {
    if (items.isEmpty) return const SizedBox.shrink();
    final h = small ? 110.0 : 170.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Row(children: [
          if (primary) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.nightlight_round, color: AraColors.accentBusy, size: 18)),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          if (primary) FilledButton(onPressed: () => go(items.first), child: const Text('Start with the first')),
        ]),
      ),
      SizedBox(
        height: h,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final c = items[i];
            return GestureDetector(
              onTap: () => showCardBack(context, c, go),
              child: SizedBox(
                width: h * 0.72,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: tierColor(c.tier), width: 2)),
                      child: CardArt(c),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text('${c.label} ${c.dso.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ───────────────────────── Host + switcher ─────────────────────────
class SkyAlbumPrototype extends StatefulWidget {
  const SkyAlbumPrototype({super.key});
  @override
  State<SkyAlbumPrototype> createState() => _SkyAlbumPrototypeState();
}

class _SkyAlbumPrototypeState extends State<SkyAlbumPrototype> {
  static const variants = ['A', 'B', 'C'];
  static const names = {'A': VariantA.name, 'B': VariantB.name, 'C': VariantC.name};
  int _v = 0;
  bool _messier = true;
  late final Future<List<PlanningDso>> _catalog = loadBundledCatalogs();
  final _focus = FocusNode();

  void _go(FakeCard c) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('callback: start imaging ${c.label} ${c.dso.name}')));

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focus..requestFocus(),
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) setState(() => _v = (_v + 1) % 3);
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) setState(() => _v = (_v + 2) % 3);
      },
      child: Scaffold(
        backgroundColor: AraColors.bgPrimary,
        appBar: AppBar(
          title: const Text('Sky Album'),
          actions: [
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Messier')), ButtonSegment(value: false, label: Text('Caldwell'))],
              selected: {_messier},
              onSelectionChanged: (s) => setState(() => _messier = s.first),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: FutureBuilder<List<PlanningDso>>(
          future: _catalog,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final cards = fakeBook(snap.data!, messier: _messier);
            return Stack(children: [
              switch (variants[_v]) {
                'A' => VariantA(cards, _go),
                'B' => VariantB(cards, _go),
                _ => VariantC(cards, _go),
              },
              if (kDebugMode)
                Positioned(
                  bottom: 16, left: 0, right: 0,
                  child: Center(
                    child: Material(
                      color: Colors.white,
                      elevation: 8,
                      borderRadius: BorderRadius.circular(30),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.chevron_left, color: Colors.black), onPressed: () => setState(() => _v = (_v + 2) % 3)),
                        Text('${variants[_v]} (${names[variants[_v]]})', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                        IconButton(icon: const Icon(Icons.chevron_right, color: Colors.black), onPressed: () => setState(() => _v = (_v + 1) % 3)),
                      ]),
                    ),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
