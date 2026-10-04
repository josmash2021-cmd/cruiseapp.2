import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/config/agent_prompts.dart';

/// The support chat's two assistants, pinned app-side (2026-10-02
/// redesign): rider and driver quick actions open different doors, and
/// each list carries the capabilities the role's AI actually has —
/// rider: payments/trip/report/cancel; driver: earnings/docs/tier/trip.
void main() {
  group('rider quick actions', () {
    final labelsEs =
        AgentPrompts.riderQuickActions(true).map((a) => a['label']!).toList();
    final labelsEn =
        AgentPrompts.riderQuickActions(false).map((a) => a['label']!).toList();

    test('cover payments, trip/stop, report and cancel — bilingual', () {
      expect(labelsEs, hasLength(5));
      expect(labelsEn, hasLength(5));
      expect(labelsEs.join('|'), contains('cobro'));
      expect(labelsEs.join('|'), contains('parada'));
      expect(labelsEs.join('|'), contains('Reportar conductor'));
      expect(labelsEs.join('|'), contains('Cancelar mi viaje'));
      expect(labelsEn.join('|'), contains('Cancel my trip'));
    });

    test('nothing about earnings, documents or tiers — that is the other seat',
        () {
      final all = labelsEs.join('|').toLowerCase();
      expect(all, isNot(contains('ganancias')));
      expect(all, isNot(contains('documentos')));
      expect(all, isNot(contains('categoría')));
    });
  });

  group('driver quick actions', () {
    final labels =
        AgentPrompts.driverQuickActions(true).map((a) => a['label']!).toList();

    test('cover earnings, documents, tier and the active trip', () {
      expect(labels, hasLength(5));
      expect(labels.join('|'), contains('Ganancias y payouts'));
      expect(labels.join('|'), contains('Documentos y vehículo'));
      expect(labels.join('|'), contains('categoría'));
      expect(labels.join('|'), contains('Viaje activo'));
    });

    test('nothing about cancels or refunds — dispatch-human territory', () {
      final all = labels.join('|').toLowerCase();
      expect(all, isNot(contains('cancelar')));
      expect(all, isNot(contains('reembolso')));
    });
  });
}
