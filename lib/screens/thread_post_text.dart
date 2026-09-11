import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Keep selection controls interactive, but clear selection on outside touches
/// on mobile as well as mouse clicks on desktop.
class ThreadPostText extends StatefulWidget {
  const ThreadPostText(this.text, {super.key, this.onTap, this.onOpenUrl});

  final String text;
  final VoidCallback? onTap;
  final ValueChanged<Uri>? onOpenUrl;

  @override
  State<ThreadPostText> createState() => _ThreadPostTextState();
}

class _ThreadPostTextState extends State<ThreadPostText> {
  final _focus = FocusNode();
  final _links = <TapGestureRecognizer>[];

  void clearLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  TextSpan linkedText() {
    clearLinks();
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'''h?ttps?://[^\s<>"「」『』（）]+''');
    var end = 0;
    for (final match in pattern.allMatches(widget.text)) {
      final url = match.group(0)!.replaceFirst(RegExp(r'[.,、。]+$'), '');
      // Preserve the displayed text, but restore omitted h for navigation.
      final uri = Uri.tryParse(url.startsWith('ttp') ? 'h$url' : url);
      if (uri == null || uri.host.isEmpty) continue;
      spans.add(TextSpan(text: widget.text.substring(end, match.start)));
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          _focus.unfocus();
          widget.onOpenUrl!(uri);
        };
      _links.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF90CAF9)
                : Colors.blue,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
      end = match.start + url.length;
    }
    spans.add(TextSpan(text: widget.text.substring(end)));
    return TextSpan(children: spans);
  }

  @override
  void dispose() {
    clearLinks();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    onTapOutside: (_) => _focus.unfocus(),
    child: widget.onOpenUrl == null
        ? SelectableText(widget.text, focusNode: _focus, onTap: widget.onTap)
        : SelectableText.rich(
            linkedText(),
            focusNode: _focus,
            onTap: widget.onTap,
          ),
  );
}
