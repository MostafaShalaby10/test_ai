import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'image_marker_registry.dart';

typedef OnMarkerDetected = void Function(ImageMarker marker);
typedef OnMarkerLost = void Function(int targetIndex);

class MindARDetector extends StatefulWidget {
  final String mindFileUrl;
  final ImageMarkerRegistry registry;
  final int maxTrack;
  final OnMarkerDetected? onMarkerDetected;
  final OnMarkerLost? onMarkerLost;
  final void Function(String error)? onError;
  final bool showDebug;

  const MindARDetector({super.key, required this.mindFileUrl, required this.registry, this.maxTrack = 3, this.onMarkerDetected, this.onMarkerLost, this.onError, this.showDebug = false});

  @override
  State<MindARDetector> createState() => _MindARDetectorState();
}

class _MindARDetectorState extends State<MindARDetector> {
  late WebViewController _wvc;
  String _status = 'Initializing...';
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    log('Init: mindFile=${widget.mindFileUrl} maxTrack=${widget.maxTrack} registeredMarkers=${widget.registry.count}', name: 'MINDAR');
    _initWebView();
  }

  void _initWebView() {
    _wvc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // ..setOnPermissionRequest((r) { log('WebView permission request: ${r.types}', name: 'MINDAR'); r.grant(); })
      ..addJavaScriptChannel('MarkerChannel', onMessageReceived: _onJSMsg)
      ..setBackgroundColor(Colors.transparent)
      ..loadRequest(Uri.parse(
        'file:///android_asset/flutter_assets/assets/mindar_tracker.html'
        '?mindFile=${Uri.encodeComponent(widget.mindFileUrl)}'
        '&maxTrack=${widget.maxTrack}',
      ));
    log('WebView created, loading HTML...', name: 'MINDAR');
  }

  void _onJSMsg(JavaScriptMessage msg) {
    log('JS message received: ${msg.message}', name: 'MINDAR');
    try {
      final data = jsonDecode(msg.message) as Map<String, dynamic>;
      final event = data['event'] as String;

      switch (event) {
        case 'onMarkerDetected':
          final idx = data['targetIndex'] as int;
          log('Marker DETECTED: targetIndex=$idx', name: 'MINDAR');
          final marker = widget.registry.lookup(idx);
          if (marker == null) {
            log('WARNING: targetIndex=$idx not in registry. Ignoring.', name: 'MINDAR');
            setState(() => _status = 'Unknown #$idx');
            return;
          }
          setState(() { _status = '✓ ${marker.name}'; _isReady = true; });
          log('✓ Matched marker: ${marker.name} pos=${marker.position}', name: 'MINDAR');
          widget.onMarkerDetected?.call(marker);
          break;

        case 'onMarkerLost':
          final idx = data['targetIndex'] as int;
          log('Marker LOST: targetIndex=$idx', name: 'MINDAR');
          setState(() => _status = 'Scanning...');
          widget.onMarkerLost?.call(idx);
          break;

        case 'onError':
          final err = data['message'] as String? ?? 'Unknown';
          log('ERROR from JS: $err', name: 'MINDAR');
          setState(() => _status = 'Error: $err');
          widget.onError?.call(err);
          break;

        default:
          log('Unknown event: $event', name: 'MINDAR');
      }
    } catch (e) { log('Failed to parse JS message: $e raw=${msg.message}', name: 'MINDAR'); }
  }

  void pause() { log('Pausing tracking', name: 'MINDAR'); _wvc.runJavaScript('pauseTracking()'); }
  void resume() { log('Resuming tracking', name: 'MINDAR'); _wvc.runJavaScript('resumeTracking()'); }
  void stop() { log('Stopping tracking', name: 'MINDAR'); _wvc.runJavaScript('stopTracking()'); }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _wvc)),
      if (widget.showDebug) Positioned(
        top: 0, right: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: (_isReady ? Colors.green : Colors.orange).withOpacity(0.8), borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(8))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_isReady ? Icons.visibility : Icons.search, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text(_status, style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'monospace')),
          ]),
        ),
      ),
    ]);
  }
}
