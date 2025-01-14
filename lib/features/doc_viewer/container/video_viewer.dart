import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:madari_client/features/connections/service/base_connection_service.dart';
import 'package:madari_client/features/watch_history/service/base_watch_history.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../utils/load_language.dart';
import '../../connections/types/stremio/stremio_base.types.dart' as types;
import '../../trakt/service/trakt.service.dart';
import '../../watch_history/service/zeee_watch_history.dart';
import '../types/doc_source.dart';
import 'video_viewer/video_viewer_ui.dart';

class VideoViewer extends StatefulWidget {
  final DocSource source;
  final LibraryItem? meta;
  final BaseConnectionService? service;
  final String? currentSeason;
  final String? library;

  const VideoViewer({
    super.key,
    required this.source,
    this.meta,
    this.service,
    this.currentSeason,
    this.library,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  late LibraryItem? meta = widget.meta;

  final zeeeWatchHistory = ZeeeWatchHistoryStatic.service;
  Timer? _timer;
  late final Player player = Player(
    configuration: const PlayerConfiguration(
      title: "Madari",
    ),
  );
  final Logger _logger = Logger('VideoPlayer');

  double get currentProgressInPercentage {
    final duration = player.state.duration.inSeconds;
    final position = player.state.position.inSeconds;
    return duration > 0 ? (position / duration * 100) : 0;
  }

  bool timeLoaded = false;

  Future<types.Meta>? traktProgress;

  Future<void> saveWatchHistory() async {
    final duration = player.state.duration.inSeconds;

    if (duration <= 30) {
      _logger.info('Video is too short to track.');
      return;
    }

    if (gotFromTraktDuration == false) {
      _logger.info(
        "did not start the scrobbing because initially time is not retrieved from the api",
      );
      return;
    }

    final position = player.state.position.inSeconds;
    final progress = duration > 0 ? (position / duration * 100) : 0;

    if (progress < 0.01) {
      _logger.info('No progress to save.');
      return;
    }

    if (meta is types.Meta && TraktService.instance != null) {
      try {
        if (player.state.playing) {
          _logger.info('Starting scrobbling...');
          await TraktService.instance!.startScrobbling(
            meta: meta as types.Meta,
            progress: currentProgressInPercentage,
          );
        } else {
          _logger.info('Stopping scrobbling...');
          await TraktService.instance!.stopScrobbling(
            meta: meta as types.Meta,
            progress: currentProgressInPercentage,
          );
        }
      } catch (e) {
        _logger.severe('Error during scrobbling: $e');
        TraktService.instance!.debugLogs.add(e.toString());
      }
    } else {
      _logger.warning('Meta is not valid or TraktService is not initialized.');
    }

    await zeeeWatchHistory!.saveWatchHistory(
      history: WatchHistory(
        id: _source.id,
        progress: progress.round(),
        duration: duration.toDouble(),
        episode: _source.episode,
        season: _source.season,
      ),
    );
  }

  late final controller = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      enableHardwareAcceleration: !config.softwareAcceleration,
    ),
  );

  late DocSource _source;

  bool gotFromTraktDuration = false;

  int? traktId;

  Future<void> setDurationFromTrakt() async {
    try {
      if (player.state.duration.inSeconds < 2) {
        return;
      }

      if (gotFromTraktDuration) {
        return;
      }

      gotFromTraktDuration = true;

      if (!TraktService.isEnabled() || traktProgress == null) {
        player.play();
        return;
      }

      final progress = await traktProgress;

      if (this.meta is! types.Meta) {
        return;
      }

      final meta = (progress ?? this.meta) as types.Meta;

      final duration = Duration(
        seconds: calculateSecondsFromProgress(
          player.state.duration.inSeconds.toDouble(),
          meta.currentVideo?.progress ?? meta.progress ?? 0,
        ),
      );

      if (duration.inSeconds > 10) {
        await player.seek(duration);
      }

      await player.play();
    } catch (e) {
      await player.play();
    }
  }

