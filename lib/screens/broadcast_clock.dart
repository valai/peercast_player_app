import 'dart:async';

import 'package:flutter/material.dart';

import '../models/channel.dart';

class BroadcastClock extends StatefulWidget {
  const BroadcastClock({super.key, required this.channel});
  final Channel channel;
  @override
  State<BroadcastClock> createState() => _BroadcastClockState();
}

class _BroadcastClockState extends State<BroadcastClock> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.channel.broadcastDurationLabel(),
    style: const TextStyle(color: Colors.white, fontSize: 12),
  );
}
