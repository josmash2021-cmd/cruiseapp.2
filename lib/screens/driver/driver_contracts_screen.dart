import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../widgets/neu_style.dart';

const _contractsGold = Color(0xFFE8C547);

/// Digital contracts hub (2026-10-21, user spec — Uber-style e-acceptance).
///
/// Lists the five required driver contracts from `GET /legal/contracts`
/// (server-versioned, dispatch-editable). Each tile opens a reader with the
/// full markdown; signing requires an explicit checkbox + the "Accept and
/// sign electronically" button, which records the verifiable evidence
/// server-side (version, content hash, IP, user agent, device info, exact
/// timestamp). Signed documents offer the PDF receipt download instead.
///
/// With [gate] = true the page is modal: back is blocked until every
/// required contract is current, then it pops itself (the can_go_online
/// gate and the boot check use this).
class DriverContractsScreen extends StatefulWidget {
  const DriverContractsScreen({super.key, this.gate = false});

  final bool gate;

  @override
  State<DriverContractsScreen> createState() => _DriverContractsScreenState();
}

class _DriverContractsScreenState extends State<DriverContractsScreen> {
  List<Map<String, dynamic>>? _contracts;
  bool _loadError = false;

  bool get _allCurrent =>
      _contracts != null &&
      _contracts!.every((c) => c['needs_acceptance'] != true);