  List<StreamSubscription> listener = [];

  PlaybackConfig config = getPlaybackConfig();

  Future setupVideoThings() async {
    _duration = player.stream.duration.listen((item) async {
      if (item.inSeconds != 0) {
        await saveWatchHistory();
      }
    });

    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      saveWatchHistory();
    });

    _streamListen = player.stream.playing.listen((playing) {
      saveWatchHistory();
    });

    return loadFile();
  }

  destroyVideoThing() async {
    timeLoaded = false;
    gotFromTraktDuration = false;
    traktProgress = null;

    for (final item in listener) {
      item.cancel();
    }
    _timer?.cancel();
    _streamListen?.cancel();
    _duration?.cancel();

    if (meta is types.Meta && player.state.duration.inSeconds > 30) {
      await TraktService.instance!.stopScrobbling(
        meta: meta as types.Meta,
        progress: currentProgressInPercentage,
        shouldClearCache: true,
        traktId: traktId,
      );
    }
  }

  GlobalKey videoKey = GlobalKey();

  generateNewKey() {
    videoKey = GlobalKey();

    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _source = widget.source;

    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );

    if (player.platform is NativePlayer && !kIsWeb) {
      Future.microtask(() async {
        await (player.platform as dynamic).setProperty('network-timeout', '60');
      });
    }

    onVideoChange(
      _source,
      widget.meta!,
    );
  }

  Future<void> loadFile() async {
    Duration duration = const Duration(seconds: 0);

    if (meta is types.Meta && TraktService.isEnabled()) {
      _logger.info("Playing video ${(meta as types.Meta).selectedVideoIndex}");

      traktProgress = TraktService.instance!.getProgress(
        meta as types.Meta,
      );
    } else {
      final item = await zeeeWatchHistory!.getItemWatchHistory(
        ids: [
          WatchHistoryGetRequest(
            id: _source.id,
            season: _source.season,
            episode: _source.episode,
          ),
        ],
      );

      duration = Duration(
        seconds: item.isEmpty
            ? 0
            : calculateSecondsFromProgress(
                item.first.duration,
                item.first.progress.toDouble(),
              ),
      );
    }

    _logger.info('Loading file for source: ${_source.id}');

    switch (_source.runtimeType) {
      case const (FileSource):
        if (kIsWeb) {
          return;
        }
        player.open(
          Media(
            (_source as FileSource).filePath,
            start: duration,
          ),
          play: false,
        );
      case const (URLSource):
      case const (MediaURLSource):
      case const (TorrentSource):
        player.open(
          Media(
            (_source as URLSource).url,
            httpHeaders: (_source as URLSource).headers,
            start: duration,
          ),
          play: false,
        );
    }
  }

  late StreamSubscription<bool>? _streamListen;
  late StreamSubscription<dynamic>? _duration;

  @override
  void dispose() {
    _logger.info('Disposing VideoViewer...');

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: [],
    );
    destroyVideoThing();
    player.dispose();
    super.dispose();
  }

  onVideoChange(DocSource source, LibraryItem item) async {
    _source = source;
    meta = item;

    setState(() {});
    await destroyVideoThing();
    setState(() {});
    traktProgress = null;
    await setupVideoThings();
    await setDurationFromTrakt();
    setState(() {});
    generateNewKey();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: VideoViewerUi(
        key: videoKey,
        controller: controller,
        player: player,
        config: config,
        source: _source,
        onLibrarySelect: () {},
        service: widget.service,
        meta: meta,
        onSourceChange: (source, meta) => onVideoChange(source, meta),
      ),
    );
  }
}

int calculateSecondsFromProgress(
  double duration,
  double progressPercentage,
) {
  final clampedProgress = progressPercentage.clamp(0.0, 100.0);
  final currentSeconds = (duration * (clampedProgress / 100)).round();
  return currentSeconds;
}
