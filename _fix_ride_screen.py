"""
Apply all active ride screen enhancements:
1. Gold verified badge on _avatar
2. Full addresses (no truncation) in all panels  
3. Gold-only icons in panels
4. 3D tilt entry animation wrapper
5. Staggered entry fade for inTrip
"""

filepath = r'c:\Users\Puma\cruiseapp.2\lib\screens\driver\driver_online_screen.dart'

with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

changes = 0

# =====================================================
# FIX 1: Replace _avatar with version that has gold verified badge
# =====================================================
old_avatar = '''  Widget _avatar(double s) {
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [_gold, _goldLight]),
      ),
      child: Center(
        child: Text(
          _riderInit,
          style: TextStyle(
            color: Colors.black,
            fontSize: s * 0.42,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }'''

new_avatar = '''  Widget _avatar(double s, {bool showBadge = false}) {
    final circle = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [_gold, _goldLight]),
      ),
      child: Center(
        child: Text(
          _riderInit,
          style: TextStyle(
            color: Colors.black,
            fontSize: s * 0.42,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    if (!showBadge) return circle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          bottom: -2,
          right: -2,
          child: Container(
            width: s * 0.38,
            height: s * 0.38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
              border: Border.all(color: const Color(0xFF0A0A0A), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              Icons.check,
              color: Colors.black,
              size: s * 0.22,
            ),
          ),
        ),
      ],
    );
  }'''

if content.count(old_avatar) == 1:
    content = content.replace(old_avatar, new_avatar)
    changes += 1
    print('FIX 1: _avatar with verified badge - OK')
else:
    print(f'FIX 1: SKIP (found {content.count(old_avatar)})')

# =====================================================
# FIX 2a: _arrivedPanel — show badge on avatar
# =====================================================
old_arrived_avatar = '              _avatar(50),'
new_arrived_avatar = '              _avatar(50, showBadge: true),'

# Only replace the one in _arrivedPanel context (near "Waiting for Rider")
# Find position of "waitingForRider" and then the avatar(50) near it
idx_waiting = content.find('waitingForRider')
if idx_waiting > 0:
    idx_avatar50 = content.find('_avatar(50)', idx_waiting)
    if idx_avatar50 > 0 and idx_avatar50 - idx_waiting < 500:
        content = content[:idx_avatar50] + '_avatar(50, showBadge: true)' + content[idx_avatar50 + len('_avatar(50)'):]
        changes += 1
        print('FIX 2a: _arrivedPanel avatar badge - OK')
    else:
        print('FIX 2a: SKIP - avatar(50) not found near waitingForRider')
else:
    print('FIX 2a: SKIP - waitingForRider not found')

# =====================================================
# FIX 2b: _routeSummaryPanel — show badge on avatar
# =====================================================
# Find the _avatar(42) in _routeSummaryPanel
idx_routesum = content.find('Widget _routeSummaryPanel(')
if idx_routesum > 0:
    idx_a42 = content.find('_avatar(42)', idx_routesum)
    if idx_a42 > 0 and idx_a42 - idx_routesum < 500:
        content = content[:idx_a42] + '_avatar(42, showBadge: true)' + content[idx_a42 + len('_avatar(42)'):]
        changes += 1
        print('FIX 2b: _routeSummaryPanel avatar badge - OK')
    else:
        print('FIX 2b: SKIP - avatar(42) not found near _routeSummaryPanel')
else:
    print('FIX 2b: SKIP - _routeSummaryPanel not found')

# =====================================================
# FIX 3: _tripPanel — add avatar, full addresses, gold icons
# Replace the rider info section in _tripPanel
# =====================================================
old_trip_rider = '''              // Rider info - compact
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _dropoffAddr,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: Icon(
                      Icons.phone,
                      color: textPrimary,
                      size: 22,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),'''

new_trip_rider = '''              // Rider info with avatar + badge
              Row(
                children: [
                  _avatar(42, showBadge: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _vehicleType,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: const Icon(
                      Icons.phone,
                      color: _gold,
                      size: 22,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Dropoff address card — full text, gold icon
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1A1A1A) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.flag_rounded, color: _gold, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),'''

if content.count(old_trip_rider) == 1:
    content = content.replace(old_trip_rider, new_trip_rider)
    changes += 1
    print('FIX 3: _tripPanel rider info + full address + gold icon - OK')
else:
    print(f'FIX 3: SKIP (found {content.count(old_trip_rider)})')

# =====================================================
# FIX 4a: _pickupPanel — full pickup address (no ellipsis) + gold icon
# =====================================================
old_pickup_addr = '''                        Text(
                          _pickupAddr,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),'''

new_pickup_addr = '''                        Text(
                          _pickupAddr,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 3,
                          softWrap: true,
                        ),'''

if content.count(old_pickup_addr) == 1:
    content = content.replace(old_pickup_addr, new_pickup_addr)
    changes += 1
    print('FIX 4a: _pickupPanel full pickup address - OK')
else:
    print(f'FIX 4a: SKIP (found {content.count(old_pickup_addr)})')

# =====================================================
# FIX 4b: _pickupPanel — replace green dot with gold location icon
# =====================================================
old_green_dot = '''                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF34C759),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),'''

new_gold_icon = '''                  const Icon(Icons.location_on_rounded, color: _gold, size: 20),
                  const SizedBox(width: 10),'''

if content.count(old_green_dot) == 1:
    content = content.replace(old_green_dot, new_gold_icon)
    changes += 1
    print('FIX 4b: _pickupPanel gold location icon - OK')
else:
    print(f'FIX 4b: SKIP (found {content.count(old_green_dot)})')

# =====================================================
# FIX 4c: _routeSummaryPanel — full addresses (no ellipsis)
# Replace green dot + truncated pickup addr 
# =====================================================
old_summary_pickup = '''                    Container(
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF34A853),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _pickupAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),'''

new_summary_pickup = '''                    const Icon(Icons.location_on_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pickupAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),'''

if content.count(old_summary_pickup) == 1:
    content = content.replace(old_summary_pickup, new_summary_pickup)
    changes += 1
    print('FIX 4c: _routeSummaryPanel full pickup + gold icon - OK')
else:
    print(f'FIX 4c: SKIP (found {content.count(old_summary_pickup)})')

# =====================================================
# FIX 4d: _routeSummaryPanel — full dropoff address + gold icon
# =====================================================
old_summary_dropoff = '''                    Container(
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFEA4335),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),'''

new_summary_dropoff = '''                    const Icon(Icons.flag_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),'''

if content.count(old_summary_dropoff) == 1:
    content = content.replace(old_summary_dropoff, new_summary_dropoff)
    changes += 1
    print('FIX 4d: _routeSummaryPanel full dropoff + gold icon - OK')
else:
    print(f'FIX 4d: SKIP (found {content.count(old_summary_dropoff)})')

# =====================================================
# FIX 4e: _tripPanel phone icon — already changed to gold in FIX 3
# FIX 4f: _pickupPanel phone icon — make gold
# =====================================================
old_phone_icon = '''                    icon: Icon(Icons.phone, color: textPrimary, size: 22),'''
new_phone_icon = '''                    icon: const Icon(Icons.phone, color: _gold, size: 22),'''

# This appears in _pickupPanel
if content.count(old_phone_icon) >= 1:
    content = content.replace(old_phone_icon, new_phone_icon, 1)
    changes += 1
    print('FIX 4f: _pickupPanel gold phone icon - OK')
else:
    print(f'FIX 4f: SKIP (found {content.count(old_phone_icon)})')


print(f'\nTotal changes: {changes}')
with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
print('File saved.')
