import 'dart:async';
import 'package:flutter/material.dart';
import '../services/places_service.dart';

class PlaceSearchField extends StatefulWidget {
  final String hint;
  final Function(PlaceDetails) onSelected;
  final String apiKey;

  const PlaceSearchField({
    super.key,
    required this.hint,
    required this.onSelected,
    required this.apiKey,
  });

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  late final PlacesService _service;
  Timer? _debounce;
  List<PlaceSuggestion> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _service = PlacesService(widget.apiKey);
  }

  void _onChanged(String val) {
    _debounce?.cancel();
    if (val.length < 2) {
      setState(() {
        _results = [];
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _loading = true);
      final r = await _service.autocomplete(val);
      if (!mounted) return;
      setState(() {
        _results = r;
        _loading = false;
      });
    });
  }

  Future<void> _onSelect(PlaceSuggestion s) async {
    _ctrl.text = s.description;
    setState(() {
      _results = [];
      _loading = true;
    });
    _focus.unfocus();
    final d = await _service.details(s.placeId);
    if (!mounted) return;
    setState(() => _loading = false);
    if (d != null) widget.onSelected(d);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Input
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1F35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focus.hasFocus
                  ? const Color(0xFFD4AF37).withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.search_rounded,
                  color: _focus.hasFocus
                      ? const Color(0xFFD4AF37)
                      : Colors.white38,
                  size: 20,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  onChanged: _onChanged,
                  autofocus: true,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                  ),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFD4AF37),
                    ),
                  ),
                )
              else if (_ctrl.text.isNotEmpty)
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white38,
                    size: 18,
                  ),
                  onPressed: () {
                    _ctrl.clear();
                    setState(() => _results = []);
                  },
                ),
            ],
          ),
        ),
        // Results
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1223),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _results.length,
              separatorBuilder: (_, __) => Divider(
                color: Colors.white.withValues(alpha: 0.05),
                height: 1,
              ),
              itemBuilder: (_, i) {
                final s = _results[i];
                return ListTile(
                  onTap: () => _onSelect(s),
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: Color(0xFF1A1F35),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: Color(0xFFD4AF37),
                      size: 18,
                    ),
                  ),
                  title: Text(
                    s.description,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  dense: true,
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }
}
