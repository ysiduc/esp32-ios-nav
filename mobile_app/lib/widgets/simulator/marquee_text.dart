import 'package:flutter/material.dart';

/// Widget chữ tự động thả trôi (Marquee) khi văn bản dài hơn khung chứa.
/// Tuyệt đối không tràn ra ngoài nhờ SizedBox + ClipRect.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double width;
  final TextAlign textAlign;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    required this.width,
    this.textAlign = TextAlign.left,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  AnimationController? _animController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _checkScroll();
  }

  void _checkScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _startAnimation();
      }
    });
  }

  void _startAnimation() {
    _animController?.dispose();
    if (!mounted || !_scrollController.hasClients) return;
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final durationSeconds = (maxExtent / 20.0).clamp(3.0, 15.0);
    _animController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (durationSeconds * 1000).toInt()),
    )..addListener(() {
        if (_scrollController.hasClients && _animController != null) {
          _scrollController.jumpTo(_animController!.value * maxExtent);
        }
      });
    _animController!.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _animController?.stop();
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
          if (_scrollController.position.maxScrollExtent > 0) {
            _startAnimation();
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _animController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: ClipRect(
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(
            widget.text,
            style: widget.style,
            textAlign: widget.textAlign,
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

