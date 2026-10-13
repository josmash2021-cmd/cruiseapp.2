import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/vehicle_tier_style.dart';

/// Guardian for the Electric Pro tier (user spec 2026-10-13):
///   1. The rate card is the exact Standard↔Premium midpoint.
///   2. The booking sheet lists it between SUV XL and Sedan, capacity 5, ⚡.
///   3. Every render of car_electric.png falls back in a chain: bundled
///      asset → backend-hosted /static copy (OTA rule: Shorebird patches
///      carry no new assets, so patched phones stream it from the
///      backend) → the long-bundled side-profile render.
///   4. The "Meet Electric Pro" sheet has its own copy (ES/EN).
///   5. vehicle_tier_style knows the tier (key, photo, colour, icon).
///   6. The request sends the option NAME ('Electric Pro'), which the
///      backend normalises to `electric_pro`.
///   7. The scheduled-cancel fee is $20 in both mirrored sources.
///   8. The gold-bolt badge (bolt_badge.png, with the widget-composed OTA
///      fallback) marks the tier's card top-right — home fleet carousel AND
///      booking tier row, Electric Pro only.
///
/// Source-grep style, like schedule_hub_guard_test.dart.
void main() {
  final controller =
      File('lib/state/rider_trip_controller.dart').readAsStringSync();
  final widgets =
      File('lib/screens/ride_request_widgets.dart').readAsStringSync();
  final style = File('lib/utils/vehicle_tier_style.dart').readAsStringSync();
  final detail = File('lib/widgets/tier_detail_sheet.dart').readAsStringSync();
  final home = File('lib/screens/home_screen_widgets.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  group('rate card', () {
    test('anchorRates carries the exact midpoint card', () {
      expect(controller, contains("case 'electric_pro':"));
      expect(controller, contains('return (2.50, 1.40, 0.25, 2.60, 10.00);'),
          reason: 'the Standard↔Premium midpoint, pinned by the spec');
    });

    test('the option prices itself off its own anchor', () {
      expect(controller, contains("anchoredTotal('electric_pro')"));
    });
  });

  group('the booking option', () {
    test('exists between SUV XL and Sedan, capacity 5, bolt icon', () {
      final optStart = controller.indexOf("id: 'electric_pro',");
      expect(optStart, greaterThan(-1));
      final suvXl = controller.indexOf("id: 'suv_xl',");
      final sedan = controller.indexOf("id: 'camry',");
      expect(suvXl, lessThan(optStart),
          reason: 'Electric Pro sorts after SUV XL (Premium)');
      expect(optStart, lessThan(sedan),
          reason: 'Electric Pro sorts before Sedan (Compact)');
      final optBlock = controller.substring(optStart, optStart + 400);
      expect(optBlock, contains("name: 'Electric Pro'"));
      expect(optBlock,
          contains("description: 'Electric • Zero emissions • Silent ride'"));
      expect(optBlock, contains("icon: '⚡'"));
      expect(optBlock, contains('capacity: 5'));
      expect(optBlock, contains('etaMinutes: baseDuration + 2'));
    });

    test('the sheet keeps it between suv_xl and camry in the pinned order',
        () {
      expect(
          widgets,
          contains(
              "['suburban', 'suv_xl', 'electric_pro', 'camry', 'fusion']"));
    });

    test('the display name is Electric Pro (never Compact by fallthrough)',
        () {
      final start = widgets.indexOf('static String _tierDisplayName(');
      final block = widgets.substring(start, start + 700);
      expect(block, contains("opt.id == 'electric_pro'"));
      expect(block, contains("'Electric Pro'"));
    });

    test('the wait-estimate tier key is electric_pro, not a neighbour', () {
      final start = widgets.indexOf('String _tierKeyForOption(');
      final block = widgets.substring(start, start + 400);
      expect(block, contains("case 'electric_pro':"));
      expect(block, contains("return 'electric_pro';"));
    });

    test('a placeholder tier exists so the skeleton count matches', () {
      final start = widgets.indexOf('List<RideOption> _placeholderTiers()');
      final block = widgets.substring(start, start + 1400);
      expect(block, contains("id: 'electric_pro'"));
    });
  });

  group('the photo and the OTA fallback', () {
    test('the booking card maps the option to car_electric.png', () {
      final start = widgets.indexOf('String _carAssetForOption(');
      final block = widgets.substring(start, start + 500);
      expect(block, contains("key.contains('electric')"));
      expect(block, contains('car_electric.png'));
    });

    test('every card render of it errorBuilder-falls to cruisert_compact', () {
      // Booking tier row (CarImage3D fallback).
      expect(widgets, contains("opt.id == 'electric_pro'"));
      expect(widgets, contains('cruisert_compact.png'),
          reason: 'the booking card falls back to the SIDE-PROFILE compact '
              'SUV — never the top-down map sprite (user report 2026-10-13)');
      // Home fleet card, Meet-tier sheet, ride summary, tracking card.
      final sites = <String, String>{
        'home fleet card': home,
        'tier detail sheet': detail,
        'ride summary':
            File('lib/screens/ride_request_controller.dart').readAsStringSync(),
        'tracking driver card':
            File('lib/widgets/tracking/driver_info_card.dart')
                .readAsStringSync(),
        'trip receipt':
            File('lib/screens/trip_receipt_screen.dart').readAsStringSync(),
        'ride history':
            File('lib/screens/ride_history_screen.dart').readAsStringSync(),
        'ride options sheet':
            File('lib/screens/ride_options_sheet.dart').readAsStringSync(),
      };
      for (final e in sites.entries) {
        expect(e.value, contains('car_electric.png'),
            reason: '${e.key} never renders the electric PNG');
        expect(e.value, contains('otaImageFallback('),
            reason: '${e.key}: the /static network rung (OTA photos, user '
                'spec 2026-10-13) is missing');
        expect(e.value, contains('cruisert_compact.png'),
            reason: '${e.key}: the OTA fallback is not the side-profile '
                'compact SUV');
      }
    });

    test('the OTA image chain helper + the backend-hosted twins exist', () {
      final ota = File('lib/widgets/ota_image.dart').readAsStringSync();
      expect(ota, contains('ApiService.currentBaseUrl'));
      expect(ota, contains('/static/'));
      expect(ota, contains('Image.network'));
      for (final f in [
        'car_electric.png',
        'bolt_badge.png',
        'driver_tier_electric.png',
      ]) {
        expect(File('backend/static/$f').existsSync(), isTrue,
            reason: '$f must ride the backend deploy or patched phones '
                'have nothing to stream');
      }
      final badge =
          File('lib/widgets/electric_bolt_badge.dart').readAsStringSync();
      expect(badge, contains("otaImageFallback("),
          reason: 'the bolt badge streams from /static on patched builds');
      final splash = File('lib/screens/splash_screen.dart').readAsStringSync();
      expect(splash, contains("'/static/car_electric.png'"),
          reason: 'precached at boot so the fallback paints instantly');
    });

    test('map markers use the top-down SUV for electric, never the profile', () {
      // A map marker is a TOP-DOWN sprite: car_electric.png is a card
      // render (side profile) and would be wrong even after the store build
      // carries it — the marker spots use car_suv.png outright.
      final markers = {
        'lib/widgets/tracking/tracking_map_view.dart':
            "rideName.contains('electric')",
        'lib/map/tracking_map_car.dart':
            "rideNameLower.contains('electric')",
        'lib/screens/rider_confirm_pickup_screen.dart':
            "rideName.contains('electric')",
      };
      for (final e in markers.entries) {
        final src = File(e.key).readAsStringSync();
        expect(src, contains(e.value),
            reason: '${e.key} does not branch on electric');
        final i = src.indexOf(e.value);
        final window = src.substring(i, i + 400);
        expect(window, contains('car_suv.png'),
            reason: '${e.key}: the electric map marker is not the top-down SUV');
        expect(window, isNot(contains('car_electric.png')),
            reason: '${e.key}: the side profile must never be the map marker');
      }
    });

    test('the asset exists in the repo and the fallback is long-bundled', () {
      expect(File('assets/images/car_electric.png').existsSync(), isTrue);
      expect(File('assets/images/cruisert_compact.png').existsSync(), isTrue);
      // Bundled wholesale — no pubspec entry to forget.
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('- assets/images/'));
    });
  });

  group('the Meet-tier sheet copy', () {
    test('has its own tagline and three bullets', () {
      expect(detail, contains("case 'electric_pro':"));
      expect(detail, contains('s.tierTaglineElectricPro'));
      for (final key in [
        'tierBulletElectricPro1',
        'tierBulletElectricPro2',
        'tierBulletElectricPro3',
      ]) {
        expect(detail, contains('s.$key'), reason: 'missing $key');
      }
    });

    test('the copy is bilingual', () {
      for (final key in [
        'tierTaglineElectricPro',
        'tierBulletElectricPro1',
        'tierBulletElectricPro2',
        'tierBulletElectricPro3',
        'tierDescElectricPro',
        'fleetElectricProDesc',
      ]) {
        final start = l10n.indexOf('get $key');
        expect(start, greaterThan(-1), reason: '$key missing from S');
        expect(l10n.substring(start, start + 260), contains('_es'),
            reason: '$key must resolve ES/EN like its siblings');
      }
    });
  });

  group('vehicle_tier_style knows the tier', () {
    test('the key is canonical and survives display-name spellings', () {
      expect(kVehicleTiers, contains(kTierElectricPro));
      expect(tierKey('electric_pro'), kTierElectricPro);
      expect(tierKey('Electric Pro'), kTierElectricPro);
      expect(tierKey('electric'), kTierElectricPro);
      expect(tripTierKey('Electric Pro'), kTierElectricPro);
      expect(tripTierKey('electric_pro'), kTierElectricPro);
    });

    test('photo, colour and icon are its own', () {
      expect(style, contains('kTierElectricPro'));
      expect(tierCarImage('electric_pro'), 'assets/images/car_electric.png');
      expect(tierColor('electric_pro'), isNot(tierColor('standard')));
      expect(tierIcon('electric_pro'), isNot(tierIcon('standard')));
    });
  });

  group('the request sends electric_pro to the backend', () {
    test('the option name travels as vehicleType, unmapped', () {
      // The backend normalises "Electric Pro" -> "electric_pro" (spaces to
      // underscores); any app-side remap would break that contract.
      expect(controller,
          contains('vehicleType: _state.selectedOption?.name,'));
      final booking =
          File('lib/screens/ride_request_controller.dart').readAsStringSync();
      expect(booking, contains('vehicleType: state.selectedOption?.name,'));
    });

    test('the home fleet card enters the flow with rideId electric_pro', () {
      expect(home, contains("'rideId': 'electric_pro'"));
      expect(home,
          contains("'electric_pro' => ('Electric Pro', 'electric_pro')"));
    });
  });

  group('the bolt badge (user spec 2026-10-13)', () {
    final badge =
        File('lib/widgets/electric_bolt_badge.dart').readAsStringSync();

    test('is ONE reusable widget, with the widget-composed OTA fallback', () {
      expect(badge, contains('class ElectricBoltBadge'));
      expect(badge, contains("'assets/images/bolt_badge.png'"));
      // No broken image on phones without the asset: the errorBuilder
      // composes the same badge from widgets — dark ring, gold bolt.
      expect(badge, contains('errorBuilder'));
      expect(badge, contains('0xFF1A1A22'), reason: 'the dark ring');
      expect(badge, contains('Icons.bolt_rounded'));
      expect(badge, contains('0xFFE8C547'), reason: 'the gold bolt');
      expect(badge, contains('IgnorePointer'),
          reason: 'decorative — it must never eat the card tap');
      expect(File('assets/images/bolt_badge.png').existsSync(), isTrue);
    });

    test('rides the home fleet card, top-right, Electric Pro only', () {
      final start = home.indexOf('Widget _buildFleetStack(');
      final block = home.substring(start, start + 10500);
      expect(block, contains('ElectricBoltBadge('));
      // The single badge site is gated on the tier id — the other four
      // cards never wear it.
      expect('ElectricBoltBadge('.allMatches(block).length, 1,
          reason: 'one badge site in the carousel, not one per card');
      final i = block.indexOf('ElectricBoltBadge(');
      expect(block.substring(i - 400, i),
          contains("v['rideId'] == 'electric_pro'"));
      expect(block.substring(i - 400, i), contains('Positioned('));
      expect(block.substring(i - 400, i), contains(RegExp(r'top: -\d')));
      expect(block.substring(i - 400, i), contains(RegExp(r'right: -\d')),
          reason: 'a small negative offset so it sticks out of the corner');
    });

    test('rides the booking tier row, top-right, Electric Pro only', () {
      final start = widgets.indexOf('Widget _buildTierRow(');
      final end = widgets.indexOf('Widget _buildTierExpandedDetail(');
      final block = widgets.substring(start, end);
      expect(block, contains('ElectricBoltBadge('));
      expect('ElectricBoltBadge('.allMatches(block).length, 1,
          reason: 'one badge site in the row, not one per tier');
      final i = block.indexOf('ElectricBoltBadge(');
      expect(block.substring(i - 500, i),
          contains("opt.id == 'electric_pro'"));
      expect(block.substring(i - 500, i), contains('Positioned('));
      expect(block.substring(i - 500, i), contains(RegExp(r'top: ')));
      expect(block.substring(i - 500, i), contains(RegExp(r'right: -\d')));
    });
  });

  group('the scheduled-cancel fee mirror (\$20)', () {
    test('both sources carry the tier at the midpoint price', () {
      final policy =
          File('lib/screens/schedule_cancel_policy_screen.dart')
              .readAsStringSync();
      expect(policy, contains("'Electric Pro': 20"));
      final tripsPy = File('backend/routers/trips.py').readAsStringSync();
      expect(tripsPy, contains('"electric_pro": 20.0'));
    });

    test('the hub estimate resolves the Electric Pro label', () {
      final hub =
          File('lib/screens/schedule_hub_screen.dart').readAsStringSync();
      expect(hub, contains('kTierElectricPro'));
      expect(hub, contains("'Electric Pro'"),
          reason: 'feeTier electric_pro must look up the Electric Pro row, '
              'not fall through to the \$15 default');
    });
  });
}
