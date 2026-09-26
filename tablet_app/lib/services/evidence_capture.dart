import 'dart:convert';
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
    this.bytes,
  });

  /// Whether a file ended up on the disk.
  final bool ok;

  /// How long takeScreenshot itself took.
  ///
  /// There is nothing else in this number any more. A fixed wait used to sit in
  /// front of it, put there to let the confirmation dialog disappear - a guess at
  /// how long a frame takes on a tablet nobody had measured. The page now
  /// announces only once it has drawn the finished screen, so there is nothing
  /// left to wait for here.
  final int ms;

  final String? file;
  final String? error;

  /*
   * The image itself, for the one caller that has to hand it to the page.
   *
   * Deliberately NOT kept in EvidenceCapture.last. That field lives for as long
   * as the app does, and holding four hundred kilobytes there for the rest of a
   * show day to show a thumbnail nobody may open is memory spent for nothing.
   * The viewer reads the file off the disk instead.
   */
  final Uint8List? bytes;

  EvidenceShot withoutBytes() =>
      EvidenceShot(ok: ok, ms: ms, file: file, error: error);

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

      /*
       * THE SIDECAR IS WHAT MAKES THIS FILE RE-SENDABLE.
       *
       * Everything the upload needs - show, class, horse, the submission id, the
       * moment it was sent - arrives from the page and exists nowhere else. A
       * .jpg on its own cannot be uploaded later because nobody would know what
       * it is of.
       *
       * Its presence is also the state: a .json beside a .jpg means NOT YET
       * ACKNOWLEDGED BY THE SERVER. The page deletes it through ack() once the
       * upload is stored, and the 48-hour cleanup steps over any file that still
       * has one. So a photograph that never reached the server is never deleted
       * for being old - it waits.
       */
      try {
        await File('$path.json').writeAsString(jsonEncode({
          ...moment,
          'capturedMs': sw.elapsedMilliseconds,
        }), flush: true);
      } catch (_) {
        // The image is on the disk and the page is about to upload it anyway.
        // A missing sidecar costs the retry, not the evidence.
      }

      return _remember(EvidenceShot(
        ok: true,
        ms: sw.elapsedMilliseconds,
        file: path,
        bytes: bytes,
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
    last = s.withoutBytes();
    return s;
  }

  /*
   * FORTY-EIGHT HOURS, AND THEN THE TABLET LETS GO.
   *
   * The server holds the copy that matters - it is authenticated, it carries the
   * server's own timestamp, and deleting from it is manual and always will be.
   * What sits here is the staging post, and a tablet that never forgets fills up
   * in the middle of a season.
   *
   * WHEN THE OUTBOX ARRIVES (stage 5) THIS HAS TO CHANGE: a file still waiting
   * to be uploaded must be exempt, or two days without a network would delete
   * evidence that never reached the server at all. Today nothing queues, so age
   * alone is the rule.
   *
   * Failures are swallowed per file. A locked or vanished file is not a reason
   * to stop cleaning up the rest, and none of this is worth a word on screen.
   */
  static const Duration keepFor = Duration(hours: 48);

  static Future<Directory?> _root() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory('${docs.path}${Platform.pathSeparator}evidence');
      return d.existsSync() ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// Sidecars, oldest first - the ones still waiting to reach the server.
  static Future<List<File>> _pending() async {
    final root = await _root();
    if (root == null) return const [];
    final out = <File>[];
    try {
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.jpg.json')) out.add(e);
      }
      out.sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {}
    return out;
  }

  static Future<int> pendingCount() async => (await _pending()).length;

  /*
   * ONE waiting photograph, for the page to upload.
   *
   * One, not all of them. A class gives a send every minute or two, so twelve
   * horses are twelve chances to drain - while handing over ten images at once
   * would push five megabytes across the bridge in the middle of a class, at
   * exactly the moment the network has already shown it is unreliable.
   */
  static Future<Map<String, dynamic>?> nextPending() async {
    for (final side in await _pending()) {
      try {
        final meta = jsonDecode(await side.readAsString()) as Map<String, dynamic>;
        final jpg = File(side.path.substring(0, side.path.length - 5));
        if (!jpg.existsSync()) {
          // The sidecar outlived its image - nothing to send, so stop tracking it.
          try { await side.delete(); } catch (_) {}
          continue;
        }
        return {
          'meta': meta,
          'b64': base64Encode(await jpg.readAsBytes()),
        };
      } catch (_) {
        // A sidecar that cannot be read is not a reason to stop draining.
      }
    }
    return null;
  }

  /// The server has it. Drop the sidecar; the image stays until it ages out.
  static Future<bool> ack(String id) async {
    final want = id.trim();
    if (want.isEmpty) return false;
    for (final side in await _pending()) {
      try {
        final meta = jsonDecode(await side.readAsString()) as Map<String, dynamic>;
        if ((meta['id'] ?? '').toString().trim() == want) {
          await side.delete();
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  static Future<int> pruneOld() async {
    var removed = 0;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}${Platform.pathSeparator}evidence');
      if (!root.existsSync()) return 0;
      final cutoff = DateTime.now().subtract(keepFor);

      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          /*
           * A file that still has a sidecar has not reached the server. Age is
           * not a reason to delete it - the whole point of keeping anything here
           * is that the server has the copy that matters, and for this one it
           * does not. It waits instead, and the next send drags it along.
           */
          if (e.path.endsWith('.jpg') && File('${e.path}.json').existsSync()) continue;
          if ((await e.lastModified()).isBefore(cutoff)) {
            await e.delete();
            removed++;
          }
        } catch (_) {}
      }

      // Second pass: the folders the files leave behind. Deepest first, so a
      // class folder can go once its judge folders have.
      final dirs = <Directory>[];
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is Directory) dirs.add(e);
      }
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        try {
          if (d.listSync().isEmpty) await d.delete();
        } catch (_) {}
      }
    } catch (_) {}
    return removed;
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
