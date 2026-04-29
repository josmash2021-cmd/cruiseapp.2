part of 'map_screen.dart';

// ════════════════════════════════════════════════════════════
//  WIDGETS — panels, UI builders, sheets
// ════════════════════════════════════════════════════════════

extension _MapScreenWidgets on _MapScreenState {

  void _showTripCancelledDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(
          Icons.cancel_outlined,
          color: Color(0xFFFF453A),
          size: 48,
        ),
        title: Text(
          S.of(context).tripCancelled,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).tripCancelledByOperator,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 15,
            height: 1.4,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                S.of(context).okButton,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rideTimeOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: _c.iconDefault, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: _c.iconDefault, fontSize: 13),
                  ),
                ],
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _c.textSecondary, width: 2),
                color: selected ? _c.textPrimary : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _c.mapSurface,
          foregroundColor: _c.textPrimary,
          side: BorderSide(color: _c.textSecondary, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  void _handlePanelDragEnd(BuildContext context, double velocity) {
    _lastPanelVelocity = velocity;
    final screenHeight = MediaQuery.of(context).size.height;
    final draggedHeight = _panelDragHeight ?? _panelHeightForStage(context);
    const flingThreshold = 700.0;

    if (_stage == RideStage.pin) {
      final openThreshold = screenHeight * 0.40;
      // Fast upward fling or dragged past threshold → open
      if (velocity < -flingThreshold || draggedHeight >= openThreshold) {
        _setStage(RideStage.plan);
        return;
      }
    }

    if (_stage == RideStage.plan) {
      final collapseThreshold = screenHeight * 0.33;
      // Fast downward fling or dragged below threshold → collapse
      if (velocity > flingThreshold || draggedHeight <= collapseThreshold) {
        Navigator.of(context).maybePop();
        return;
      }
    }

    if (_stage == RideStage.options) {
      final bottomInset = MediaQuery.of(context).padding.bottom;
      final expandedH = (442 + bottomInset).clamp(390.0, screenHeight * 0.62);
      final collapsedH = (270 + bottomInset).clamp(240.0, screenHeight * 0.45);
      final midpoint = (expandedH + collapsedH) / 2;
      // Fast fling overrides position threshold
      final bool expand;
      if (velocity.abs() > flingThreshold) {
        expand = velocity < 0; // swipe up = expand
      } else {
        expand = draggedHeight >= midpoint;
      }
      _setState(() {
        _optionsExpanded = expand;
        _isPanelDragging = false;
        _panelDragHeight = null;
      });
      return;
    }

    _setState(() {
      _isPanelDragging = false;
      _panelDragHeight = null;
    });
  }

  double _currentPanelHeight(BuildContext context) {
    if (_stage == RideStage.plan &&
        (_isAddressFieldFocused || _suggestions.isNotEmpty || _isSearching)) {
      return _panelMaxHeight(context);
    }
    final minH = _panelMinHeight(context);
    final maxH = math.max(minH, _panelMaxHeight(context));
    return (_panelDragHeight ?? _panelHeightForStage(context)).clamp(
      minH,
      maxH,
    );
  }

  double _panelMinHeight(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    if (_stage == RideStage.pin) {
      return 228 + bottomInset;
    }
    if (_stage == RideStage.plan) {
      if (_isAddressFieldFocused) {
        final maxH = _panelMaxHeight(context);
        final minH = math.min(420.0, maxH);
        return (MediaQuery.of(context).size.height * 0.82).clamp(minH, maxH);
      }
      return 310 + bottomInset;
    }
    if (_stage == RideStage.options) {
      return 240 + bottomInset;
    }
    if (_stage == RideStage.confirmPickup) {
      return 270 + bottomInset;
    }
    if (_stage == RideStage.payment) {
      return 360 + bottomInset;
    }
    if (_stage == RideStage.matching || _stage == RideStage.riding) {
      return 300 + bottomInset;
    }
    return 170 + bottomInset;
  }

  double _panelMaxHeight(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    return (screenHeight - topPadding - 14).clamp(260, screenHeight * 0.95);
  }

  double _panelHeightForStage(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    // Helper: safe clamp that guards against max < min on small screens.
    double safeClamp(double value, double minVal, double maxFraction) {
      final maxVal = math.max(minVal, screenHeight * maxFraction);
      return value.clamp(minVal, maxVal).toDouble();
    }

    switch (_stage) {
      case RideStage.pin:
        return 214 + bottomInset;
      case RideStage.plan:
        return safeClamp(320 + bottomInset, 290.0, 0.46);
      case RideStage.loading:
        return safeClamp(340 + bottomInset, 310.0, 0.46);
      case RideStage.options:
        if (_optionsExpanded) {
          return safeClamp(442 + bottomInset, 390.0, 0.62);
        } else {
          return safeClamp(270 + bottomInset, 240.0, 0.45);
        }
      case RideStage.confirmPickup:
        return safeClamp(340 + bottomInset, 300.0, 0.50);
      case RideStage.payment:
        final promoExtra = _promoActive ? 44.0 : 0.0;
        final payH =
            (_linkedPaymentMethods.contains(_selectedPaymentMethod)
                ? 440
                : 480) +
            promoExtra;
        return safeClamp(payH + bottomInset, 400.0, 0.72);
      case RideStage.matching:
        return safeClamp(500 + bottomInset, 450.0, 0.82);
      case RideStage.riding:
        return safeClamp(310 + bottomInset, 280.0, 0.50);
    }
  }

  Widget _buildPanel() {
    final panel = switch (_stage) {
      RideStage.pin => _pinPanel(),
      RideStage.plan => _planPanel(),
      RideStage.loading => _loadingPanel(),
      RideStage.options => _optionsPanel(),
      RideStage.confirmPickup => _confirmPickupPanel(),
      RideStage.payment => _paymentPanel(),
      RideStage.matching => _matchingPanel(),
      RideStage.riding => _ridingPanel(),
    };
    return RepaintBoundary(child: panel);
  }

  Widget _pinPanel() {
    return Container(
      height: double.infinity,
      key: const ValueKey('pin'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            const SizedBox(height: 12),
            Text(
              S.of(context).planYourDestination,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 30,
              ),
            ),
            Text(
              S.of(context).moveMapChooseDestination,
              style: TextStyle(color: _c.textTertiary, fontSize: 14),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _openWhereTo,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: _softBlack,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.45),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.crop_square, color: _gold, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        S.of(context).whereToQuestion,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          shadows: _thinWhiteOutline,
                        ),
                      ),
                    ),
                    Icon(Icons.search, color: _gold),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planPanel() {
    return ClipRRect(
      key: const ValueKey('plan'),
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A).withValues(alpha: 0.82),
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        border: Border.fromBorderSide(BorderSide(color: _c.border, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 28,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          offset: _planBodyVisible ? Offset.zero : const Offset(0, 0.04),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            opacity: _planBodyVisible ? 1 : 0,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                _handle(),
                const SizedBox(height: 8),
                Text(
                  S.of(context).planYourRide,
                  style: TextStyle(
                    color: _c.textPrimary,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Badge(
                      icon: _pickupNow
                          ? Icons.watch_later_outlined
                          : Icons.calendar_today_outlined,
                      text: _rideTimeBadgeText,
                      onTap: _showRideTimeSheet,
                    ),
                    const SizedBox(width: 8),
                    _Badge(
                      icon: Icons.person_outline,
                      text: S.of(context).forMe,
                    ),
                    const SizedBox(width: 8),
                    _Badge(
                      icon: _airportSelection != null
                          ? Icons.flight_rounded
                          : Icons.flight_outlined,
                      text: _airportSelection != null
                          ? _airportSelection!.airport.code
                          : S.of(context).airportLabel,
                      onTap: _showAirportSheet,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _addressBox(),
                const SizedBox(height: 6),
                Expanded(child: _suggestionsView()),
              ],
            ),
          ),
        ),
      ),
        ),
      ),
    );
  }

  Widget _addressBox() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold, width: 1.1),
      ),
      child: Column(
        children: [
          _addressInput(
            controller: _pickupCtrl,
            focusNode: _pickupFocus,
            icon: Icons.radio_button_checked,
            hint: S.of(context).pickupHint,
            textInputAction: TextInputAction.next,
            onChanged: (value) => _onAddressChanged(value, pickup: true),
            onSubmitted: (_) => _dropoffFocus.requestFocus(),
            onClear: () => _clearAddressInput(pickup: true),
          ),
          Divider(height: 1, color: _c.border),
          _addressInput(
            controller: _dropoffCtrl,
            focusNode: _dropoffFocus,
            icon: Icons.crop_square,
            hint: S.of(context).whereToQuestion,
            textInputAction: TextInputAction.done,
            onChanged: (value) => _onAddressChanged(value, pickup: false),
            onSubmitted: _onDropoffSubmitted,
            onClear: () => _clearAddressInput(pickup: false),
          ),
        ],
      ),
    );
  }

  Widget _suggestionsView() {
    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
      );
    }

    if (_searchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          S.of(context).addressResultsError,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }

    if (_suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      cacheExtent: 400,
      itemCount: _suggestions.length,
      separatorBuilder: (_, index) => Divider(height: 1, color: _c.divider),
      itemBuilder: (context, index) {
        final s = _suggestions[index];

        // Smart icon from Google Places type tags
        final icon = s.icon;

        // Build subtitle
        String? subtitle;
        if (!_searchingPickup &&
            _currentPosition != null &&
            s.distanceMiles != null) {
          final miles = '${s.distanceMiles!.toStringAsFixed(1)} mi';
          final eta = s.etaText ?? _etaFromMiles(s.distanceMiles);
          subtitle = '$eta · $miles';
        }

        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            icon,
            color: _gold,
            size: 18,
          ),
          title: Text(
            s.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _c.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle,
                  style: TextStyle(color: _c.textTertiary, fontSize: 12),
                )
              : null,
          onTap: () => _selectSuggestion(s, pickup: _searchingPickup),
        );
      },
    );
  }

  Widget _loadingPanel() {
    return Container(
      key: const ValueKey('loading'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            const SizedBox(height: 10),
            Text(
              S.of(context).gatheringOptions,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 32,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              minHeight: 3,
              color: _gold,
              backgroundColor: _c.border,
              borderRadius: BorderRadius.circular(99),
            ),
            const SizedBox(height: 14),
            ...List.generate(
              3,
              (index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(width: 48, height: 24, decoration: _skeleton),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 130,
                            height: 10,
                            decoration: _skeleton,
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: 94,
                            height: 10,
                            decoration: _skeletonLight,
                          ),
                        ],
                      ),
                    ),
                    Container(width: 60, height: 10, decoration: _skeleton),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionsPanel() {
    return Container(
      height: double.infinity,
      key: const ValueKey('options'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _handle(),
            BouncingButton(
              onPressed: () => _setState(() {
                _optionsExpanded = !_optionsExpanded;
                _panelDragHeight = null;
              }),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: AnimatedRotation(
                  turns: _optionsExpanded ? 0.0 : 0.5,
                  duration: const Duration(milliseconds: 250),
                  child: Icon(
                    Icons.keyboard_arrow_up,
                    color: _c.textTertiary,
                    size: 24,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_offer, color: _gold, size: 16),
                const SizedBox(width: 8),
                Text(
                  _promoActive
                      ? S.of(context).discountApplied(_promoDiscountPercent)
                      : S.of(context).selectYourRide,
                  style: TextStyle(
                    color: _promoActive ? _gold : _c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.route, color: _c.iconDefault, size: 15),
                const SizedBox(width: 6),
                Text(
                  '$_tripMiles · $_tripDuration',
                  style: TextStyle(color: _c.textSecondary, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              fit: FlexFit.loose,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubicEmphasized,
                alignment: Alignment.topCenter,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _optionsExpanded ? _rides.length : 1,
                  itemBuilder: (context, i) {
                    final ride = _rides[i];
                    final selected = i == _selectedRide;
                    final accent = _rideAccentColor(ride.name);
                    final badgeInfo = _rideBadgeInfo(ride.name);

                    return BouncingButton(
                      scaleFactor: 0.96,
                      onPressed: () => _setState(() => _selectedRide = i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.only(bottom: 12),
                        height: 140,
                        decoration: BoxDecoration(
                          color: selected ? const Color(0xFF1A1F2E) : const Color(0xFF111318),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: selected ? accent.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.07),
                            width: selected ? 1.5 : 1.0,
                          ),
                          boxShadow: selected
                              ? [BoxShadow(color: accent.withValues(alpha: 0.15), blurRadius: 16, spreadRadius: 1)]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Row(
                            children: [
                              // LEFT — Badge + Car
                              SizedBox(
                                width: 140,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Badge
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: badgeInfo.$3,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(badgeInfo.$2, color: badgeInfo.$4, size: 11),
                                            const SizedBox(width: 4),
                                            Text(
                                              badgeInfo.$1,
                                              style: TextStyle(color: badgeInfo.$4, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      // Car image
                                      Image.asset(
                                        _rideCarAsset(ride.name),
                                        height: 70,
                                        fit: BoxFit.contain,
                                        filterQuality: FilterQuality.high,
                                        cacheWidth: 240,
                                        errorBuilder: (_, __, ___) => Icon(
                                          Icons.directions_car_rounded,
                                          size: 48,
                                          color: _c.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // RIGHT — Info + Price
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(4, 14, 14, 14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      // Title + description
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _rideDescription(ride.name),
                                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            _rideFeatures(ride.name),
                                            style: TextStyle(color: accent.withValues(alpha: 0.75), fontSize: 11, fontWeight: FontWeight.w500),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                      // Price + checkmark row
                                      Row(
                                        children: [
                                          Text(
                                            ride.price,
                                            style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w800),
                                          ),
                                          const SizedBox(width: 6),
                                          const Text(
                                            'est. fare',
                                            style: TextStyle(color: Colors.white38, fontSize: 10),
                                          ),
                                          const Spacer(),
                                          if (selected)
                                            Container(
                                              width: 22,
                                              height: 22,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: accent,
                                              ),
                                              child: const Icon(Icons.check_rounded, color: Colors.black, size: 14),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _c.mapSurface,
                      foregroundColor: _c.textPrimary,
                      side: BorderSide(color: _c.textSecondary, width: 1.2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: _beginRideRequestFromOptions,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${S.of(context).chooseRide} ${_rides[_selectedRide].name}',
                        maxLines: 1,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          shadows: _thinWhiteOutline,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _showRideTimeSheet,
                  child: Container(
                    width: 52,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _softBlack,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.calendar_month, color: _c.textPrimary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressInput({
    required TextEditingController controller,
    required FocusNode focusNode,
    required IconData icon,
    required String hint,
    required ValueChanged<String> onChanged,
    TextInputAction textInputAction = TextInputAction.done,
    ValueChanged<String>? onSubmitted,
    required VoidCallback onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            icon,
            color: icon == Icons.crop_square ? _gold : _c.iconDefault,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: textInputAction,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: _c.textTertiary),
              ),
            ),
          ),
          InkWell(
            onTap: onClear,
            borderRadius: BorderRadius.circular(30),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.cancel_outlined,
                color: _c.textTertiary,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backButton() {
    return GestureDetector(
      onTap: () async {
        if (_stage == RideStage.riding || _stage == RideStage.matching) {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: _c.mapSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                _stage == RideStage.riding
                    ? S.of(context).cancelRide
                    : S.of(context).stopSearchingQuestion,
                style: TextStyle(
                  color: _c.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: Text(
                _stage == RideStage.riding
                    ? S.of(context).cancelRideConfirmation
                    : S.of(context).stopSearchingConfirmation,
                style: TextStyle(color: _c.textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    S.of(context).keepRide,
                    style: TextStyle(color: _gold, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    S.of(context).cancelButton,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          );
          if (confirm != true || !mounted) return;
          _rideLifecycleTimer?.cancel();
          _tripPollTimer?.cancel();
          _setState(() {
            // driver annotation cleared via manager
            _rideProgress = 0;
          });
          Navigator.of(context).maybePop();
          return;
        }
        if (_stage == RideStage.payment) {
          _setStage(RideStage.confirmPickup);
          return;
        }
        if (_stage == RideStage.confirmPickup) {
          _setStage(RideStage.options);
          return;
        }
        if (_stage == RideStage.options) {
          _setStage(RideStage.plan);
          return;
        }
        if (_stage == RideStage.plan || _stage == RideStage.loading) {
          Navigator.of(context).maybePop();
          return;
        }
        Navigator.of(context).maybePop();
      },
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.arrow_back, color: _c.textPrimary, size: 20),
      ),
    );
  }

  Widget _handle() => Container(
    width: 44,
    height: 5,
    decoration: BoxDecoration(
      color: _c.iconMuted,
      borderRadius: BorderRadius.circular(40),
    ),
  );

  Widget _confirmPickupPanel() {
    return Container(
      key: const ValueKey('confirmPickup'),
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: BoxDecoration(
        color: _c.mapPanel,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        border: Border.all(color: _c.border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: _c.shadow,
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: _c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              S.of(context).confirmPickupSpot,
              style: TextStyle(
                color: _c.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              S.of(context).moveMapAdjustPickup,
              style: TextStyle(
                color: _c.textTertiary,
                fontSize: 13.5,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 18),
            // Schedule banner
            if (!_pickupNow) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _gold.withValues(alpha: 0.30)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_rounded,
                      color: _gold,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        S.of(context).scheduledFor(_rideTimeBadgeText),
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            // --- Pickup address card ---
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _c.border,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.30),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.my_location_rounded,
                      color: _gold,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.of(context).pickupLabel.toUpperCase(),
                          style: TextStyle(
                            color: _gold.withValues(alpha: 0.8),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _pickupAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // --- Driver note ---
            InkWell(
              onTap: _showDriverNoteSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 14,
                ),
                decoration: BoxDecoration(
                  color: _c.border,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_note_rounded,
                      color: _gold.withValues(alpha: 0.8),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _driverNote.isEmpty
                            ? S.of(context).addNoteForDriver
                            : _driverNote,
                        style: TextStyle(
                          color: _driverNote.isEmpty
                              ? _gold.withValues(alpha: 0.75)
                              : _c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontStyle: _driverNote.isEmpty
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _c.iconMuted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // --- Confirm button ---
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _confirmPickupAndRequestRide,
                child: Text(
                  S.of(context).selectPayment,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardBrandLogoWidget(String? brand, double size) {
    // Map brand to display name shown as clean text on white background (single logo only)
    final Map<String, ({String text, Color color, bool italic})> brands = {
      'visa': (text: 'VISA', color: const Color(0xFF1A1F71), italic: true),
      'mastercard': (text: 'MC', color: const Color(0xFFEB001B), italic: false),
      'amex': (text: 'AMEX', color: const Color(0xFF006FCF), italic: false),
      'discover': (text: 'DISC', color: const Color(0xFFFF6000), italic: false),
      'diners': (text: 'DC', color: const Color(0xFF0079BE), italic: false),
      'jcb': (text: 'JCB', color: const Color(0xFF0B7CBE), italic: false),
    };
    final info = brands[brand];
    if (info == null) {
      return _brandLogo(
        null,
        const Color(0xFF6B7280),
        icon: Icons.credit_card_rounded,
      );
    }
    // Single clean logo: white pill with brand text in brand color
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              info.text,
              style: TextStyle(
                color: info.color,
                fontSize: size * 0.40,
                fontWeight: FontWeight.w900,
                fontStyle: info.italic ? FontStyle.italic : FontStyle.normal,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandLogo(
    String? letter,
    Color color, {
    Color? bg,
    bool bordered = false,
    bool italic = false,
    IconData? icon,
  }) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: bordered
            ? Border.all(color: Colors.grey.shade300, width: 0.5)
            : null,
      ),
      child: Center(
        child: icon != null
            ? Icon(icon, color: color, size: 20)
            : Text(
                letter!,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                  fontFamily: 'Roboto',
                ),
              ),
      ),
    );
  }

  /// Apple Pay logo widget for iOS.
  Widget _applePayLogoWidget(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade700, width: 0.5),
      ),
      child: Center(
        child: Icon(Icons.apple, color: Colors.white, size: size * 0.55),
      ),
    );
  }

  /// Wide Apple Pay / Google Pay logo for payment rows (no extra text).
  Widget _nativePayLogoWide(String id) {
    if (id == 'apple_pay') {
      return Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apple, color: Colors.white, size: 28),
              SizedBox(width: 6),
              Text('Apple Pay', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: -0.3)),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Center(
        child: RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFEA4335))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFFBBC05))),
              TextSpan(text: 'g', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'le ', style: TextStyle(color: Color(0xFF34A853))),
              TextSpan(text: 'Pay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  /// Google Pay logo using the real multicolor "G" image asset.
  Widget _googlePayLogoWidget(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Image.asset('assets/images/google_g.png', fit: BoxFit.contain, cacheWidth: 80),
      ),
    );
  }

  /// PayPal logo using the real double-P image asset.
  Widget _paypalLogoWidget(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Image.asset(
          'assets/images/paypal_logo.png',
          fit: BoxFit.contain,
          cacheWidth: 80,
        ),
      ),
    );
  }

  /// Opens the payment-method bottom sheet and lets the user pick one.
  void _showPaymentMethodSelector() {
    final creditLabel = (_savedCardBrand != null && _savedCardLast4 != null)
        ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
        : S.of(context).creditOrDebitCard;
    final isIOS = Platform.isIOS;
    final methods = [
      if (isIOS) ('apple_pay', 'Apple Pay'),
      if (!isIOS) ('google_pay', 'Google Pay'),
      ('credit_card', creditLabel),
      ('paypal', 'PayPal'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          decoration: BoxDecoration(
            color: _c.mapPanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: _c.iconMuted,
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    S.of(context).paymentMethodTitle,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ...methods.map((m) {
                  final (id, label) = m;
                  final info = _paymentMethodInfo(id);
                  final selected = id == _selectedPaymentMethod;
                  final linked = _linkedPaymentMethods.contains(id);
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _onPaymentMethodSelected(id);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? _gold.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: selected
                            ? Border.all(
                                color: _gold.withValues(alpha: 0.4),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          if (id == 'apple_pay' || id == 'google_pay')
                            Expanded(child: _nativePayLogoWide(id))
                          else ...[    
                            info.logoWidget,
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: TextStyle(
                                      color: _c.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (!linked)
                                    Text(
                                      S.of(context).notAdded,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          if (linked && selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: _gold,
                              size: 22,
                            )
                          else if (linked)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                S.of(context).addedLabel,
                                style: TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _gold,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                S.of(context).addButton,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                // Manage payment accounts link
                GestureDetector(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
                    _loadLinkedPayments(); // refresh linked state on return
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings_rounded, color: _gold, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        S.of(context).managePaymentAccounts,
                        style: TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _paymentPanel() {
    final ride = _rides[_selectedRide];
    return Container(
      key: const ValueKey('payment'),
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: _c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              S.of(context).paymentLabel,
              style: TextStyle(
                color: _c.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 16),
            // Schedule banner for payment panel
            if (!_pickupNow) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _gold.withValues(alpha: 0.30)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_rounded,
                      color: _gold,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _rideTimeBadgeText,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            // --- Scrollable content area ---
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Ride summary card ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _c.border,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _c.border, width: 1),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 56,
                            height: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.asset(
                              'assets/images/${ride.vehicle.toLowerCase()}.png',
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              cacheWidth: 112,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${ride.name} • ${ride.vehicle}',
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '$_tripMiles • $_tripDuration',
                                  style: TextStyle(
                                    color: _c.textTertiary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            ride.price,
                            style: TextStyle(
                              color: _c.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_promoActive) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.local_offer_rounded,
                              color: _gold,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                S
                                    .of(context)
                                    .promoDiscountApplied(
                                      _promoDiscountPercent,
                                    ),
                                style: TextStyle(
                                  color: _gold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // --- Route summary ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _c.border,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _gold,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _pickupAddress,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: 2,
                                height: 20,
                                color: _c.textTertiary,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _c.iconDefault,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _dropoffAddress,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // --- Payment method selector ---
                    GestureDetector(
                      onTap: _showPaymentMethodSelector,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _c.border,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.25),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            if (!_linkedPaymentMethods.contains(_selectedPaymentMethod)) ...[
                              // No linked method — show plain text, no icon
                              Expanded(
                                child: Text(
                                  S.of(context).selectPaymentMethod,
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ] else if (_selectedPaymentMethod == 'apple_pay' || _selectedPaymentMethod == 'google_pay')
                              Expanded(child: _nativePayLogoWide(_selectedPaymentMethod))
                            else ...[
                              _paymentMethodInfo(
                                _selectedPaymentMethod,
                              ).logoWidget,
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _paymentMethodInfo(
                                        _selectedPaymentMethod,
                                      ).label,
                                      style: TextStyle(
                                        color: _c.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      S.of(context).tapToChange,
                                      style: TextStyle(
                                        color: _c.textTertiary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: _c.textTertiary,
                              size: 22,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // --- Pay button ---
            if (!_linkedPaymentMethods.contains(_selectedPaymentMethod))
              // Unlinked — connect button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () async {
                    await Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
                    _loadLinkedPayments();
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.link_rounded, size: 18),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          S.of(context).addPaymentMethod,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _processPaymentAndRequestRide,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _pickupNow
                            ? Icons.lock_rounded
                            : Icons.calendar_month_rounded,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _pickupNow
                              ? S.of(context).payAmount(ride.price)
                              : S
                                    .of(context)
                                    .bookScheduledRidePrice(ride.price),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            // ── TEST MODE: Skip payment ──
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _c.textTertiary,
                  side: BorderSide(
                    color: _c.textTertiary.withValues(alpha: 0.35),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _processPaymentAndRequestRide,
                icon: const Icon(Icons.science_rounded, size: 16),
                label: const Text(
                  'Skip Payment (Test)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _matchingPanel() {
    final ride = _rides[_selectedRide];

    return Container(
      key: const ValueKey('matching'),
      height: double.infinity,
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Drag handle ──
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 0),
              child: Center(child: _handle()),
            ),
            const SizedBox(height: 22),

            // ── Radar hero — full centered visual ──
            Center(
              child: SizedBox(
                width: 164,
                height: 164,
                child: _MatchingRadar(color: _gold, isSearching: true),
              ),
            ),
            const SizedBox(height: 26),

            // ── Status text ──
            _AnimatedSearchText(
              text: S.of(context).lookingForDriver,
              style: TextStyle(
                color: _c.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              S.of(context).findingBestNearby(ride.name),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _c.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),

            // ── Indeterminate gold progress bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 52),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: const SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    color: _gold,
                    backgroundColor: Color(0xFF2A2A2A),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Trip summary card: badge + price | pickup → dropoff ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _c.border),
                ),
                child: Row(
                  children: [
                    // Ride badge + price column
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            ride.name,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          ride.price,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    // Divider
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Container(
                        width: 1,
                        height: 38,
                        color: _c.border,
                      ),
                    ),
                    // Pickup / dropoff addresses
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF4CAF50),
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _pickupAddress.isNotEmpty
                                      ? _pickupAddress
                                      : S.of(context).pickupLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _gold,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _dropoffAddress.isNotEmpty
                                      ? _dropoffAddress
                                      : S.of(context).dropoffLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Spacer(),

            // ── Cancel button ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: _isCancelling ? null : _cancelMatchingRide,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _c.border, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isCancelling
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white54,
                            strokeWidth: 2,
                          ))
                      : Text(
                          S.of(context).cancelRide,
                          style: TextStyle(
                            color: _c.textSecondary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Skeleton loading card shown while searching for driver
  Widget _matchingSkeletonCard() {
    return Container(
      key: const ValueKey('skeleton'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _c.border),
      ),
      child: Row(
        children: [
          // Skeleton avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.06),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 120, height: 14, decoration: _skeleton),
                const SizedBox(height: 8),
                Container(width: 80, height: 11, decoration: _skeletonLight),
              ],
            ),
          ),
          Container(width: 60, height: 14, decoration: _skeleton),
        ],
      ),
    );
  }

  /// Maps ride name to Cruise-branded car image asset.
  String _rideCarAsset(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip') || n.contains('suv') || n.contains('suburban')) return 'assets/images/cruise_3.png';
    if (n.contains('comfort') || n.contains('fusion') || n.contains('economy')) return 'assets/images/cruise_6.png';
    return 'assets/images/cruise_7.png';
  }

  double _carWidth(double aspectRatio) {
    return (_carHeight * aspectRatio).clamp(32.0, 56.0);
  }

  /// Gold ride progress bar with car image at the tip of the fill.
  Widget _buildRideProgressBar(double progress, String rideName) {
    final carAsset = _rideCarAsset(rideName);
    final carW = _carWidth(_carImageAspectRatio);
    const barH = 8.0;
    const carH = _carHeight;
    const totalH = carH + 4.0; // car + small gap above bar

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LayoutBuilder(
        builder: (_, constraints) {
          final barWidth = constraints.maxWidth;
          final filledWidth = barWidth * progress.clamp(0.0, 1.0);
          // Center of car aligns with tip of gold fill
          final carX = (filledWidth - carW / 2).clamp(0.0, barWidth - carW);

          return SizedBox(
            height: totalH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Bar track at bottom
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: barH,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(barH / 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(barH / 2),
                      child: FractionallySizedBox(
                        widthFactor: progress.clamp(0.0, 1.0),
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0xFFFFC200),
                                Color(0xFFFFD700),
                                Color(0xFFFFE566),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Car image at tip — bottom of car sits on top of bar
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOut,
                  left: carX,
                  bottom: barH,
                  child: Image.asset(
                    carAsset,
                    width: carW,
                    height: carH,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    isAntiAlias: true,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Accent color per ride type.
  Color _rideAccentColor(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return const Color(0xFFD4AF37);
    if (n.contains('comfort')) return const Color(0xFF2ECC71);
    return Colors.white;
  }

  /// Card description per ride type.
  String _rideDescription(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return 'Luxury SUV with premium amenities';
    if (n.contains('comfort')) return 'Reliable ride at great value';
    return 'Elegant sedan for any occasion';
  }

  /// Card features per ride type.
  String _rideFeatures(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return 'Spacious • Leather • Snacks & Drinks';
    if (n.contains('comfort')) return 'Clean • Safe • Efficient';
    return 'Comfort • Climate • Charger';
  }

  /// Driver info card shown when driver is found
  Widget _matchingDriverCard() {
    // Pick the right top-view car image based on ride type
    final carAsset = _rideCarAsset(_rides[_selectedRide].name);

    return Container(
      key: const ValueKey('driver'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.25), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.08),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Top: checkmark + title ──
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gold.withValues(alpha: 0.15),
                  border: Border.all(color: _gold.withValues(alpha: 0.4)),
                ),
                child: Icon(Icons.check_rounded, color: _gold, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).driverFound,
                      style: TextStyle(
                        color: _gold,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      S.of(context).driverOnTheWay(nh.displayName(_driverName, _driverCar)),
                      style: TextStyle(
                        color: _c.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // ── Car image with shadow ──
          Container(
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Shadow ellipse
                Positioned(
                  bottom: 8,
                  child: Container(
                    width: 100,
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(50),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          blurRadius: 18,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
                // Car image
                Image.asset(
                  carAsset,
                  height: 70,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  cacheWidth: 200,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.directions_car_rounded,
                    size: 48,
                    color: _c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── Car info + plate ──
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.directions_car_rounded, size: 15, color: _c.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _driverCar.isNotEmpty ? _driverCar : _rides[_selectedRide].name,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Rating
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, color: _gold, size: 15),
                    const SizedBox(width: 4),
                    Text(
                      _driverRating.toStringAsFixed(1),
                      style: TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              if (_driverPlate.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _driverPlate,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  RIDER NAVIGATION HEADER — Full driver info card (Uber-style)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildRiderNavHeader() {
    final isInTrip = _tripStatus == 'in_trip';
    final isArrived = _tripStatus == 'arrived';
    final isDriverEnRoute = !isInTrip && !isArrived;

    // Status dot color
    final statusColor = isInTrip
        ? const Color(0xFF4CAF50)
        : isArrived
            ? const Color(0xFF4FC3F7)
            : _gold;

    // Status text
    final statusText = isInTrip
        ? S.of(context).onTripToDestination
        : isArrived
            ? S.of(context).meetDriverAtPickup
            : S.of(context).driverEnRouteHeader;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Status row with dot ──
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ── Driver info row ──
          Row(
            children: [
              VerifiedAvatar(
                photoUrl: _driverPhotoUrl.isNotEmpty ? _driverPhotoUrl : null,
                radius: Responsive.w(22),
                fallbackName: _driverName,
                uid: _currentDriverId?.toString(),
                role: 'driver',
                isVerified: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _driverName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: _gold, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          _driverRating.toStringAsFixed(1),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Message button
              _headerActionButton(
                icon: Icons.chat_bubble_outline,
                onTap: () {
                  // TODO: Open chat with driver
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── Action buttons row ──
          Row(
            children: [
              // Message input (decorative)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: _gold.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.white.withValues(alpha: 0.4),
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        S.of(context).typeAMessage,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Phone button
              _headerActionButton(
                icon: Icons.phone_rounded,
                onTap: () async {
                  if (_driverPhone.isNotEmpty) {
                    final uri = Uri(scheme: 'tel', path: _driverPhone);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri);
                    }
                  }
                },
              ),
              const SizedBox(width: 8),
              // Share button
              _headerActionButton(
                icon: Icons.share_outlined,
                onTap: () {
                  // TODO: Share trip status
                },
              ),
              const SizedBox(width: 8),
              // More options
              _headerActionButton(
                icon: Icons.more_horiz,
                onTap: () {
                  // TODO: Show more options
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _headerActionButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          color: Colors.white.withValues(alpha: 0.8),
          size: 18,
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOTTOM STATUS BAR — ETA and trip status
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildBottomStatusBar() {
    final isInTrip = _tripStatus == 'in_trip';
    final isArrived = _tripStatus == 'arrived';

    final statusColor = isInTrip
        ? const Color(0xFF4CAF50)
        : isArrived
            ? const Color(0xFFFF5252)
            : _gold;

    final statusText = isInTrip
        ? S.of(context).onTheWayToDestination
        : isArrived
            ? S.of(context).driverIsWaitingForYou
            : S.of(context).driverOnTheWay(_driverName);

    final etaText = isArrived
        ? ''
        : (_driverEta.isNotEmpty && _driverEta != 'Arrived'
            ? _driverEta.replaceAll(RegExp(r'[^0-9]'), '')
            : '');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (etaText.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    etaText,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'min',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.5),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ridingPanel() {
    final isInTrip = _tripStatus == 'in_trip';
    final isArrived = _tripStatus == 'arrived';
    final price = (_rides.isNotEmpty && _selectedRide < _rides.length)
        ? _rides[_selectedRide].price
        : '';
    final rideName = (_rides.isNotEmpty && _selectedRide < _rides.length)
        ? _rides[_selectedRide].name
        : 'CRUISE';

    return Container(
      key: const ValueKey('riding'),
      height: double.infinity,
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _handle(),
            const SizedBox(height: 8),

            // Ride progress bar with car at tip
            if (isInTrip)
              _buildRideProgressBar(_rideProgress, rideName),
            const SizedBox(height: 10),

            // Route visual row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Color(0xFF00C853),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 22,
                          color: const Color(0xFF9E9E9E),
                        ),
                        const Icon(
                          Icons.location_on,
                          color: Color(0xFF1565C0),
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _pickupAddress.isNotEmpty
                              ? _pickupAddress
                              : S.of(context).yourLocation,
                          style: TextStyle(
                            color: _c.textSecondary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _dropoffAddress.isNotEmpty
                              ? _dropoffAddress
                              : S.of(context).destinationLabel,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final result = await Navigator.of(context)
                          .push<Map<String, dynamic>>(
                            sharedAxisZRoute(PickupDropoffSearchScreen(
                              initialPickupText: _pickupAddress,
                            )),
                          );
                      if (result != null &&
                          result['dropoffLabel'] != null &&
                          mounted) {
                        _setState(() {
                          _dropoffAddress = result['dropoffLabel'] as String;
                        });
                      }
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(60, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      S.of(context).addOrChange,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _c.isDark ? _gold : const Color(0xFF1565C0),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            Divider(height: 1, color: _c.border),
            const SizedBox(height: 10),

            // Driver row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  VerifiedAvatar(
                    photoUrl: _driverPhotoUrl.isNotEmpty ? _driverPhotoUrl : null,
                    radius: Responsive.w(22),
                    fallbackName: _driverName,
                    uid: _currentDriverId?.toString(),
                    role: 'driver',
                    isVerified: true,
                  ),
                  SizedBox(width: Responsive.w(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              nh.displayName(_driverName, _driverCar),
                              style: TextStyle(
                                color: _c.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: Responsive.sp(15),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.star_rounded,
                              color: _gold,
                              size: 13,
                            ),
                            Text(
                              ' 4.9',
                              style: TextStyle(
                                color: _c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        if (_driverCar.isNotEmpty || _driverPlate.isNotEmpty)
                          Text(
                            [
                              if (_driverCar.isNotEmpty) _driverCar,
                              if (_driverPlate.isNotEmpty) _driverPlate,
                            ].join(' \u2022 '),
                            style: TextStyle(
                              color: _c.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () async {
                      if (_driverPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _driverPhone);
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        }
                      }
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _c.isDark
                            ? const Color(0xFF2A2A2A)
                            : const Color(0xFF1C1E24),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.phone_rounded,
                        size: 18,
                        color: _c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),
            Divider(height: 1, color: _c.border),

            // Rate row (in_trip only)
            if (isInTrip) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text(
                      S.of(context).howsYourRide,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(
                          sharedAxisVerticalRoute(
                            RideRatingScreen(
                              driverName: _driverName,
                              rideName: rideName,
                              price: price.isNotEmpty ? price : r'$0.00',
                            ),
                          ),
                        );
                      },
                      child: Row(
                        children: [
                          Text(
                            S.of(context).rateOrTip,
                            style: TextStyle(
                              color: _c.isDark
                                  ? _gold
                                  : const Color(0xFF1565C0),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: _c.isDark ? _gold : const Color(0xFF1565C0),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: _c.border),
            ],

            const Spacer(),

            // Bottom: price/ETA + cancel
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isInTrip && price.isNotEmpty) ...[
                    Text(
                      price,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_tripMiles.isNotEmpty || _tripDuration.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _c.border,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          [
                            if (_tripMiles.isNotEmpty) _tripMiles,
                            if (_tripDuration.isNotEmpty) _tripDuration,
                          ].join(' \u2022 '),
                          style: TextStyle(
                            color: _c.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ] else ...[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isArrived
                                ? S.of(context).driverAtPickup(nh.displayName(_driverName, _driverCar))
                                : S.of(context).etaLabel(_driverEta),
                            style: TextStyle(
                              color: _c.textPrimary,
                              fontSize: Responsive.sp(16),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!isArrived)
                            Text(
                              S.of(context).driverOnTheWay(nh.displayName(_driverName, _driverCar)),
                              style: TextStyle(
                                color: _c.textSecondary,
                                fontSize: Responsive.sp(12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(S.of(context).cancelRide),
                          content: Text(S.of(context).cancelRideConfirmation),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(
                                S.of(context).keepRide,
                                style: TextStyle(color: _gold),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(
                                S.of(context).cancelButton,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirm != true || !mounted) return;
                      _rideLifecycleTimer?.cancel();
                      _tripPollTimer?.cancel();
                      _setState(() {
                        // driver annotation cleared via manager
                        _rideProgress = 0;
                      });
                      Navigator.of(context).maybePop();
                    },
                    child: Text(
                      S.of(context).cancelButton,
                      style: TextStyle(color: _c.textSecondary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small white floating chip displayed next to a route endpoint pin.
/// Appears at the coordinate-mapped screen position (updated on map idle).
class _PinInfoChip extends StatelessWidget {
  final String text;
  const _PinInfoChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF1A1A1F),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
