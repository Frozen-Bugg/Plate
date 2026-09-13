import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera and returns the first barcode read, or null if the lifter
/// backed out.
///
/// Deliberately does no lookup of its own: reading the code and deciding what
/// it means are separate jobs, and a scanner that also talks to the network is
/// a scanner that cannot be tested without one.
Future<String?> scanBarcode(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const _ScannerScreen(), fullscreenDialog: true),
  );
}

class _ScannerScreen extends StatefulWidget {
  const _ScannerScreen();

  @override
  State<_ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<_ScannerScreen> {
  final _controller = MobileScannerController(
    // Only the symbologies that appear on food. Narrowing it makes the read
    // faster and stops a QR code on the same packet winning the race.
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// The scanner keeps firing after a hit; without this the first barcode pops
  /// the screen and the second tries to pop whatever replaced it.
  var _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .where(_looksLikeBarcode)
        .firstOrNull;
    if (code == null) return;

    _handled = true;
    Navigator.of(context).pop(code);
  }

  /// The same 6–14 digits the schema accepts. A misread that is not a barcode
  /// should keep the camera open rather than fail a lookup.
  static bool _looksLikeBarcode(String value) =>
      RegExp(r'^[0-9]{6,14}$').hasMatch(value);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan a barcode'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // A camera that cannot start says why. The usual cause is a denied
            // permission, and "nothing happened" is the worst way to learn it.
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined,
                        color: Colors.white70, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      switch (error.errorCode) {
                        MobileScannerErrorCode.permissionDenied =>
                          'Overload needs the camera to read a barcode. Allow '
                              'it in Settings → Apps → Overload → Permissions.',
                        MobileScannerErrorCode.unsupported =>
                          'This device cannot scan barcodes. Search by name '
                              'instead.',
                        _ => 'The camera would not start.\n${error.errorDetails?.message ?? ''}',
                      },
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // A window to aim through. Purely a target — the scanner reads the
          // whole frame, and cropping to this would only make it fussier.
          IgnorePointer(
            child: Container(
              width: 260,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 48,
            left: 32,
            right: 32,
            child: Text(
              'Point at the barcode on the packet',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
