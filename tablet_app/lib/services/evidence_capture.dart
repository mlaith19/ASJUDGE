import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// One attempt at photographing what the judge was looking at.
class EvidenceShot {
  const EvidenceShot({
    required this.ok,
    required this.ms,
    this.file,
    this.error,
  });

  /// Whether a file ended up on the disk.
  final bool ok;

  /// How long this took, from the page's announcement to the pixels being taken.
  ///
  /// The settle wait is INSIDE this number on purpose. What matters is the whole
  /// window between the judge pressing SEND and the frame being grabbed, because
  /// that is what races the admin pushing the next horse - not the cost of the
  /// screenshot call on its own.
  final int ms;

  final String? file;
  final String? error;

  String get status => ok ? 'ok' : 'failed';

  String get fileName {
    final f = file;
    if (f == null || f.isEmpty) return '';
    return f.split(Platform.pathSeparator).last.split('/').last;
  }
}

/*
 * THE CAPTURE ITSELF.
 *
 * Its own file rather than more weight in webview_screen.dart, because stage 4
 * adds the front camera and the compositing here, and that belongs next to this
 * and not inside a screen that is already long.
 *
 * WHY JPEG AND NOT PNG
 * A tablet screen as PNG is one to two megabytes. The same frame as JPEG at 80 is
 * two to four hundred kilobytes, which is what the decided budget of about 80MB
 * per show was calculated from - and it is the .jpg the agreed folder layout
 * already names.
 *
 * WHY THE LAYOUT MATCHES THE SERVER'S
 * Stage 3 uploads these files. Naming them here the way the server will store
 * them means that stage reads and sends, rather than inventing names a second
 * time and having two places that must agree forever.
 *
 * ONE DEVIATION FROM THE SKETCH, DELIBERATE: the judge folder is the nickname the
 * page is signed in as, not a tablet letter. The tablet no longer holds an
 * identity of its own - that is a closed decision - so the page's sign-in is the
 * only identity in hand at this stage. The letter arrives in stage 4, alongside
 * it rather than instead of it, because a disagreement between the two is the
 * finding and not a detail to resolve by picking one.
 */
class EvidenceCapture {
  /// Time given to the native WebView surface to catch up with the page's paint.
  static const Duration _settleDelay = Duration(milliseconds: 150);

  /// The most recent attempt, for the viewer in the kiosk menu.
  ///
  /// Nothing is uploaded at this stage, so without a way to look at the file on
  /// the tablet itself there is no way to check the one thing stage 2 exists to
  /// check: that the image shows the horse that was sent.
  static EvidenceShot? last;

  static Future<EvidenceShot> capture({
    required InAppWebViewController controller,
    required Map<String, dynamic> moment,
  }) async {
    final sw = Stopwatch()..start();
    try {
      /*
       * WHY THIS WAITS - FOUND ON A TABLET, 26/09
       *
       * The page already waits for its own paint before announcing, through two
       * nested requestAnimationFrames, so by the time this runs the browser has
       * drawn the screen without the confirmation dialog.
       *
       * This covers a different gap, and it is not the same wait twice. What
       * takeScreenshot draws from is the native WebView surface, and the browser
       * having painted does not guarantee that surface has been recomposited in
       * the same instant.
       *
       * It is affordable rather than careful: the judge cannot change horse at
       * all, so the only thing that can replace the screen is the admin pushing
       * the next one, about three seconds away. A capture measured at 49ms plus
       * this is still under a tenth of that.
       */
      await Future<void>.delayed(_settleDelay);

      final Uint8List? bytes = await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.JPEG,
          quality: 80,
        ),
      );
      sw.stop();

      if (bytes == null || bytes.isEmpty) {
        // The plugin answers null when the WebView has nothing to draw - a page
        // mid-navigation, or a surface Android has taken away. Not an error to
        // throw, but not a photograph either.
        return _remember(EvidenceShot(
          ok: false,
          ms: sw.elapsedMilliseconds,
          error: 'empty',
        ));
      }

      final path = await _pathFor(moment);
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);

      return _remember(EvidenceShot(
        ok: true,
        ms: sw.elapsedMilliseconds,
        file: path,
      ));
    } catch (e) {
      if (sw.isRunning) sw.stop();
      return _remember(EvidenceShot(
        ok: false,
        ms: sw.elapsedMilliseconds,
        error: e.toString(),
      ));
    }
  }

  static EvidenceShot _remember(EvidenceShot s) {
    last = s;
    return s;
  }

  static Future<String> _pathFor(Map<String, dynamic> moment) async {
    final docs = await getApplicationDocumentsDirectory();

    final show = _seg(moment['showId'], fallback: 'no-show');
    final klass = _seg(moment['classId'], fallback: 'no-class');
    final judge = _seg(moment['judgeNickname'], fallback: 'no-judge');

    // Three digits, so the folder sorts the way the class runs. Without the
    // padding it reads 1, 10, 11, 2.
    final n = int.tryParse(_digits(moment['horseNumber']));
    final horse = (n == null) ? '000' : n.toString().padLeft(3, '0');

    final name = _seg(moment['horseName'], fallback: 'unnamed');

    // The id the page minted BEFORE it touched any state, and the same one that
    // travels to the server with the score. It is what ties a file to a
    // submission, and it is why a re-send never overwrites earlier evidence.
    final id = _seg(moment['id'], fallback: 'no-id');

    return '${docs.path}${Platform.pathSeparator}evidence'
        '${Platform.pathSeparator}$show'
        '${Platform.pathSeparator}$klass'
        '${Platform.pathSeparator}$judge'
        '${Platform.pathSeparator}${horse}_${name}_$id.jpg';
  }

  /// Anything that is not a letter, a digit or a dash becomes a dash: these end
  /// up as file and folder names, and a judge nickname or a horse name can carry
  /// spaces, slashes and quotes.
  static String _seg(Object? v, {required String fallback}) {
    final raw = (v ?? '').toString().trim();
    if (raw.isEmpty) return fallback;
    final cleaned = raw
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isEmpty) return fallback;
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  static String _digits(Object? v) =>
      (v ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
}