  int get _signedCount =>
      _contracts?.where((c) => c['needs_acceptance'] != true).length ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ApiService.getContracts();
      if (!mounted) return;
      final list = (data['contracts'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const <Map<String, dynamic>>[];
      setState(() {
        _contracts = list;
        _loadError = false;
      });
      // Gate mode: the moment the whole set is current the page has done
      // its job — hand control back to the caller.
      if (widget.gate && _allCurrent) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) setState(() => _loadError = true);
    }
  }

  String _titleOf(Map<String, dynamic> c) {
    final es = S.of(context).isSpanish;
    return (es ? c['title_es'] : c['title_en'])?.toString() ??
        c['title_en']?.toString() ??
        c['slug']?.toString() ??
        '';
  }

  Future<void> _open(Map<String, dynamic> c) async {
    final slug = c['slug']?.toString() ?? '';
    if (slug.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ContractReaderPage(
        slug: slug,
        needsAcceptance: c['needs_acceptance'] == true,
        acceptedAt: c['accepted_at']?.toString(),
      ),
    ));
    _load();
  }

  Widget _chip(String text, {required bool signed}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: signed
            ? const Color(0xFF22C55E).withValues(alpha: 0.14)
            : _contractsGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: signed
              ? const Color(0xFF22C55E).withValues(alpha: 0.55)
              : _contractsGold.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            signed ? Icons.check_circle_rounded : Icons.edit_note_rounded,
            size: 13,
            color: signed ? const Color(0xFF22C55E) : _contractsGold,
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: signed ? const Color(0xFF22C55E) : _contractsGold,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final canPop = !widget.gate || _allCurrent;
    return PopScope(
      canPop: canPop,
      child: Scaffold(
        backgroundColor: neuBase,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    if (canPop)
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: neuBox(radius: 14, pressed: true),
                          child: const Icon(Icons.arrow_back_rounded,
                              color: Colors.white, size: 20),
                        ),
                      )
                    else
                      const SizedBox(width: 40, height: 40),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.contractsTitle,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _contracts == null
                                ? ''
                                : '$_signedCount/${_contracts!.length} · '
                                    '${s.contractsSubtitle}',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _contracts == null
                    ? Center(
                        child: _loadError
                            ? GestureDetector(
                                onTap: () {
                                  setState(() => _loadError = false);
                                  _load();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 28, vertical: 14),
                                  decoration: neuBox(radius: 16),
                                  child: Text(s.retry,
                                      style: const TextStyle(
                                          fontFamily: 'Poppins',
                                          color: Colors.white)),
                                ),
                              )
                            : const CircularProgressIndicator(
                                color: _contractsGold, strokeWidth: 2.5),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                        itemCount: _contracts!.length,
                        itemBuilder: (_, i) {
                          final c = _contracts![i];
                          final signed = c['needs_acceptance'] != true;
                          return GestureDetector(
                            onTap: () => _open(c),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: neuBox(radius: 18),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration:
                                        neuBox(radius: 14, pressed: true),
                                    child: const Icon(
                                      Icons.description_rounded,
                                      color: _contractsGold,
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _titleOf(c),
                                          style: const TextStyle(
                                            fontFamily: 'Poppins',
                                            color: Colors.white,
                                            fontSize: 14.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${s.contractVersion} '
                                          '${c['version'] ?? ''}',
                                          style: TextStyle(
                                            fontFamily: 'Poppins',
                                            color: Colors.white
                                                .withValues(alpha: 0.4),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  _chip(
                                    signed
                                        ? s.contractSignedChip
                                        : s.contractPendingChip,
                                    signed: signed,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One contract, full text. Bottom bar: the checkbox + gold sign button
/// when acceptance is due, or the signed stamp + PDF receipt download.
class _ContractReaderPage extends StatefulWidget {
  const _ContractReaderPage({
    required this.slug,
    required this.needsAcceptance,
    this.acceptedAt,
  });

  final String slug;
  final bool needsAcceptance;
  final String? acceptedAt;

  @override
  State<_ContractReaderPage> createState() => _ContractReaderPageState();
}

class _ContractReaderPageState extends State<_ContractReaderPage> {
  Map<String, dynamic>? _doc;
  bool _checked = false;
  bool _busy = false;
  bool _downloading = false;

  static const _bodyStyle = TextStyle(
    fontFamily: 'Poppins',
    color: Color(0xBFFFFFFF),
    fontSize: 13.5,
    height: 1.55,
  );
  static final _boldStyle = _bodyStyle.copyWith(
    fontWeight: FontWeight.w700,
    color: const Color(0xE6FFFFFF),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final lang = S.of(context).isSpanish ? 'es' : 'en';
      final doc = await ApiService.getContract(widget.slug, lang: lang);
      if (mounted) setState(() => _doc = doc);
    } catch (_) {
      if (mounted) setState(() => _doc = const {});
    }
  }

  String _deviceInfo() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _sign() async {
    final doc = _doc;
    if (doc == null || _busy) return;
    setState(() => _busy = true);
    final s = S.of(context);
    try {
      final res = await ApiService.acceptContract(
        slug: widget.slug,
        version: doc['version']?.toString() ?? '',
        contentHash: doc['content_hash']?.toString() ?? '',
        deviceInfo: _deviceInfo(),
      );
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.of(context).pop();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['error'] == 'stale_version'
            ? s.contractStaleVersion
            : s.contractAcceptError),
      ));
      if (res['error'] == 'stale_version') _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message.contains('stale_version')
            ? s.contractStaleVersion
            : s.contractAcceptError),
      ));
      if (e.message.contains('stale_version')) _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.contractAcceptError)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadReceipt() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final bytes = await ApiService.downloadContractReceipt(widget.slug);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/receipt_${widget.slug}.pdf');
      await f.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(f.path)]);
    } catch (_) {
      // Share sheet dismissed or a transient failure — nothing to repair.
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Minimal markdown: `#`/`##` headings in gold, paragraphs with **bold**.
  List<Widget> _renderMarkdown(String markdown) {
    final widgets = <Widget>[];
    final buffer = <String>[];
    void flushParagraph() {
      final text = buffer.join('\n').trim();
      buffer.clear();
      if (text.isEmpty) return;
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text.rich(TextSpan(children: _parseBold(text))),
      ));
    }

    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('#')) {
        flushParagraph();
        final level = line.startsWith('##') ? 2 : 1;
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Text(
            line.replaceFirst(RegExp(r'^#+\s*'), ''),
            style: TextStyle(
              fontFamily: 'Poppins',
              color: _contractsGold,
              fontSize: level == 1 ? 17 : 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ));
      } else if (line.trim().isEmpty) {
        flushParagraph();
      } else {
        buffer.add(line);
      }
    }
    flushParagraph();
    return widgets;
  }

  List<TextSpan> _parseBold(String text) {
    final spans = <TextSpan>[];
    final parts = text.split('**');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(TextSpan(
        text: parts[i],
        style: i.isOdd ? _boldStyle : _bodyStyle,
      ));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text, style: _bodyStyle));
    return spans;
  }

  String _signedStamp(S s) {
    final at = DateTime.tryParse(widget.acceptedAt ?? '')?.toLocal();
    final date = at == null ? '' : ' ${at.month}/${at.day}/${at.year}';
    return '${s.contractSignedOn}$date';
  }

  Widget _bottomBar(S s) {
    // Sign mode has NO pinned bar (user spec 2026-10-21: "en lo último es
    // que marcarán la casilla y el botón") — the sign block is the LAST
    // item of the document scroll, so signing requires reading to the end.
    if (widget.needsAcceptance) return const SizedBox.shrink();
    return Container(
        padding: EdgeInsets.fromLTRB(
            24, 12, 24, MediaQuery.of(context).padding.bottom + 12),
        decoration: neuBox(radius: 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.verified_rounded,
                    color: Color(0xFF22C55E), size: 18),
                const SizedBox(width: 8),
                Text(
                  _signedStamp(s),
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFF22C55E),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _downloading ? null : _downloadReceipt,
              child: Container(
                width: double.infinity,
                height: 50,
                decoration: neuBox(radius: 16, pressed: true),
                alignment: Alignment.center,
                child: _downloading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: _contractsGold, strokeWidth: 2))
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.download_rounded,
                              color: _contractsGold, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            s.contractDownloadPdf,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: _contractsGold,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      );
  }

  /// Checkbox + gold sign button + E-SIGN note as the LAST scroll item
  /// (user spec 2026-10-21: "requiere que hagan todo el scroll down para
  /// que realmente se verifique que leyeron todo el contrato") — the block
  /// only exists at the end of the document, so it cannot be signed
  /// without scrolling through the full text first.
  Widget _signBlock(S s) {
    final canSign = _checked && !_busy;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _checked = !_checked),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _checked ? _contractsGold : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _checked
                          ? _contractsGold
                          : Colors.white.withValues(alpha: 0.35),
                      width: 2,
                    ),
                  ),
                  child: _checked
                      ? const Icon(Icons.check, size: 16, color: Colors.black)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.contractReadAndAccept,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: canSign ? _sign : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: double.infinity,
              height: 54,
              decoration: canSign
                  ? BoxDecoration(
                      color: _contractsGold,
                      borderRadius: BorderRadius.circular(16),
                    )
                  : neuBox(radius: 16, pressed: true),
              alignment: Alignment.center,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.black, strokeWidth: 2.4))
                  : Text(
                      s.contractAcceptSign,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: canSign
                            ? Colors.black
                            : Colors.white.withValues(alpha: 0.35),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.contractEsignNote,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final doc = _doc;
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          doc?['title']?.toString() ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${s.contractVersion} ${doc?['version'] ?? ''}',
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: doc == null
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: _contractsGold, strokeWidth: 2.5))
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      // The sign block is the LAST item — full scroll first.
                      children: [
                        ..._renderMarkdown(
                            doc['content_markdown']?.toString() ?? ''),
                        if (widget.needsAcceptance &&
                            (doc['content_markdown']?.toString() ?? '')
                                .isNotEmpty)
                          _signBlock(s),
                      ],
                    ),
            ),
            _bottomBar(s),
          ],
        ),
      ),
    );
  }
}
