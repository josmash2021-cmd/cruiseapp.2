import re

filepath = r'c:\Users\Puma\cruiseapp.2\lib\screens\driver\driver_online_screen.dart'

with open(filepath, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find _drawPreviewRoute method
start = None
for i, line in enumerate(lines):
    if 'Future<void> _drawPreviewRoute(LatLng o, LatLng d, String id, Color c) async {' in line:
        start = i
        break

if start is None:
    print('Method not found!')
    exit(1)

# Find the method end
end = start + 1
brace_count = 1
for i in range(start + 1, len(lines)):
    brace_count += lines[i].count('{') - lines[i].count('}')
    if brace_count == 0:
        end = i + 1
        break

print(f'Replacing _drawPreviewRoute at lines {start+1}-{end}')

new_method_lines = [
    '  Future<void> _drawPreviewRoute(LatLng o, LatLng d, String id, Color c) async {\n',
    '    List<LatLng>? pts;\n',
    '\n',
    '    // Try Google Directions API\n',
    '    try {\n',
    '      final uri =\n',
    "          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {\n",
    "            'origin': '${o.latitude},${o.longitude}',\n",
    "            'destination': '${d.latitude},${d.longitude}',\n",
    "            'key': ApiKeys.webServices,\n",
    "            'mode': 'driving',\n",
    '          });\n',
    '      final res = await http.get(uri).timeout(const Duration(seconds: 10));\n',
    '      if (res.statusCode == 200) {\n',
    '        final data = jsonDecode(res.body);\n',
    "        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {\n",
    '          pts = _decodePoly(\n',
    "            data['routes'][0]['overview_polyline']['points'] as String,\n",
    '          );\n',
    '        }\n',
    '      }\n',
    '    } catch (_) {}\n',
    '\n',
    '    // Fallback: OSRM\n',
    '    if (pts == null) {\n',
    '      try {\n',
    '        final path =\n',
    "            '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';\n",
    "        final uri = Uri.https('router.project-osrm.org', path, {\n",
    "          'overview': 'full',\n",
    "          'geometries': 'polyline',\n",
    '        });\n',
    '        final res = await http.get(uri).timeout(const Duration(seconds: 10));\n',
    '        final data = jsonDecode(res.body);\n',
    '        if (data is Map<String, dynamic> &&\n',
    "            data['code']?.toString().toUpperCase() == 'OK') {\n",
    "          final routes = data['routes'] as List?;\n",
    '          if (routes != null && routes.isNotEmpty) {\n',
    "            pts = _decodePoly(routes[0]['geometry'] as String);\n",
    '          }\n',
    '        }\n',
    '      } catch (_) {}\n',
    '    }\n',
    '\n',
    '    // Last resort: straight line\n',
    '    pts ??= List.generate(21, (i) {\n',
    '      final t = i / 20;\n',
    '      return LatLng(\n',
    '        o.latitude + (d.latitude - o.latitude) * t,\n',
    '        o.longitude + (d.longitude - o.longitude) * t,\n',
    '      );\n',
    '    });\n',
    '\n',
    '    // Snap first and last points to exact pin coordinates\n',
    '    if (pts.isNotEmpty) {\n',
    '      pts[0] = o;\n',
    '      pts[pts.length - 1] = d;\n',
    '    }\n',
    '\n',
    '    await _addPreviewPolyline(pts, c);\n',
    '  }\n',
    '\n',
]

lines[start:end] = new_method_lines

# ============================================================
# FIX 3: Layer order — pins must render on top of polylines
# Restructure _previewOfferRoute to draw polylines FIRST, pins SECOND
# ============================================================

# Find _previewOfferRoute method
prev_start = None
for i, line in enumerate(lines):
    if 'Future<void> _previewOfferRoute(Map<String, dynamic> offer) async {' in line:
        prev_start = i
        break

if prev_start is None:
    print('_previewOfferRoute not found!')
else:
    prev_end = prev_start + 1
    brace_count = 1
    for i in range(prev_start + 1, len(lines)):
        brace_count += lines[i].count('{') - lines[i].count('}')
        if brace_count == 0:
            prev_end = i + 1
            break

    print(f'Replacing _previewOfferRoute at lines {prev_start+1}-{prev_end}')

    # New method: draw polylines FIRST, then create pins on top
    new_preview = [
        '  Future<void> _previewOfferRoute(Map<String, dynamic> offer) async {\n',
        "    final pickupLat  = (offer['pickup_lat']  as num?)?.toDouble() ?? 0;\n",
        "    final pickupLng  = (offer['pickup_lng']  as num?)?.toDouble() ?? 0;\n",
        "    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;\n",
        "    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;\n",
        '    final pickupLL  = LatLng(pickupLat,  pickupLng);\n',
        '    final dropoffLL = LatLng(dropoffLat, dropoffLng);\n',
        '\n',
        '    setState(() => _previewingOffer = offer);\n',
        '    await _clearAllAnnotations();\n',
        '\n',
        '    // Step 1: Draw polylines FIRST (rendered below pins)\n',
        '    await Future.wait([\n',
        "      _drawPreviewRoute(_pos!,    pickupLL,  'prev_to_pickup', _gold),\n",
        "      _drawPreviewRoute(pickupLL, dropoffLL, 'prev_trip',      _gold),\n",
        '    ]);\n',
        '\n',
        '    // Step 2: Build and place pins AFTER polylines (pins render on top)\n',
        '    final results = await Future.wait([\n',
        '      _buildCruisePin(const Color(0xFF0D1B2A), const Color(0xFF5BA3F5), 26),\n',
        '      _buildCruisePin(const Color(0xFF0D1B2A), _gold, 26),\n',
        '      _buildCruisePin(Colors.white, const Color(0xFF0D1B2A), 26),\n',
        '    ]);\n',
        '\n',
        '    final pointMgr = _pointAnnotMgr;\n',
        '    if (pointMgr != null && mounted) {\n',
        '      if (results[0] != null) {\n',
        '        _prevDriverAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(\n',
        '          geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),\n',
        '          image: results[0],\n',
        '          iconSize: 1.0,\n',
        '          iconAnchor: mapbox.IconAnchor.BOTTOM,\n',
        '        ));\n',
        '      }\n',
        '      if (results[1] != null) {\n',
        '        _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(\n',
        '          geometry: mapbox.Point(coordinates: mapbox.Position(pickupLL.longitude, pickupLL.latitude)),\n',
        '          image: results[1],\n',
        '          iconSize: 1.0,\n',
        '          iconAnchor: mapbox.IconAnchor.BOTTOM,\n',
        '        ));\n',
        '      }\n',
        '      if (results[2] != null) {\n',
        '        _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(\n',
        '          geometry: mapbox.Point(coordinates: mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),\n',
        '          image: results[2],\n',
        '          iconSize: 1.0,\n',
        '          iconAnchor: mapbox.IconAnchor.BOTTOM,\n',
        '        ));\n',
        '      }\n',
        '    }\n',
        '\n',
        '    // Mark route as shown (triggers card shrink animation)\n',
        '    if (mounted && _previewingOffer != null) {\n',
        '      setState(() => _offerRouteShown = true);\n',
        '    }\n',
        '\n',
        '    // Fit camera to show all three points\n',
        '    if (!mounted) return;\n',
        '    await Future.delayed(const Duration(milliseconds: 200));\n',
        '    _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);\n',
        '\n',
        '    await Future.delayed(const Duration(milliseconds: 600));\n',
        '    if (mounted && _previewingOffer != null) {\n',
        '      _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);\n',
        '    }\n',
        '  }\n',
        '\n',
    ]

    lines[prev_start:prev_end] = new_preview

# ============================================================
# FIX 4: Track glow annotations for cleanup
# Add glow annotation variables and update cleanup
# ============================================================

# Add glow annotation vars next to existing preview annots
for i, line in enumerate(lines):
    if '_previewDropoffAnnot;' in line and 'PolylineAnnotation?' in line:
        # Add glow vars after this line
        lines.insert(i + 1, '  mapbox.PolylineAnnotation? _previewPickupGlow;\n')
        lines.insert(i + 2, '  mapbox.PolylineAnnotation? _previewDropoffGlow;\n')
        print(f'Added glow vars at line {i+2}')
        break

# Update _clearRouteAnnotation to also delete glow annotations
for i, line in enumerate(lines):
    if '_previewDropoffAnnot = null;' in line and i > 0 and '_previewDropoffAnnot!' in lines[i-1]:
        # Add glow cleanup after dropoff cleanup
        insert_idx = i + 1
        glow_cleanup = [
            '    if (_previewPickupGlow != null) {\n',
            '      try { await polyMgr.delete(_previewPickupGlow!); } catch (_) {}\n',
            '      _previewPickupGlow = null;\n',
            '    }\n',
            '    if (_previewDropoffGlow != null) {\n',
            '      try { await polyMgr.delete(_previewDropoffGlow!); } catch (_) {}\n',
            '      _previewDropoffGlow = null;\n',
            '    }\n',
        ]
        for j, gl in enumerate(glow_cleanup):
            lines.insert(insert_idx + j, gl)
        print(f'Added glow cleanup at line {insert_idx+1}')
        break

# Update _addPreviewPolyline to store glow annotations
# Find "_previewPickupAnnot = annot;" and add glow storage after it
for i, line in enumerate(lines):
    if '_previewPickupAnnot = annot;' in line and 'null' not in line:
        # Next line should be close of if block, then else
        # Add glow storage
        lines.insert(i + 1, '      _previewPickupGlow = glowAnnot;\n')
        print(f'Added pickup glow storage at line {i+2}')
        break

# Find "_previewDropoffAnnot = annot;" and add glow storage after it
for i, line in enumerate(lines):
    if '_previewDropoffAnnot = annot;' in line and 'null' not in line:
        lines.insert(i + 1, '      _previewDropoffGlow = glowAnnot;\n')
        print(f'Added dropoff glow storage at line {i+2}')
        break

with open(filepath, 'w', encoding='utf-8') as f:
    f.writelines(lines)

print('\nAll fixes applied and saved!')
