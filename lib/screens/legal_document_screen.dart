import 'package:flutter/material.dart';
import '../widgets/neu_style.dart';

const _legalGold = Color(0xFFE8C547);

/// One section of a legal document: a heading plus its full body text.
/// The body supports multi-paragraph text (\n\n separates paragraphs) and
/// simple **bold** markers (parsed locally — no markdown dependency).
class LegalSection {
  final String heading;
  final String body;
  const LegalSection({required this.heading, required this.body});
}

/// Shared neumorphic renderer for legal documents (Terms of Service,
/// Privacy Policy). English-only content, matching the legal docs.
class LegalDocumentScreen extends StatelessWidget {
  final String title;
  final String effectiveDate;
  final List<LegalSection> sections;

  const LegalDocumentScreen({
    super.key,
    required this.title,
    required this.effectiveDate,
    required this.sections,
  });

  static const _bodyStyle = TextStyle(
    fontFamily: 'Poppins',
    color: Color(0xBFFFFFFF), // white 0.75
    fontSize: 14,
    height: 1.55,
  );
  static final _boldStyle = _bodyStyle.copyWith(
    fontWeight: FontWeight.w700,
    color: const Color(0xE6FFFFFF), // white 0.9
  );

  /// Parses **bold** markers into TextSpans (odd segments are bold).
  static List<TextSpan> _parseBold(String text) {
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

  Widget _buildSection(LegalSection section) {
    final paragraphs = section.body
        .split('\n\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: neuBox(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.heading,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: _legalGold,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < paragraphs.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i < paragraphs.length - 1 ? 10 : 0),
              child: Text.rich(
                TextSpan(children: _parseBold(paragraphs[i])),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            // ── Header: back button + title + effective date ──
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
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
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
                          effectiveDate,
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
            // ── Sections ──
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                itemCount: sections.length,
                itemBuilder: (_, i) => _buildSection(sections[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
