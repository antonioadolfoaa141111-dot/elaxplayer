import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

late final RelaxAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _audioHandler = await AudioService.init(
    builder: () => RelaxAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.relaxplayer.channel.audio',
      androidNotificationChannelName: 'relaxPlayer',
      androidNotificationIcon: 'drawable/ic_stat_relax',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidShowNotificationBadge: false,
      androidNotificationClickStartsActivity: true,
    ),
  );
  await _audioHandler.initAudioSession();
  runApp(const RelaxPlayerApp());
}

// --- Servicio de audio nativo + Ecualizador Android + Refuerzo de bajos ---

class RelaxAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  static const MediaControl _ctrlPrev = MediaControl(
    androidIcon: 'drawable/ic_media_prev',
    label: 'Anterior',
    action: MediaAction.skipToPrevious,
  );
  static const MediaControl _ctrlPause = MediaControl(
    androidIcon: 'drawable/ic_media_pause',
    label: 'Pausar',
    action: MediaAction.pause,
  );
  static const MediaControl _ctrlPlay = MediaControl(
    androidIcon: 'drawable/ic_media_play',
    label: 'Reproducir',
    action: MediaAction.play,
  );
  static const MediaControl _ctrlNext = MediaControl(
    androidIcon: 'drawable/ic_media_next',
    label: 'Siguiente',
    action: MediaAction.skipToNext,
  );

  // Dos motores independientes con su propio ecualizador para crossfade real sin cortes
  final AndroidEqualizer _eqA = AndroidEqualizer();
  final AndroidLoudnessEnhancer _loudA = AndroidLoudnessEnhancer();
  final AndroidEqualizer _eqB = AndroidEqualizer();
  final AndroidLoudnessEnhancer _loudB = AndroidLoudnessEnhancer();

  late final AudioPlayer _playerA = AudioPlayer(
    audioPipeline: Platform.isAndroid
        ? AudioPipeline(androidAudioEffects: [_loudA, _eqA])
        : null,
  );
  late final AudioPlayer _playerB = AudioPlayer(
    audioPipeline: Platform.isAndroid
        ? AudioPipeline(androidAudioEffects: [_loudB, _eqB])
        : null,
  );

  bool _usingA = true;
  AudioPlayer get player => _usingA ? _playerA : _playerB;
  AudioPlayer get _standbyPlayer => _usingA ? _playerB : _playerA;
  AndroidEqualizer get equalizer => _usingA ? _eqA : _eqB;
  AndroidLoudnessEnhancer get loudnessEnhancer => _usingA ? _loudA : _loudB;

  final StreamController<Duration> _posController = StreamController<Duration>.broadcast();
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();

  Stream<Duration> get unifiedPositionStream => _posController.stream;
  Stream<bool> get unifiedPlayingStream => _playingController.stream;

  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;
  Future<void> Function()? onTrackCompleted;
  Future<void> Function()? onCrossfadeTrigger;
  Future<void> Function()? onPreloadNext;
  Future<void> Function()? onHeadphonesDisconnected;

  bool autoPauseOnDisconnect = true;
  int crossfadeSeconds = 4; // 0 = apagado, 2/4/6/8 segundos

  double _baseVolume = 0.85;
  bool _repeatOne = false;
  bool _completionSent = false;
  bool _preloadSent = false;
  bool _crossfading = false;
  bool _resumeAfterInterruption = false;
  int _fadeToken = 0;
  int _currentQueueIndex = 0;
  Timer? _fadeTimer;

  RelaxAudioHandler() {
    _attachListeners(_playerA, isA: true);
    _attachListeners(_playerB, isA: false);
  }

  void _attachListeners(AudioPlayer p, {required bool isA}) {
    p.playbackEventStream.listen((ev) {
      if (_usingA == isA) _broadcastState(ev);
    });
    p.playingStream.listen((playing) {
      if (_usingA == isA) {
        _playingController.add(playing);
        _broadcastState(p.playbackEvent);
      }
    });
    p.positionStream.listen((pos) {
      if (_usingA != isA) return;
      _posController.add(pos);

      // Pre-cargar siguiente pista en linea unos segundos antes para que el crossfade entre limpio
      final dur = p.duration;
      if (dur != null && dur.inSeconds > 16 && pos.inSeconds >= 3 && !_repeatOne && p.playing) {
        final remaining = dur - pos;
        if (!_preloadSent && remaining <= Duration(seconds: max(12, crossfadeSeconds + 10))) {
          _preloadSent = true;
          onPreloadNext?.call();
        }
        // Disparar transicion suave (Crossfade) cuando faltan X segundos para terminar
        if (crossfadeSeconds > 0 &&
            !_crossfading &&
            dur.inSeconds > crossfadeSeconds + 4 &&
            remaining <= Duration(seconds: crossfadeSeconds) &&
            remaining > const Duration(milliseconds: 350)) {
          _crossfading = true;
          onCrossfadeTrigger?.call();
        }
      }
    });
    p.processingStateStream.listen((state) {
      if (_usingA != isA) return;
      if (state == ProcessingState.completed) {
        if (!_completionSent && !_crossfading) {
          _completionSent = true;
          onTrackCompleted?.call();
        }
      } else if (state == ProcessingState.ready) {
        _completionSent = false;
      }
      _broadcastState(p.playbackEvent);
    });
    p.durationStream.listen((dur) {
      if (_usingA != isA) return;
      final current = mediaItem.value;
      if (current != null && dur != null && dur > Duration.zero && current.duration != dur) {
        mediaItem.add(current.copyWith(duration: dur));
      }
    });
  }

  Future<void> initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Pausa automatica al desconectar audifonos con cable o Bluetooth
      session.becomingNoisyEventStream.listen((_) async {
        if (!autoPauseOnDisconnect) return;
        final wasPlaying = player.playing;
        if (wasPlaying) {
          await pause();
        }
        await onHeadphonesDisconnected?.call();
      });

      // Manejo limpio de llamadas o interrupciones del sistema
      session.interruptionEventStream.listen((event) async {
        if (event.begin) {
          if (event.type == AudioInterruptionType.duck) {
            await player.setVolume((_baseVolume * 0.25).clamp(0.0, 1.0));
          } else {
            _resumeAfterInterruption = player.playing;
            if (player.playing) await pause();
          }
        } else {
          if (event.type == AudioInterruptionType.duck) {
            await player.setVolume(_baseVolume);
          } else if (event.type == AudioInterruptionType.pause && _resumeAfterInterruption) {
            _resumeAfterInterruption = false;
            await play();
          }
        }
      });
    } catch (_) {}
  }

  void _cancelCrossfade({bool stopStandby = true}) {
    _fadeToken++;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _crossfading = false;
    if (stopStandby) {
      unawaited(_standbyPlayer.stop());
    }
  }

  Future<void> setVolumeLive(double v) async {
    _baseVolume = v.clamp(0.0, 1.0);
    if (!_crossfading) {
      await player.setVolume(_baseVolume);
    }
  }

  Future<void> setSpeedLive(double s) async {
    await player.setSpeed(s);
  }

  Future<void> setRepeatOne(bool repeat) async {
    _repeatOne = repeat;
    await player.setLoopMode(repeat ? LoopMode.one : LoopMode.off);
  }

  Future<void> applyEqualizerToBoth({
    required bool enabled,
    required double loudnessGain,
    required List<double> bandGains,
  }) async {
    if (!Platform.isAndroid) return;
    for (final pair in [(_eqA, _loudA), (_eqB, _loudB)]) {
      try {
        await pair.$1.setEnabled(enabled);
        await pair.$2.setEnabled(enabled && loudnessGain > 0.01);
        await pair.$2.setTargetGain(loudnessGain);
        if (bandGains.isNotEmpty) {
          final params = await pair.$1.parameters.timeout(const Duration(seconds: 2));
          for (int i = 0; i < params.bands.length && i < bandGains.length; i++) {
            await params.bands[i].setGain(
              bandGains[i].clamp(params.minDecibels, params.maxDecibels),
            );
          }
        }
      } catch (_) {}
    }
  }

  static const Map<String, String> _streamHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://www.youtube.com/',
    'Origin': 'https://www.youtube.com',
  };

  Future<void> playMediaTrack({
    required String path,
    String? localFilePath,
    List<String>? sourceUrls,
    required String title,
    required String artist,
    required String album,
    Uri? artUri,
    required List<MediaItem> queueItems,
    required int queueIndex,
    required double volume,
    required double speed,
    required bool repeatOne,
    bool useCrossfade = false,
  }) async {
    _baseVolume = volume.clamp(0.0, 1.0);
    _repeatOne = repeatOne;
    _completionSent = false;
    _preloadSent = false;
    _currentQueueIndex = queueIndex.clamp(0, max(0, queueItems.length - 1));

    final currentItem = MediaItem(
      id: path,
      title: title,
      artist: artist,
      album: album,
      artUri: artUri,
    );

    Future<Duration?> loadInto(AudioPlayer target) async {
      if (localFilePath != null && localFilePath.isNotEmpty) {
        return target.setFilePath(localFilePath);
      }
      if (sourceUrls != null && sourceUrls.isNotEmpty) {
        Object? lastErr;
        for (final url in sourceUrls) {
          try {
            return await target
                .setUrl(url, headers: _streamHeaders)
                .timeout(const Duration(seconds: 10));
          } catch (e) {
            lastErr = e;
          }
        }
        throw lastErr ?? Exception('No se pudo abrir el stream');
      }
      return target.setFilePath(path);
    }

    if (queueItems.isNotEmpty) {
      queue.add(queueItems);
    } else {
      queue.add([currentItem]);
    }
    mediaItem.add(currentItem);

    if (useCrossfade && crossfadeSeconds > 0) {
      final outgoing = player;
      final incoming = _standbyPlayer;
      final token = ++_fadeToken;
      _fadeTimer?.cancel();

      try {
        final dur = await loadInto(incoming);
        if (dur != null && dur > Duration.zero) {
          mediaItem.add(currentItem.copyWith(duration: dur));
        }
        await incoming.setSpeed(speed);
        await incoming.setLoopMode(repeatOne ? LoopMode.one : LoopMode.off);
        await incoming.setVolume(0.0);

        // Intercambiar motor activo para que la barra y notificacion muestren el tema nuevo
        _usingA = !_usingA;
        _posController.add(Duration.zero);
        _playingController.add(true);
        unawaited(incoming.play());
        _broadcastState(incoming.playbackEvent, forcePlaying: true);

        const totalSteps = 24;
        final stepMs = max(60, (crossfadeSeconds * 1000) ~/ totalSteps);
        int step = 0;

        _fadeTimer = Timer.periodic(Duration(milliseconds: stepMs), (timer) {
          if (token != _fadeToken) {
            timer.cancel();
            return;
          }
          step++;
          final t = (step / totalSteps).clamp(0.0, 1.0);
          unawaited(outgoing.setVolume(_baseVolume * (1.0 - t)));
          unawaited(incoming.setVolume(_baseVolume * t));

          if (step >= totalSteps) {
            timer.cancel();
            _fadeTimer = null;
            _crossfading = false;
            unawaited(outgoing.stop());
            unawaited(outgoing.setVolume(_baseVolume));
          }
        });
        return;
      } catch (_) {
        _crossfading = false;
        rethrow;
      }
    }

    // Cambio manual instantaneo
    _cancelCrossfade(stopStandby: true);
    final active = player;
    final dur = await loadInto(active);
    if (dur != null && dur > Duration.zero) {
      mediaItem.add(currentItem.copyWith(duration: dur));
    }
    await active.setVolume(_baseVolume);
    await active.setSpeed(speed);
    await active.setLoopMode(repeatOne ? LoopMode.one : LoopMode.off);

    unawaited(active.play());
    _playingController.add(true);
    _broadcastState(active.playbackEvent, forcePlaying: true);
  }

  void updateCurrentMetadata(String path, {String? title, String? artist, Uri? artUri}) {
    final current = mediaItem.value;
    if (current != null && current.id == path) {
      mediaItem.add(
        current.copyWith(
          title: title ?? current.title,
          artist: artist ?? current.artist,
          artUri: artUri ?? current.artUri,
        ),
      );
    }
  }

  void _broadcastState(PlaybackEvent event, {bool? forcePlaying}) {
    final active = player;
    final playing = forcePlaying ?? active.playing;
    const stateMap = <ProcessingState, AudioProcessingState>{
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    };

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          _ctrlPrev,
          playing ? _ctrlPause : _ctrlPlay,
          _ctrlNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: stateMap[active.processingState] ?? AudioProcessingState.ready,
        playing: playing,
        updatePosition: active.position,
        bufferedPosition: active.bufferedPosition,
        speed: active.speed,
        queueIndex: _currentQueueIndex,
      ),
    );
  }

  @override
  Future<void> play() async {
    await player.setVolume(_baseVolume);
    unawaited(player.play());
    _playingController.add(true);
    _broadcastState(player.playbackEvent, forcePlaying: true);
  }

  @override
  Future<void> pause() async {
    _cancelCrossfade(stopStandby: true);
    await player.pause();
    await player.setVolume(_baseVolume);
    _playingController.add(false);
    _broadcastState(player.playbackEvent, forcePlaying: false);
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    _posController.add(position);
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> skipToNext() async {
    if (onSkipNext != null) {
      await onSkipNext!();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipPrevious != null) {
      await onSkipPrevious!();
    }
  }

  @override
  Future<void> stop() async {
    _cancelCrossfade(stopStandby: true);
    await player.stop();
    await super.stop();
  }
}

// --- Constantes y utilidades ---

const Set<String> kAudioExts = {
  '.mp3', '.wav', '.ogg', '.flac', '.m4a', '.aac', '.opus', '.wma', '.amr',
};

const Set<String> kVideoExts = {
  '.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.3gp', '.ts',
};

const Map<String, Color> kAccentThemes = {
  'Morado': Color(0xFF9B5DE5),
  'Verde': Color(0xFF1DB954),
  'Naranja': Color(0xFFFF6B35),
  'Azul': Color(0xFF00BBF9),
  'Rosa': Color(0xFFF15BB5),
};

const Map<String, List<double>> kEqPresets = {
  'Plano': [0.0, 0.0, 0.0, 0.0, 0.0],
  'Bass Boost': [0.85, 0.55, 0.05, 0.15, 0.25],
  'Urbano': [0.75, 0.45, -0.05, 0.35, 0.55],
  'Noche': [0.35, 0.25, 0.12, -0.15, -0.25],
  'Vocal': [-0.20, 0.10, 0.55, 0.45, 0.15],
};

const List<double> kSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const List<String> kOnlineQuickGenres = [
  'Lofi Chill',
  'Urbano',
  'Reggaetón',
  'Pop',
  'Rock',
  'Electrónica',
  'Acústico',
  'Salsa',
];
const List<String> kWeekDays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

const Set<String> kIgnoredDirs = {
  '.thumbnails', '.trash', '.cache', 'cache', 'temp', 'tmp',
  'notifications', 'ringtones', 'alarms', 'stickers', 'obb', 'data', 'android',
};

Color withA(Color c, double opacity) {
  return c.withAlpha((opacity.clamp(0.0, 1.0) * 255).round());
}

Color blendSolid(Color accent, Color bg, double weight) {
  return Color.lerp(bg, accent, weight.clamp(0.0, 1.0)) ?? bg;
}

String formatTime(Duration d) {
  final totalSec = max(0, d.inSeconds);
  final hrs = totalSec ~/ 3600;
  final mins = (totalSec % 3600) ~/ 60;
  final secs = totalSec % 60;
  if (hrs > 0) {
    return '$hrs:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
  return '$mins:${secs.toString().padLeft(2, '0')}';
}

String formatFrequency(double hz) {
  if (hz >= 1000) {
    final k = hz / 1000.0;
    return k == k.roundToDouble() ? '${k.toInt()}k' : '${k.toStringAsFixed(1)}k';
  }
  return '${hz.round()}Hz';
}

String fileExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return '';
  return path.substring(dot).toLowerCase();
}

String fileBaseName(String path) {
  final clean = path.replaceAll('\\', '/');
  final slash = clean.lastIndexOf('/');
  final name = slash >= 0 ? clean.substring(slash + 1) : clean;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String parentFolderName(String path) {
  final clean = path.replaceAll('\\', '/');
  final slash = clean.lastIndexOf('/');
  if (slash <= 0) return 'Dispositivo';
  final parent = clean.substring(0, slash);
  final prevSlash = parent.lastIndexOf('/');
  final name = prevSlash >= 0 ? parent.substring(prevSlash + 1) : parent;
  return name.isEmpty ? 'Dispositivo' : name;
}

String pathWithoutExtension(String path) {
  final dot = path.lastIndexOf('.');
  final slash = max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  if (dot > slash) return path.substring(0, dot);
  return path;
}

// --- Extractor de color dominante puro en Dart (Colores Camaleon sin paquetes extra) ---

class CoverColorExtractor {
  static final Map<String, Color> _cache = {};

  static Future<Color?> extractDominant(String imagePath) async {
    if (_cache.containsKey(imagePath)) return _cache[imagePath];
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24, targetHeight: 24);
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (bd == null) return null;

      final data = bd.buffer.asUint8List();
      final bucketWeight = List<double>.filled(12, 0.0);
      final bucketR = List<double>.filled(12, 0.0);
      final bucketG = List<double>.filled(12, 0.0);
      final bucketB = List<double>.filled(12, 0.0);

      for (int i = 0; i + 3 < data.length; i += 4) {
        final a = data[i + 3];
        if (a < 180) continue;
        final r = data[i];
        final g = data[i + 1];
        final b = data[i + 2];
        final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
        if (hsl.lightness < 0.12 || hsl.lightness > 0.88 || hsl.saturation < 0.16) {
          continue;
        }
        final score = (hsl.saturation * hsl.saturation) * (1.0 - (hsl.lightness - 0.5).abs());
        final idx = ((hsl.hue / 30.0).floor()) % 12;
        bucketWeight[idx] += score;
        bucketR[idx] += r * score;
        bucketG[idx] += g * score;
        bucketB[idx] += b * score;
      }

      int bestIdx = -1;
      double bestW = 0.0;
      for (int i = 0; i < 12; i++) {
        if (bucketWeight[i] > bestW) {
          bestW = bucketWeight[i];
          bestIdx = i;
        }
      }
      if (bestIdx < 0 || bestW <= 0) return null;

      final avgColor = Color.fromARGB(
        255,
        (bucketR[bestIdx] / bestW).round().clamp(0, 255),
        (bucketG[bestIdx] / bestW).round().clamp(0, 255),
        (bucketB[bestIdx] / bestW).round().clamp(0, 255),
      );
      final normalized = HSLColor.fromColor(avgColor);
      final vibrant = normalized
          .withSaturation(normalized.saturation.clamp(0.48, 0.84))
          .withLightness(normalized.lightness.clamp(0.44, 0.58))
          .toColor();

      if (_cache.length > 60) _cache.clear();
      _cache[imagePath] = vibrant;
      return vibrant;
    } catch (_) {
      return null;
    }
  }

  static void invalidate(String imagePath) {
    _cache.remove(imagePath);
  }
}

// --- Parser de letras sincronizadas (.lrc) y texto plano ---

class LyricLine {
  final Duration? time;
  final String text;

  const LyricLine({this.time, required this.text});
}

class LyricsParser {
  static final RegExp _tagRegex = RegExp(r'\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\]');

  static List<LyricLine> parse(String raw) {
    final lines = <LyricLine>[];
    bool hasTimestamps = false;

    for (final rawLine in raw.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      final matches = _tagRegex.allMatches(trimmed).toList();
      if (matches.isNotEmpty) {
        hasTimestamps = true;
        final text = trimmed.replaceAll(_tagRegex, '').trim();
        if (text.isEmpty) continue;
        for (final m in matches) {
          final mins = int.tryParse(m.group(1) ?? '0') ?? 0;
          final secs = int.tryParse(m.group(2) ?? '0') ?? 0;
          final fracStr = m.group(3) ?? '0';
          int ms = int.tryParse(fracStr) ?? 0;
          if (fracStr.length == 1) ms *= 100;
          if (fracStr.length == 2) ms *= 10;
          lines.add(
            LyricLine(
              time: Duration(minutes: mins, seconds: secs, milliseconds: ms),
              text: text,
            ),
          );
        }
      } else {
        // Ignorar etiquetas meta [ar:...], [ti:...]
        if (trimmed.startsWith('[') && trimmed.endsWith(']') && trimmed.contains(':')) {
          continue;
        }
        lines.add(LyricLine(text: trimmed));
      }
    }

    if (hasTimestamps) {
      lines.sort((a, b) => (a.time ?? Duration.zero).compareTo(b.time ?? Duration.zero));
    }
    return lines;
  }

  static int activeIndex(List<LyricLine> lines, Duration pos) {
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      final t = lines[i].time;
      if (t != null && t <= pos + const Duration(milliseconds: 220)) {
        idx = i;
      }
    }
    return idx;
  }
}

// --- Boton tactil con rebote elastico suave ---

class _SpringPressButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double pressedScale;

  const _SpringPressButton({
    required this.child,
    required this.onTap,
    this.pressedScale = 0.90,
  });

  @override
  State<_SpringPressButton> createState() => _SpringPressButtonState();
}

class _SpringPressButtonState extends State<_SpringPressButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

class MediaTrack {
  final String path;
  String title;
  String artist;
  final String folder;
  final String ext;
  final bool isVideo;
  final int modifiedMs;
  String? coverPath;
  bool metadataLoaded;
  final bool isOnline;
  final String? onlineVideoId;
  final String? remoteArtUrl;
  final int? durationMs;

  MediaTrack({
    required this.path,
    required this.title,
    required this.artist,
    required this.folder,
    required this.ext,
    required this.isVideo,
    required this.modifiedMs,
    this.coverPath,
    this.metadataLoaded = false,
    this.isOnline = false,
    this.onlineVideoId,
    this.remoteArtUrl,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'artist': artist,
        'folder': folder,
        'ext': ext,
        'isVideo': isVideo,
        'modifiedMs': modifiedMs,
        'coverPath': coverPath,
        'metadataLoaded': metadataLoaded,
        'isOnline': isOnline,
        'onlineVideoId': onlineVideoId,
        'remoteArtUrl': remoteArtUrl,
        'durationMs': durationMs,
      };

  factory MediaTrack.fromJson(Map<String, dynamic> json) => MediaTrack(
        path: json['path']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? 'Dispositivo',
        folder: json['folder']?.toString() ?? 'Dispositivo',
        ext: json['ext']?.toString() ?? '',
        isVideo: json['isVideo'] == true,
        modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
        coverPath: json['coverPath']?.toString(),
        metadataLoaded: json['metadataLoaded'] == true,
        isOnline: json['isOnline'] == true,
        onlineVideoId: json['onlineVideoId']?.toString(),
        remoteArtUrl: json['remoteArtUrl']?.toString(),
        durationMs: (json['durationMs'] as num?)?.toInt(),
      );
}

// --- Lector nativo en Dart puro de portadas y etiquetas ID3v2 (MP3) ---

class Id3Reader {
  static Future<void> loadTrackMetadata(MediaTrack track, String cacheDir) async {
    if (track.metadataLoaded || track.isVideo) return;
    track.metadataLoaded = true;
    if (track.ext != 'MP3') return;

    RandomAccessFile? raf;
    try {
      final file = File(track.path);
      if (!await file.exists()) return;
      raf = await file.open();
      final header = await raf.read(10);
      if (header.length < 10) return;
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) return;

      final version = header[3];
      final tagSize = ((header[6] & 0x7F) << 21) |
          ((header[7] & 0x7F) << 14) |
          ((header[8] & 0x7F) << 7) |
          (header[9] & 0x7F);
      if (tagSize <= 0) return;

      final bytesToRead = min(tagSize, 2 * 1024 * 1024);
      final data = await raf.read(bytesToRead);

      int pos = 0;
      while (pos + 10 <= data.length) {
        if (data[pos] == 0) break;
        final frameId = String.fromCharCodes(data.sublist(pos, pos + 4));
        int frameSize;
        if (version == 4) {
          frameSize = ((data[pos + 4] & 0x7F) << 21) |
              ((data[pos + 5] & 0x7F) << 14) |
              ((data[pos + 6] & 0x7F) << 7) |
              (data[pos + 7] & 0x7F);
        } else {
          frameSize = (data[pos + 4] << 24) |
              (data[pos + 5] << 16) |
              (data[pos + 6] << 8) |
              data[pos + 7];
        }
        pos += 10;
        if (frameSize <= 0 || pos + frameSize > data.length) break;

        final payload = data.sublist(pos, pos + frameSize);
        if (frameId == 'TIT2') {
          final txt = _decodeTextFrame(payload);
          if (txt.isNotEmpty) track.title = txt;
        } else if (frameId == 'TPE1') {
          final txt = _decodeTextFrame(payload);
          if (txt.isNotEmpty) track.artist = txt;
        } else if (frameId == 'APIC' && track.coverPath == null) {
          final imgBytes = _extractImageBytes(payload);
          if (imgBytes != null && imgBytes.length > 64) {
            final hash = track.path.hashCode.abs();
            final extImg = (imgBytes[0] == 0x89 && imgBytes[1] == 0x50) ? 'png' : 'jpg';
            final outFile = File('$cacheDir/cover_$hash.$extImg');
            if (!await outFile.exists()) {
              await outFile.writeAsBytes(imgBytes, flush: true);
            }
            track.coverPath = outFile.path;
          }
        }
        pos += frameSize;
      }
    } catch (_) {
      // Conserva nombre del archivo si el MP3 tiene etiquetas danadas
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  static String _decodeTextFrame(Uint8List payload) {
    if (payload.length < 2) return '';
    final enc = payload[0];
    final body = payload.sublist(1);
    try {
      if (enc == 0) {
        return latin1.decode(body).replaceAll('\x00', '').trim();
      } else if (enc == 3) {
        return utf8.decode(body, allowMalformed: true).replaceAll('\x00', '').trim();
      } else if (enc == 1 || enc == 2) {
        int start = 0;
        bool littleEndian = false;
        if (enc == 1 && body.length >= 2) {
          if (body[0] == 0xFF && body[1] == 0xFE) {
            littleEndian = true;
            start = 2;
          } else if (body[0] == 0xFE && body[1] == 0xFF) {
            littleEndian = false;
            start = 2;
          }
        }
        final codeUnits = <int>[];
        for (int i = start; i + 1 < body.length; i += 2) {
          final unit = littleEndian
              ? (body[i] | (body[i + 1] << 8))
              : ((body[i] << 8) | body[i + 1]);
          if (unit == 0) break;
          codeUnits.add(unit);
        }
        return String.fromCharCodes(codeUnits).trim();
      }
    } catch (_) {}
    return '';
  }

  static Uint8List? _extractImageBytes(Uint8List payload) {
    final limit = min(payload.length - 4, 256);
    for (int i = 1; i < limit; i++) {
      if (payload[i] == 0xFF && payload[i + 1] == 0xD8 && payload[i + 2] == 0xFF) {
        return payload.sublist(i);
      }
      if (payload[i] == 0x89 &&
          payload[i + 1] == 0x50 &&
          payload[i + 2] == 0x4E &&
          payload[i + 3] == 0x47) {
        return payload.sublist(i);
      }
    }
    return null;
  }
}

// --- Aplicacion Principal ---

class RelaxPlayerApp extends StatefulWidget {
  const RelaxPlayerApp({super.key});

  @override
  State<RelaxPlayerApp> createState() => _RelaxPlayerAppState();
}

class _RelaxPlayerAppState extends State<RelaxPlayerApp> {
  bool _darkMode = true;
  String _accentName = 'Morado';

  @override
  void initState() {
    super.initState();
    _loadThemePrefs();
  }

  Future<void> _loadThemePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _darkMode = prefs.getBool('dark_mode') ?? true;
      _accentName = prefs.getString('accent') ?? 'Morado';
    });
  }

  void _updateTheme({bool? darkMode, String? accentName}) {
    setState(() {
      if (darkMode != null) _darkMode = darkMode;
      if (accentName != null) _accentName = accentName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = kAccentThemes[_accentName] ?? const Color(0xFF9B5DE5);
    final brightness = _darkMode ? Brightness.dark : Brightness.light;
    final bg = _darkMode ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F8);

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _darkMode ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness: _darkMode ? Brightness.light : Brightness.dark,
      ),
    );

    return MaterialApp(
      title: 'relaxPlayer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        fontFamily: 'Poppins',
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
          primary: accent,
        ),
      ),
      home: RelaxHomeScreen(
        darkMode: _darkMode,
        accentName: _accentName,
        onThemeChanged: _updateTheme,
      ),
    );
  }
}

class RelaxHomeScreen extends StatefulWidget {
  final bool darkMode;
  final String accentName;
  final void Function({bool? darkMode, String? accentName}) onThemeChanged;

  const RelaxHomeScreen({
    super.key,
    required this.darkMode,
    required this.accentName,
    required this.onThemeChanged,
  });

  @override
  State<RelaxHomeScreen> createState() => _RelaxHomeScreenState();
}

class _RelaxHomeScreenState extends State<RelaxHomeScreen>
    with TickerProviderStateMixin {
  AudioPlayer get _audioPlayer => _audioHandler.player;
  VideoPlayerController? _videoController;

  late final AnimationController _sheetController;
  late final AnimationController _vinylController;
  yt.YoutubeExplode _ytClient = yt.YoutubeExplode();
  final TextEditingController _musicSearchCtrl = TextEditingController();
  final TextEditingController _onlineSearchCtrl = TextEditingController();
  final TextEditingController _videoSearchCtrl = TextEditingController();
  final TextEditingController _pinCtrl = TextEditingController();
  final TextEditingController _newPinCtrl = TextEditingController();
  final ScrollController _lyricsScrollCtrl = ScrollController();

  List<MediaTrack> _allTracks = [];
  List<MediaTrack> _activeAudioQueue = [];
  List<MediaTrack> _activeVideoQueue = [];

  // Buscador de musica en linea + cache de streams
  List<MediaTrack> _onlineResults = [];
  List<String> _recentOnlineSearches = [];
  Map<String, MediaTrack> _savedOnlineTracks = {};
  final Map<String, List<yt.StreamInfo>> _streamCandidatesCache = {};
  final Map<String, int> _streamUrlExpMs = {};
  bool _searchingOnline = false;
  bool _loadingOnlineTrack = false;
  String? _onlineError;
  String? _lastOnlineDetail;
  int _playRequestToken = 0;

  MediaTrack? _currentTrack;
  bool _isPlaying = false;
  bool _scanning = false;
  bool _hasLogoAsset = false;
  Uri? _defaultLogoUri;
  String _cacheDir = '';
  String _docsDir = '';

  int _activeTab = 0; // 0: Musica, 1: Buscar, 2: Videos, 3: Privado, 4: Ajustes
  String _musicFilter = 'Todas';
  String _videoFilter = 'Todas';
  String _musicSort = 'recientes';
  String _videoSort = 'recientes';
  String _musicQuery = '';
  String _videoQuery = '';
  String _privateFilter = 'audio';
  bool _vaultUnlocked = false;

  bool _shuffle = false;
  bool _repeat = false;
  double _volume = 0.85;
  double _speed = 1.0;

  // Nuevas preferencias de personalizacion
  bool _chameleonMode = true;
  bool _vinylMode = false;
  bool _autoPauseDisconnect = true;
  int _crossfadeSeconds = 4;
  Color? _dynamicAccent;

  // Ecualizador y refuerzo de bajos
  bool _eqEnabled = false;
  String _eqPreset = 'Plano';
  double _loudnessBoost = 0.0; // 0.0 .. 0.50 (0 a +5 dB)
  List<double> _eqSavedGains = [];

  // Edicion personalizada de canciones y letras
  Map<String, Map<String, String>> _trackOverrides = {};
  Map<String, String> _customLyrics = {};
  bool _showLyricsPanel = false;
  List<LyricLine> _currentLyrics = [];
  int _lastScrolledLyricIdx = -1;

  // Video pantalla completa y gestos
  bool _videoFullscreen = false;
  bool _videoControlsVisible = true;
  double _videoBrightness = 1.0; // 0.15 .. 1.0
  String? _videoHudLabel;
  IconData? _videoHudIcon;
  Timer? _videoHudTimer;
  Timer? _videoControlsTimer;
  double _videoTapDownX = 0.0;
  String _videoDragMode = '';

  // Estado guardado general
  String _pin = '1234';
  Set<String> _favorites = {};
  Set<String> _privatePaths = {};
  Map<String, List<String>> _playlists = {};
  int _totalPlays = 0;
  Map<String, int> _dailySeconds = {for (final d in kWeekDays) d: 0};
  Map<String, int> _trackPlayCounts = {};

  int _sleepRemainingSec = 0;
  Timer? _clockTimer;
  int _statsAccumSec = 0;
  double? _draggingSeekSec;

  StreamSubscription<bool>? _playingSub;
  final Random _rng = Random();

  Color get _bg => widget.darkMode ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F8);
  Color get _surface => widget.darkMode ? const Color(0xFF15151C) : const Color(0xFFFFFFFF);
  Color get _surfaceAlt => widget.darkMode ? const Color(0xFF1E1E28) : const Color(0xFFEAEAF0);
  Color get _text => widget.darkMode ? const Color(0xFFF6F6F9) : const Color(0xFF111118);
  Color get _subtext => widget.darkMode ? const Color(0xFF9E9EAA) : const Color(0xFF5D5D6B);
  Color get _border => widget.darkMode ? const Color(0xFF282836) : const Color(0xFFDCDCE6);
  Color get _accent => kAccentThemes[widget.accentName] ?? const Color(0xFF9B5DE5);
  Color get _playerAccent => (_chameleonMode && _dynamicAccent != null) ? _dynamicAccent! : _accent;

  double get _bottomScrollClearance {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return safeBottom + (_currentTrack != null ? 168.0 : 96.0);
  }

  @override
  void initState() {
    super.initState();
    _sheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _vinylController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
    _initEverything();
  }

  Future<void> _initEverything() async {
    final tmp = await getTemporaryDirectory();
    final docs = await getApplicationDocumentsDirectory();
    _cacheDir = tmp.path;
    _docsDir = docs.path;
    await _prepareLogoAsset();
    await _loadPrefs();
    _bindAudioStreams();
    _startClockTimer();
    await _loadCachedLibrary();
    // Escanear en segundo plano sin bloquear el arranque ni borrar la lista guardada
    unawaited(_scanDeviceMedia(showToast: false));
  }

  Future<void> _loadCachedLibrary() async {
    if (_docsDir.isEmpty) return;
    try {
      final cacheFile = File('$_docsDir/library_cache.json');
      if (await cacheFile.exists()) {
        final raw = await cacheFile.readAsString();
        final decoded = jsonDecode(raw) as List<dynamic>;
        final loaded = <MediaTrack>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final track = MediaTrack.fromJson(item);
            if (track.path.isNotEmpty) {
              _applyOverrideToTrack(track);
              loaded.add(track);
            }
          }
        }
        if (loaded.isNotEmpty && mounted) {
          setState(() => _allTracks = loaded);
        }
      }
    } catch (_) {}

    try {
      final onlineFile = File('$_docsDir/online_tracks.json');
      if (await onlineFile.exists()) {
        final raw = await onlineFile.readAsString();
        final decoded = jsonDecode(raw) as List<dynamic>;
        final loadedOnline = <String, MediaTrack>{};
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final track = MediaTrack.fromJson(item);
            if (track.path.isNotEmpty && track.isOnline) {
              _applyOverrideToTrack(track);
              loadedOnline[track.path] = track;
            }
          }
        }
        if (loadedOnline.isNotEmpty && mounted) {
          setState(() => _savedOnlineTracks = loadedOnline);
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCachedLibrary(List<MediaTrack> tracks) async {
    if (_docsDir.isEmpty) return;
    try {
      final cacheFile = File('$_docsDir/library_cache.json');
      final encoded = jsonEncode(tracks.map((t) => t.toJson()).toList());
      await cacheFile.writeAsString(encoded, flush: true);
    } catch (_) {}
  }

  Future<void> _saveOnlineTracksCache() async {
    if (_docsDir.isEmpty) return;
    try {
      final onlineFile = File('$_docsDir/online_tracks.json');
      final list = _savedOnlineTracks.values.toList();
      final encoded = jsonEncode(list.map((t) => t.toJson()).toList());
      await onlineFile.writeAsString(encoded, flush: true);
    } catch (_) {}
  }

  void _rememberOnlineTrack(MediaTrack track) {
    if (!track.isOnline) return;
    _savedOnlineTracks[track.path] = track;
    unawaited(_saveOnlineTracksCache());
  }

  Future<void> _prepareLogoAsset() async {
    try {
      final byteData = await rootBundle.load('assets/logo.png');
      final outFile = File('$_cacheDir/relaxplayer_logo.png');
      await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      if (mounted) {
        setState(() {
          _hasLogoAsset = true;
          _defaultLogoUri = Uri.file(outFile.path);
        });
      }
    } catch (_) {
      _hasLogoAsset = false;
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final favList = prefs.getStringList('favorites') ?? [];
    final recentOnline = prefs.getStringList('recent_online_searches') ?? [];
    final privList = prefs.getStringList('private_paths') ?? [];
    final plRaw = prefs.getString('playlists');
    final dailyRaw = prefs.getString('daily_seconds');
    final overridesRaw = prefs.getString('track_overrides');
    final lyricsRaw = prefs.getString('custom_lyrics');
    final eqGainsRaw = prefs.getString('eq_gains');
    final countsRaw = prefs.getString('track_play_counts');

    Map<String, List<String>> parsedPl = {};
    if (plRaw != null) {
      try {
        final decoded = jsonDecode(plRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          parsedPl[entry.key] = List<String>.from(entry.value as List);
        }
      } catch (_) {}
    }

    Map<String, int> parsedDaily = {for (final d in kWeekDays) d: 0};
    if (dailyRaw != null) {
      try {
        final decoded = jsonDecode(dailyRaw) as Map<String, dynamic>;
        for (final d in kWeekDays) {
          parsedDaily[d] = (decoded[d] as num?)?.toInt() ?? 0;
        }
      } catch (_) {}
    }

    Map<String, Map<String, String>> parsedOverrides = {};
    if (overridesRaw != null) {
      try {
        final decoded = jsonDecode(overridesRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final map = Map<String, dynamic>.from(entry.value as Map);
          parsedOverrides[entry.key] = map.map((k, v) => MapEntry(k, v.toString()));
        }
      } catch (_) {}
    }

    Map<String, String> parsedLyrics = {};
    if (lyricsRaw != null) {
      try {
        final decoded = jsonDecode(lyricsRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          parsedLyrics[entry.key] = entry.value.toString();
        }
      } catch (_) {}
    }

    List<double> parsedEqGains = [];
    if (eqGainsRaw != null) {
      try {
        final decoded = jsonDecode(eqGainsRaw) as List<dynamic>;
        parsedEqGains = decoded.map((e) => (e as num).toDouble()).toList();
      } catch (_) {}
    }

    Map<String, int> parsedPlayCounts = {};
    if (countsRaw != null) {
      try {
        final decoded = jsonDecode(countsRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final v = (entry.value as num?)?.toInt() ?? 0;
          if (v > 0) parsedPlayCounts[entry.key] = v;
        }
      } catch (_) {}
    }

    final autoPause = prefs.getBool('auto_pause_disconnect') ?? true;
    final crossfade = prefs.getInt('crossfade_seconds') ?? 4;
    _audioHandler.autoPauseOnDisconnect = autoPause;
    _audioHandler.crossfadeSeconds = crossfade;

    if (!mounted) return;
    setState(() {
      _pin = prefs.getString('pin') ?? '1234';
      _volume = prefs.getDouble('volume') ?? 0.85;
      _chameleonMode = prefs.getBool('chameleon_mode') ?? true;
      _vinylMode = prefs.getBool('vinyl_mode') ?? false;
      _autoPauseDisconnect = autoPause;
      _crossfadeSeconds = crossfade;
      _eqEnabled = prefs.getBool('eq_enabled') ?? false;
      _eqPreset = prefs.getString('eq_preset') ?? 'Plano';
      _loudnessBoost = prefs.getDouble('loudness_boost') ?? 0.0;
      _eqSavedGains = parsedEqGains;
      _favorites = favList.toSet();
      _privatePaths = privList.toSet();
      _playlists = parsedPl;
      _totalPlays = prefs.getInt('total_plays') ?? 0;
      _dailySeconds = parsedDaily;
      _trackPlayCounts = parsedPlayCounts;
      _trackOverrides = parsedOverrides;
      _customLyrics = parsedLyrics;
      _recentOnlineSearches = recentOnline;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', widget.darkMode);
    await prefs.setString('accent', widget.accentName);
    await prefs.setString('pin', _pin);
    await prefs.setDouble('volume', _volume);
    await prefs.setBool('chameleon_mode', _chameleonMode);
    await prefs.setBool('vinyl_mode', _vinylMode);
    await prefs.setBool('auto_pause_disconnect', _autoPauseDisconnect);
    await prefs.setInt('crossfade_seconds', _crossfadeSeconds);
    await prefs.setBool('eq_enabled', _eqEnabled);
    await prefs.setString('eq_preset', _eqPreset);
    await prefs.setDouble('loudness_boost', _loudnessBoost);
    await prefs.setString('eq_gains', jsonEncode(_eqSavedGains));
    await prefs.setStringList('favorites', _favorites.toList());
    await prefs.setStringList('private_paths', _privatePaths.toList());
    await prefs.setString('playlists', jsonEncode(_playlists));
    await prefs.setInt('total_plays', _totalPlays);
    await prefs.setString('daily_seconds', jsonEncode(_dailySeconds));
    await prefs.setString('track_play_counts', jsonEncode(_trackPlayCounts));
    await prefs.setString('track_overrides', jsonEncode(_trackOverrides));
    await prefs.setString('custom_lyrics', jsonEncode(_customLyrics));
    await prefs.setStringList('recent_online_searches', _recentOnlineSearches);
  }

  Future<void> _applySavedEqualizer() async {
    await _audioHandler.applyEqualizerToBoth(
      enabled: _eqEnabled,
      loudnessGain: _loudnessBoost,
      bandGains: _eqSavedGains,
    );
  }

  void _syncVinylAnimation() {
    final shouldSpin = _vinylMode && _isPlaying && _currentTrack != null && !_currentTrack!.isVideo;
    if (shouldSpin) {
      if (!_vinylController.isAnimating) {
        _vinylController.repeat();
      }
    } else {
      if (_vinylController.isAnimating) {
        _vinylController.stop();
      }
    }
  }

  void _bindAudioStreams() {
    _audioHandler.onSkipNext = () async {
      await _nextTrack();
    };
    _audioHandler.onSkipPrevious = () async {
      await _prevTrack();
    };
    _audioHandler.onTrackCompleted = () async {
      await _nextTrack();
    };
    _audioHandler.onCrossfadeTrigger = () async {
      await _nextTrack(useCrossfade: true);
    };
    _audioHandler.onPreloadNext = () async {
      await _preloadNextOnlineTrack();
    };
    _audioHandler.onHeadphonesDisconnected = () async {
      bool pausedAny = false;
      if (_currentTrack?.isVideo == true && _videoController?.value.isPlaying == true) {
        await _videoController?.pause();
        pausedAny = true;
      } else if (_isPlaying) {
        pausedAny = true;
      }
      if (mounted && pausedAny) {
        setState(() => _isPlaying = false);
        _syncVinylAnimation();
        _showSnack('Pausado al desconectar audífonos.');
      }
    };

    _playingSub = _audioHandler.unifiedPlayingStream.listen((playing) {
      if (!mounted) return;
      if (_currentTrack != null && !_currentTrack!.isVideo) {
        if (_isPlaying != playing) {
          setState(() => _isPlaying = playing);
          _syncVinylAnimation();
        }
      }
    });
  }

  void _startClockTimer() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_isPlaying && _currentTrack != null) {
        _statsAccumSec++;
        if (_statsAccumSec >= 10) {
          final dayName = kWeekDays[(DateTime.now().weekday - 1).clamp(0, 6)];
          _dailySeconds[dayName] = (_dailySeconds[dayName] ?? 0) + 10;
          _statsAccumSec = 0;
          _savePrefs();
        }
      }
      if (_sleepRemainingSec > 0) {
        setState(() => _sleepRemainingSec--);
        if (_sleepRemainingSec == 0 && _isPlaying) {
          _pauseActivePlayback();
          _showSnack('Temporizador finalizado.');
        }
      }
    });
  }

  @override
  void dispose() {
    _exitVideoFullscreen(restoreState: false);
    _clockTimer?.cancel();
    _videoHudTimer?.cancel();
    _videoControlsTimer?.cancel();
    _playingSub?.cancel();
    _audioHandler.onSkipNext = null;
    _audioHandler.onSkipPrevious = null;
    _audioHandler.onTrackCompleted = null;
    _audioHandler.onCrossfadeTrigger = null;
    _audioHandler.onPreloadNext = null;
    _audioHandler.onHeadphonesDisconnected = null;
    _ytClient.close();
    _videoController?.dispose();
    _sheetController.dispose();
    _vinylController.dispose();
    _lyricsScrollCtrl.dispose();
    _musicSearchCtrl.dispose();
    _onlineSearchCtrl.dispose();
    _videoSearchCtrl.dispose();
    _pinCtrl.dispose();
    _newPinCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Poppins', fontSize: 13)),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, _currentTrack != null ? 156 : 92),
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  // --- Aplicar ediciones guardadas por el usuario ---

  void _applyOverrideToTrack(MediaTrack t) {
    final ov = _trackOverrides[t.path];
    if (ov == null) return;
    if ((ov['title'] ?? '').isNotEmpty) t.title = ov['title']!;
    if ((ov['artist'] ?? '').isNotEmpty) t.artist = ov['artist']!;
    final cp = ov['coverPath'] ?? '';
    if (cp.isNotEmpty && File(cp).existsSync()) {
      t.coverPath = cp;
    }
  }

  Future<void> _refreshDynamicColorFor(MediaTrack track) async {
    if (!_chameleonMode || track.isVideo) {
      if (mounted && _dynamicAccent != null) {
        setState(() => _dynamicAccent = null);
      }
      return;
    }
    final cp = track.coverPath;
    if (cp == null || !File(cp).existsSync()) {
      if (mounted && _dynamicAccent != null) {
        setState(() => _dynamicAccent = null);
      }
      return;
    }
    final extracted = await CoverColorExtractor.extractDominant(cp);
    if (mounted && _currentTrack?.path == track.path) {
      setState(() => _dynamicAccent = extracted);
    }
  }

  Future<void> _loadLyricsForTrack(MediaTrack track) async {
    String raw = _customLyrics[track.path] ?? '';
    if (raw.isEmpty) {
      try {
        final lrcFile = File('${pathWithoutExtension(track.path)}.lrc');
        if (await lrcFile.exists()) {
          raw = await lrcFile.readAsString();
        }
      } catch (_) {}
    }
    final parsed = raw.trim().isEmpty ? <LyricLine>[] : LyricsParser.parse(raw);
    if (mounted && _currentTrack?.path == track.path) {
      setState(() {
        _currentLyrics = parsed;
        _lastScrolledLyricIdx = -1;
      });
    }
  }

  // --- Buscador y streaming de musica en linea (YouTube Audio con respaldo local) ---

  String? _findCachedOnlineAudioFile(String videoId) {
    if (_cacheDir.isEmpty) return null;
    for (final ext in ['m4a', 'webm', 'mp4']) {
      final f = File('$_cacheDir/yt_audio_$videoId.$ext');
      if (f.existsSync() && f.lengthSync() > 4096) {
        return f.path;
      }
    }
    return null;
  }

  Future<void> _pruneOnlineAudioCache() async {
    if (_cacheDir.isEmpty) return;
    try {
      final dir = Directory(_cacheDir);
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('yt_audio_') && !f.path.endsWith('.part'))
          .toList();
      if (files.length <= 12) return;
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (int i = 0; i < files.length - 12; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<List<yt.StreamInfo>> _resolveOnlineCandidates(MediaTrack track) async {
    final vid = track.onlineVideoId;
    if (vid == null || vid.isEmpty) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _streamCandidatesCache[vid];
    final exp = _streamUrlExpMs[vid] ?? 0;
    if (cached != null && cached.isNotEmpty && now < exp) {
      return cached;
    }

    yt.StreamManifest? manifest;
    Object? lastErr;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        manifest = await _ytClient.videos.streamsClient
            .getManifest(vid)
            .timeout(const Duration(seconds: 22));
        break;
      } catch (e) {
        lastErr = e;
        if (attempt == 0) {
          try {
            _ytClient.close();
          } catch (_) {}
          _ytClient = yt.YoutubeExplode();
        }
      }
    }

    if (manifest == null) {
      _lastOnlineDetail = 'manifest: ${lastErr.toString()}';
      return [];
    }

    final candidates = <yt.StreamInfo>[];
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isNotEmpty) {
      // Ordenar por bitrate medio-alto primero (arranca rapido en datos moviles)
      audioStreams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final mp4s = audioStreams
          .where((s) => s.container.name.toLowerCase() == 'mp4')
          .toList();
      final webms = audioStreams
          .where((s) => s.container.name.toLowerCase() != 'mp4')
          .toList();
      if (mp4s.isNotEmpty) candidates.add(mp4s.first);
      if (webms.isNotEmpty) candidates.add(webms.first);
      if (mp4s.length > 1) candidates.add(mp4s.last);
    }

    if (manifest.muxed.isNotEmpty) {
      final muxed = manifest.muxed.toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      candidates.add(muxed.first);
    }

    if (candidates.isNotEmpty) {
      _streamCandidatesCache[vid] = candidates;
      _streamUrlExpMs[vid] = now + (60 * 60 * 1000);
    }
    return candidates;
  }

  Future<String?> _downloadOnlineStreamToCache(String videoId, yt.StreamInfo streamInfo) async {
    if (_cacheDir.isEmpty) return null;
    final container = streamInfo.container.name.toLowerCase();
    final ext = container == 'mp4' ? 'm4a' : (container == 'webm' ? 'webm' : 'mp4');
    final finalPath = '$_cacheDir/yt_audio_$videoId.$ext';
    final existing = File(finalPath);
    if (await existing.exists() && await existing.length() > 4096) {
      return finalPath;
    }

    final partFile = File('$finalPath.part');
    IOSink? sink;
    try {
      sink = partFile.openWrite();
      int totalBytes = 0;
      final stream = _ytClient.videos.streamsClient.get(streamInfo);
      await for (final chunk in stream.timeout(const Duration(seconds: 15))) {
        sink.add(chunk);
        totalBytes += chunk.length;
        if (totalBytes > 28 * 1024 * 1024) {
          throw Exception('Archivo demasiado grande para caché temporal');
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (totalBytes < 4096) {
        if (await partFile.exists()) await partFile.delete();
        return null;
      }
      if (await existing.exists()) await existing.delete();
      await partFile.rename(finalPath);
      unawaited(_pruneOnlineAudioCache());
      return finalPath;
    } catch (e) {
      _lastOnlineDetail = 'cache_dl: ${e.toString()}';
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _downloadRemoteThumb(MediaTrack track) async {
    if (!track.isOnline) return;
    if (track.coverPath != null && File(track.coverPath!).existsSync()) return;
    final url = track.remoteArtUrl;
    final vid = track.onlineVideoId;
    if (url == null || url.isEmpty || vid == null || _cacheDir.isEmpty) return;

    final outFile = File('$_cacheDir/yt_thumb_$vid.jpg');
    if (await outFile.exists()) {
      track.coverPath = outFile.path;
      _rememberOnlineTrack(track);
      if (mounted && _currentTrack?.path == track.path) {
        setState(() {});
        unawaited(_refreshDynamicColorFor(track));
      }
      return;
    }

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final bytes = <int>[];
        await for (final chunk in resp) {
          bytes.addAll(chunk);
        }
        if (bytes.length > 100) {
          await outFile.writeAsBytes(bytes, flush: true);
          track.coverPath = outFile.path;
          _rememberOnlineTrack(track);
          if (mounted && _currentTrack?.path == track.path) {
            setState(() {});
            _audioHandler.updateCurrentMetadata(
              track.path,
              artUri: Uri.file(outFile.path),
            );
            unawaited(_refreshDynamicColorFor(track));
          }
        }
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _preloadNextOnlineTrack() async {
    if (_currentTrack == null || _currentTrack!.isVideo || _activeAudioQueue.length < 2) {
      return;
    }
    if (_shuffle) return;
    final curIdx = _activeAudioQueue.indexWhere((t) => t.path == _currentTrack!.path);
    if (curIdx < 0) return;
    final nextTrack = _activeAudioQueue[(curIdx + 1) % _activeAudioQueue.length];
    if (nextTrack.isOnline) {
      unawaited(_resolveOnlineCandidates(nextTrack));
      unawaited(_downloadRemoteThumb(nextTrack));
    }
  }

  Future<void> _searchOnlineMusic(String rawQuery) async {
    final q = rawQuery.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searchingOnline = true;
      _onlineError = null;
      _recentOnlineSearches.removeWhere((s) => s.toLowerCase() == q.toLowerCase());
      _recentOnlineSearches.insert(0, q);
      if (_recentOnlineSearches.length > 8) {
        _recentOnlineSearches = _recentOnlineSearches.sublist(0, 8);
      }
    });
    unawaited(_savePrefs());

    try {
      final searchList = await _ytClient.search
          .search(q)
          .timeout(const Duration(seconds: 15));
      final items = <MediaTrack>[];
      for (final v in searchList) {
        if (v.isLive) continue;
        final vid = v.id.value;
        final trackPath = 'yt://$vid';
        final existing = _savedOnlineTracks[trackPath];
        final thumbUrl = v.thumbnails.highResUrl.isNotEmpty
            ? v.thumbnails.highResUrl
            : v.thumbnails.mediumResUrl;
        final track = MediaTrack(
          path: trackPath,
          title: existing?.title ?? v.title,
          artist: existing?.artist ?? v.author,
          folder: 'En línea',
          ext: 'ONLINE',
          isVideo: false,
          modifiedMs: DateTime.now().millisecondsSinceEpoch,
          coverPath: existing?.coverPath,
          metadataLoaded: true,
          isOnline: true,
          onlineVideoId: vid,
          remoteArtUrl: thumbUrl,
          durationMs: v.duration?.inMilliseconds,
        );
        _applyOverrideToTrack(track);
        items.add(track);
        if (items.length >= 25) break;
      }
      if (!mounted) return;
      setState(() {
        _onlineResults = items;
        _searchingOnline = false;
        if (items.isEmpty) {
          _onlineError = 'No encontré resultados para "$q".';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchingOnline = false;
        _onlineError = 'Sin conexión o no se pudo buscar ahora. Intenta de nuevo.';
      });
    }
  }

  // --- Permisos y escaneo automatico ---

  Future<void> _requestAndroidPermissions({bool promptIfMissing = true}) async {
    if (!Platform.isAndroid) return;
    for (final perm in [
      Permission.notification,
      Permission.audio,
      Permission.videos,
      Permission.storage,
    ]) {
      try {
        final st = await perm.status;
        if (!st.isGranted && promptIfMissing) {
          await perm.request();
        }
      } catch (_) {}
    }
  }

  Future<void> _scanDeviceMedia({bool showToast = true}) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    if (showToast) _showSnack('Actualizando música y videos...');

    await _requestAndroidPermissions(promptIfMissing: showToast || _allTracks.isEmpty);

    List<MediaTrack> found = await _walkMediaDirectories();

    if (found.isEmpty && Platform.isAndroid) {
      final manageStatus = await Permission.manageExternalStorage.status;
      if (!manageStatus.isGranted && (showToast || _allTracks.isEmpty)) {
        await Permission.manageExternalStorage.request();
        found = await _walkMediaDirectories();
      }
    }

    // Preservar metadatos ya leidos de la cache para no perder portadas/titulos
    final prevByPath = {for (final t in _allTracks) t.path: t};
    for (final t in found) {
      final prev = prevByPath[t.path];
      if (prev != null) {
        if (prev.metadataLoaded) {
          t.title = prev.title;
          t.artist = prev.artist;
          t.coverPath = prev.coverPath;
          t.metadataLoaded = true;
        }
      }
      _applyOverrideToTrack(t);
    }

    if (!mounted) return;
    // Si es un escaneo silencioso al arrancar y devolvio vacio pero ya tenemos cache, no borrar la lista
    if (found.isNotEmpty || showToast) {
      setState(() {
        _allTracks = found;
        _scanning = false;
      });
      unawaited(_saveCachedLibrary(found));
    } else {
      setState(() => _scanning = false);
    }

    if (showToast) {
      final nMus = _getList(isVideo: false, onlyPrivate: false).length;
      final nVid = _getList(isVideo: true, onlyPrivate: false).length;
      _showSnack('Listo: $nMus canciones y $nVid videos.');
    }
  }

  Future<List<MediaTrack>> _walkMediaDirectories() async {
    final roots = <String>[];
    if (Platform.isAndroid) {
      const candidates = [
        '/storage/emulated/0/Music',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0/Snaptube',
        '/storage/emulated/0/Audio',
        '/storage/emulated/0/Podcasts',
        '/storage/emulated/0/Recordings',
        '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio',
        '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video',
        '/storage/emulated/0',
      ];
      for (final c in candidates) {
        if (Directory(c).existsSync() && !roots.contains(c)) {
          roots.add(c);
        }
      }
      try {
        final storageDir = Directory('/storage');
        if (storageDir.existsSync()) {
          for (final ent in storageDir.listSync()) {
            if (ent is Directory) {
              final name = ent.path.split('/').last;
              if (name != 'emulated' && name != 'self' && !roots.contains(ent.path)) {
                roots.add(ent.path);
              }
            }
          }
        }
      } catch (_) {}
    }

    final seen = <String>{};
    final tracks = <MediaTrack>[];

    Future<void> walkDir(Directory dir, int depth) async {
      if (depth > 6) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name.startsWith('.') || kIgnoredDirs.contains(name.toLowerCase())) {
              continue;
            }
            await walkDir(entity, depth + 1);
          } else if (entity is File) {
            final name = entity.path.split('/').last;
            if (name.startsWith('.')) continue;
            final ext = fileExtension(entity.path);
            final isAudio = kAudioExts.contains(ext);
            final isVideo = kVideoExts.contains(ext);
            if (!isAudio && !isVideo) continue;

            final key = entity.path.toLowerCase();
            if (seen.contains(key)) continue;
            seen.add(key);

            int modMs = 0;
            try {
              modMs = (await entity.stat()).modified.millisecondsSinceEpoch;
            } catch (_) {}

            final folder = parentFolderName(entity.path);
            tracks.add(
              MediaTrack(
                path: entity.path,
                title: fileBaseName(entity.path),
                artist: folder,
                folder: folder,
                ext: ext.substring(1).toUpperCase(),
                isVideo: isVideo,
                modifiedMs: modMs,
              ),
            );
          }
        }
      } catch (_) {}
    }

    for (final r in roots) {
      await walkDir(Directory(r), 0);
    }

    return tracks;
  }

  List<MediaTrack> _getList({required bool isVideo, required bool onlyPrivate}) {
    return _allTracks.where((t) {
      if (t.isVideo != isVideo) return false;
      final isPriv = _privatePaths.contains(t.path);
      return onlyPrivate ? isPriv : !isPriv;
    }).toList();
  }

  List<MediaTrack> _sortList(List<MediaTrack> list, String sortMode) {
    final copy = List<MediaTrack>.from(list);
    if (sortMode == 'recientes') {
      copy.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    } else if (sortMode == 'carpeta') {
      copy.sort((a, b) {
        final fc = a.folder.toLowerCase().compareTo(b.folder.toLowerCase());
        return fc != 0 ? fc : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    } else {
      copy.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return copy;
  }

  List<MediaTrack> _getCombinedAudioPool() {
    final local = _getList(isVideo: false, onlyPrivate: false);
    final seen = {for (final t in local) t.path};
    final combined = List<MediaTrack>.from(local);
    for (final t in _savedOnlineTracks.values) {
      if (!seen.contains(t.path) && !_privatePaths.contains(t.path)) {
        combined.add(t);
      }
    }
    return combined;
  }

  List<MediaTrack> _getTopTracks({int limit = 25}) {
    final music = _getCombinedAudioPool()
        .where((t) => (_trackPlayCounts[t.path] ?? 0) > 0)
        .toList();
    music.sort((a, b) {
      final ca = _trackPlayCounts[a.path] ?? 0;
      final cb = _trackPlayCounts[b.path] ?? 0;
      if (cb != ca) return cb.compareTo(ca);
      return b.modifiedMs.compareTo(a.modifiedMs);
    });
    return music.length > limit ? music.sublist(0, limit) : music;
  }

  List<MediaTrack> _filteredList(bool isVideo) {
    final filter = isVideo ? _videoFilter : _musicFilter;
    final query = (isVideo ? _videoQuery : _musicQuery).trim().toLowerCase();
    final sort = isVideo ? _videoSort : _musicSort;

    if (!isVideo && filter == 'Top') {
      var top = _getTopTracks(limit: 25);
      if (query.isNotEmpty) {
        top = top
            .where((t) =>
                t.title.toLowerCase().contains(query) ||
                t.artist.toLowerCase().contains(query))
            .toList();
      }
      return top;
    }

    List<MediaTrack> base;
    if (!isVideo && filter.startsWith('PL::')) {
      final plName = filter.substring(4);
      final paths = _playlists[plName] ?? [];
      final byPath = {for (final t in _getCombinedAudioPool()) t.path: t};
      base = [for (final p in paths) if (byPath.containsKey(p)) byPath[p]!];
    } else if (!isVideo && filter == 'Favoritos') {
      base = _getCombinedAudioPool()
          .where((t) => _favorites.contains(t.path))
          .toList();
    } else {
      base = _getList(isVideo: isVideo, onlyPrivate: false).where((t) {
        if (filter == 'Favoritos') return _favorites.contains(t.path);
        if (filter != 'Todas') return t.folder == filter;
        return true;
      }).toList();
    }

    if (query.isNotEmpty) {
      base = base
          .where((t) =>
              t.title.toLowerCase().contains(query) ||
              t.artist.toLowerCase().contains(query))
          .toList();
    }
    return _sortList(base, sort);
  }

  // --- Reproduccion de audio y video ---

  Future<void> _playTrack(
    MediaTrack track,
    List<MediaTrack> queue, {
    bool openSheet = true,
    bool useCrossfade = false,
  }) async {
    _totalPlays++;
    if (!track.isVideo) {
      _trackPlayCounts[track.path] = (_trackPlayCounts[track.path] ?? 0) + 1;
    }
    _savePrefs();

    if (track.isVideo) {
      await _audioHandler.pause();
      await _disposeVideo();
      _activeVideoQueue = List<MediaTrack>.from(queue.isEmpty ? [track] : queue);
      setState(() {
        _currentTrack = track;
        _isPlaying = true;
        _dynamicAccent = null;
        _showLyricsPanel = false;
        _videoControlsVisible = true;
      });
      _syncVinylAnimation();
      if (openSheet) _openPlayerSheet();

      final ctrl = VideoPlayerController.file(File(track.path));
      _videoController = ctrl;
      try {
        await ctrl.initialize();
        await ctrl.setVolume(_volume);
        await ctrl.play();
        ctrl.addListener(() {
          if (!mounted) return;
          final val = ctrl.value;
          if (val.isInitialized &&
              val.duration > Duration.zero &&
              val.position >= val.duration - const Duration(milliseconds: 250)) {
            _nextTrack();
          } else if (_isPlaying != val.isPlaying) {
            setState(() => _isPlaying = val.isPlaying);
          }
        });
        if (mounted) setState(() => _isPlaying = true);
      } catch (_) {
        _showSnack('No se pudo abrir este video.');
      }
      return;
    }

    await _exitVideoFullscreen();
    await _disposeVideo();
    final reqToken = ++_playRequestToken;

    if (track.isOnline) {
      _rememberOnlineTrack(track);
      _applyOverrideToTrack(track);
      unawaited(_downloadRemoteThumb(track));
    } else {
      final hadMeta = track.metadataLoaded;
      await Id3Reader.loadTrackMetadata(track, _cacheDir);
      _applyOverrideToTrack(track);
      if (!hadMeta && track.metadataLoaded && _allTracks.isNotEmpty) {
        unawaited(_saveCachedLibrary(_allTracks));
      }
    }

    final validQueue = queue.isEmpty ? [track] : List<MediaTrack>.from(queue);
    _activeAudioQueue = validQueue;
    final curIdx = max(0, validQueue.indexWhere((t) => t.path == track.path));

    if (mounted) {
      setState(() {
        _currentTrack = track;
        _loadingOnlineTrack = track.isOnline;
        _isPlaying = !track.isOnline;
        _draggingSeekSec = null;
        _lastScrolledLyricIdx = -1;
      });
    }
    _syncVinylAnimation();
    unawaited(_refreshDynamicColorFor(track));
    unawaited(_loadLyricsForTrack(track));
    if (openSheet) _openPlayerSheet();

    String? cachedLocalFile;
    List<yt.StreamInfo> onlineCandidates = [];
    if (track.isOnline) {
      final vid = track.onlineVideoId ?? '';
      cachedLocalFile = _findCachedOnlineAudioFile(vid);
      if (cachedLocalFile == null) {
        onlineCandidates = await _resolveOnlineCandidates(track);
        if (reqToken != _playRequestToken) return;
        if (onlineCandidates.isEmpty) {
          if (mounted) {
            setState(() {
              _loadingOnlineTrack = false;
              _isPlaying = false;
            });
            _syncVinylAnimation();
            _showSnack('No se encontró un enlace de audio disponible para esta canción.');
          }
          return;
        }
      }
    }

    Uri? resolveArt(MediaTrack t) {
      if (t.coverPath != null && File(t.coverPath!).existsSync()) {
        return Uri.file(t.coverPath!);
      }
      if (t.remoteArtUrl != null && t.remoteArtUrl!.isNotEmpty) {
        return Uri.tryParse(t.remoteArtUrl!) ?? _defaultLogoUri;
      }
      return _defaultLogoUri;
    }

    final Uri? art = resolveArt(track);
    final mediaQueue = validQueue.map((t) {
      return MediaItem(
        id: t.path,
        title: t.title,
        artist: t.artist,
        album: t.folder,
        artUri: resolveArt(t),
      );
    }).toList();

    try {
      if (!track.isOnline || cachedLocalFile != null) {
        await _audioHandler.playMediaTrack(
          path: track.path,
          localFilePath: cachedLocalFile,
          title: track.title,
          artist: track.artist,
          album: track.folder,
          artUri: art,
          queueItems: mediaQueue,
          queueIndex: curIdx,
          volume: _volume,
          speed: _speed,
          repeatOne: _repeat,
          useCrossfade: useCrossfade,
        );
      } else {
        // Intento 1: streaming directo HTTPS probando varios formatos + headers
        bool started = false;
        Object? streamErr;
        try {
          await _audioHandler.playMediaTrack(
            path: track.path,
            sourceUrls: onlineCandidates.map((s) => s.url.toString()).toList(),
            title: track.title,
            artist: track.artist,
            album: track.folder,
            artUri: art,
            queueItems: mediaQueue,
            queueIndex: curIdx,
            volume: _volume,
            speed: _speed,
            repeatOne: _repeat,
            useCrossfade: useCrossfade,
          );
          started = true;
        } catch (e) {
          streamErr = e;
          _lastOnlineDetail = 'stream: ${e.toString()}';
        }

        // Intento 2 (Respaldo contra bloqueo 403 de YouTube en ExoPlayer):
        // Descargar el audio temporalmente con el motor de bloques de youtube_explode y reproducirlo local
        if (!started) {
          if (reqToken != _playRequestToken) return;
          final vid = track.onlineVideoId ?? '';
          String? downloaded;
          for (final cand in onlineCandidates.take(2)) {
            downloaded = await _downloadOnlineStreamToCache(vid, cand);
            if (reqToken != _playRequestToken) return;
            if (downloaded != null) break;
          }
          if (downloaded == null) {
            throw streamErr ?? Exception('No se pudo obtener el audio');
          }
          await _audioHandler.playMediaTrack(
            path: track.path,
            localFilePath: downloaded,
            title: track.title,
            artist: track.artist,
            album: track.folder,
            artUri: art,
            queueItems: mediaQueue,
            queueIndex: curIdx,
            volume: _volume,
            speed: _speed,
            repeatOne: _repeat,
            useCrossfade: useCrossfade,
          );
        }
      }

      if (mounted && reqToken == _playRequestToken) {
        setState(() {
          _loadingOnlineTrack = false;
          _isPlaying = true;
          _lastOnlineDetail = null;
        });
        _syncVinylAnimation();
      }
      unawaited(_applySavedEqualizer());
    } catch (e) {
      if (track.isOnline && track.onlineVideoId != null) {
        _streamCandidatesCache.remove(track.onlineVideoId);
      }
      _lastOnlineDetail = e.toString();
      if (mounted && reqToken == _playRequestToken) {
        setState(() {
          _loadingOnlineTrack = false;
          _isPlaying = false;
        });
        _syncVinylAnimation();
        final shortReason = _lastOnlineDetail!.replaceAll('
', ' ');
        _showSnack(
          track.isOnline
              ? 'No se pudo reproducir (${shortReason.length > 55 ? shortReason.substring(0, 55) : shortReason})'
              : 'No se pudo reproducir este archivo.',
        );
      }
    }
  }

  Future<void> _disposeVideo() async {
    final old = _videoController;
    _videoController = null;
    if (old != null) {
      await old.pause();
      await old.dispose();
    }
  }

  Future<void> _pauseActivePlayback() async {
    if (_currentTrack == null) return;
    if (_currentTrack!.isVideo) {
      await _videoController?.pause();
    } else {
      await _audioHandler.pause();
    }
    if (mounted) {
      setState(() => _isPlaying = false);
      _syncVinylAnimation();
    }
  }

  Future<void> _togglePlayPause() async {
    if (_currentTrack == null) {
      final list = _filteredList(_activeTab == 2);
      if (list.isNotEmpty) {
        await _playTrack(list.first, list, openSheet: true);
      }
      return;
    }
    if (_currentTrack!.isVideo) {
      final vc = _videoController;
      if (vc == null || !vc.value.isInitialized) return;
      if (vc.value.isPlaying) {
        await vc.pause();
      } else {
        await vc.play();
      }
      setState(() => _isPlaying = vc.value.isPlaying);
    } else {
      if (_audioPlayer.playing) {
        await _audioHandler.pause();
      } else {
        await _audioHandler.play();
      }
    }
  }

  Future<void> _nextTrack({bool useCrossfade = false}) async {
    if (_currentTrack == null) return;
    final keepSheet = _sheetController.value > 0.5;

    if (_currentTrack!.isVideo) {
      if (_activeVideoQueue.isEmpty) return;
      final idx = _activeVideoQueue.indexWhere((t) => t.path == _currentTrack!.path);
      final nextIdx = (idx + 1) % _activeVideoQueue.length;
      await _playTrack(_activeVideoQueue[nextIdx], _activeVideoQueue, openSheet: keepSheet);
      return;
    }

    if (_activeAudioQueue.isEmpty) return;
    final curIdx = _activeAudioQueue.indexWhere((t) => t.path == _currentTrack!.path);
    int nextIdx;
    if (_shuffle && _activeAudioQueue.length > 1) {
      do {
        nextIdx = _rng.nextInt(_activeAudioQueue.length);
      } while (nextIdx == curIdx);
    } else {
      nextIdx = (curIdx + 1) % _activeAudioQueue.length;
    }
    await _playTrack(
      _activeAudioQueue[nextIdx],
      _activeAudioQueue,
      openSheet: keepSheet,
      useCrossfade: useCrossfade,
    );
  }

  Future<void> _prevTrack() async {
    if (_currentTrack == null) return;
    final keepSheet = _sheetController.value > 0.5;

    if (_currentTrack!.isVideo) {
      if (_activeVideoQueue.isEmpty) return;
      final idx = _activeVideoQueue.indexWhere((t) => t.path == _currentTrack!.path);
      final prevIdx = (idx - 1 + _activeVideoQueue.length) % _activeVideoQueue.length;
      await _playTrack(_activeVideoQueue[prevIdx], _activeVideoQueue, openSheet: keepSheet);
      return;
    }

    if (_audioPlayer.position.inSeconds > 4) {
      await _audioHandler.seek(Duration.zero);
      return;
    }

    if (_activeAudioQueue.isEmpty) return;
    final curIdx = _activeAudioQueue.indexWhere((t) => t.path == _currentTrack!.path);
    final prevIdx = (curIdx - 1 + _activeAudioQueue.length) % _activeAudioQueue.length;
    await _playTrack(_activeAudioQueue[prevIdx], _activeAudioQueue, openSheet: keepSheet);
  }

  // --- Pantalla completa y gestos de video ---

  Future<void> _enterVideoFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (mounted) {
      setState(() {
        _videoFullscreen = true;
        _videoControlsVisible = true;
      });
      _scheduleHideVideoControls();
    }
  }

  Future<void> _exitVideoFullscreen({bool restoreState = true}) async {
    if (!_videoFullscreen && restoreState) return;
    _videoControlsTimer?.cancel();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    if (restoreState && mounted) {
      setState(() {
        _videoFullscreen = false;
        _videoControlsVisible = true;
      });
    }
  }

  void _scheduleHideVideoControls() {
    _videoControlsTimer?.cancel();
    if (!_videoFullscreen) return;
    _videoControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _videoFullscreen && _isPlaying) {
        setState(() => _videoControlsVisible = false);
      }
    });
  }

  void _showVideoHud(IconData icon, String label) {
    _videoHudTimer?.cancel();
    setState(() {
      _videoHudIcon = icon;
      _videoHudLabel = label;
    });
    _videoHudTimer = Timer(const Duration(milliseconds: 950), () {
      if (mounted) {
        setState(() {
          _videoHudIcon = null;
          _videoHudLabel = null;
        });
      }
    });
  }

  // --- Animacion fluida 60 FPS al subir y bajar ---

  void _openPlayerSheet() {
    if (_currentTrack == null) return;
    _sheetController.animateTo(1.0, curve: Curves.easeOutCubic);
  }

  void _closePlayerSheet() {
    if (_videoFullscreen) {
      _exitVideoFullscreen();
    }
    if (_currentTrack != null && _currentTrack!.isVideo) {
      _videoController?.pause();
      setState(() => _isPlaying = false);
    }
    _sheetController.animateBack(0.0, curve: Curves.easeInOutCubic);
  }

  // --- Cola "A continuacion" ---

  void _playNextInQueue(MediaTrack track) {
    if (track.isOnline) _rememberOnlineTrack(track);
    if (track.isVideo) {
      _playTrack(track, _filteredList(true), openSheet: true);
      return;
    }
    if (_currentTrack == null || _currentTrack!.isVideo || _activeAudioQueue.isEmpty) {
      _playTrack(track, [track], openSheet: true);
      return;
    }
    setState(() {
      _activeAudioQueue.removeWhere((t) => t.path == track.path);
      final curIdx = _activeAudioQueue.indexWhere((t) => t.path == _currentTrack!.path);
      final insertAt = (curIdx >= 0 ? curIdx + 1 : 0).clamp(0, _activeAudioQueue.length);
      _activeAudioQueue.insert(insertAt, track);
    });
    _showSnack('Sonará a continuación: ${track.title}');
  }

  void _appendToQueue(MediaTrack track) {
    if (track.isOnline) _rememberOnlineTrack(track);
    if (track.isVideo) return;
    if (_currentTrack == null || _currentTrack!.isVideo || _activeAudioQueue.isEmpty) {
      _playTrack(track, [track], openSheet: true);
      return;
    }
    setState(() {
      _activeAudioQueue.removeWhere((t) => t.path == track.path);
      _activeAudioQueue.add(track);
    });
    _showSnack('Agregada al final de la cola.');
  }

  Future<void> _showQueueBottomSheet() async {
    if (_activeAudioQueue.isEmpty) {
      _showSnack('La cola está vacía.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final dark = widget.darkMode;
            final acc = _playerAccent;
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  height: MediaQuery.of(ctx).size.height * 0.68,
                  decoration: BoxDecoration(
                    color: withA(_surface, dark ? 0.88 : 0.94),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    border: Border(
                      top: BorderSide(color: withA(Colors.white, dark ? 0.20 : 0.85), width: 1.2),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: withA(_text, 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('A continuación', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _text)),
                                Text('${_activeAudioQueue.length} canciones en cola (arrastra para ordenar)', style: TextStyle(fontSize: 11, color: _subtext)),
                              ],
                            ),
                            IconButton(
                              icon: Icon(Icons.close_rounded, color: _subtext),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: _border),
                      Expanded(
                        child: ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                          itemCount: _activeAudioQueue.length,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final item = _activeAudioQueue.removeAt(oldIndex);
                              _activeAudioQueue.insert(newIndex, item);
                            });
                            setSheetState(() {});
                          },
                          itemBuilder: (_, i) {
                            final t = _activeAudioQueue[i];
                            final isCurrent = _currentTrack?.path == t.path;
                            return Container(
                              key: ValueKey('${t.path}_$i'),
                              margin: const EdgeInsets.only(bottom: 6),
                              decoration: BoxDecoration(
                                color: isCurrent ? withA(acc, 0.18) : withA(_surfaceAlt, 0.72),
                                borderRadius: BorderRadius.circular(14),
                                border: isCurrent ? Border.all(color: withA(acc, 0.45)) : null,
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                leading: ReorderableDragStartListener(
                                  index: i,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      isCurrent ? Icons.graphic_eq_rounded : Icons.drag_handle_rounded,
                                      color: isCurrent ? acc : _subtext,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isCurrent ? acc : _text,
                                  ),
                                ),
                                subtitle: Text(
                                  t.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: _subtext),
                                ),
                                trailing: isCurrent
                                    ? null
                                    : IconButton(
                                        icon: Icon(Icons.close_rounded, size: 18, color: _subtext),
                                        onPressed: () {
                                          setState(() => _activeAudioQueue.removeAt(i));
                                          setSheetState(() {});
                                        },
                                      ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _playTrack(t, _activeAudioQueue, openSheet: true);
                                },
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
          },
        );
      },
    );
  }

  // --- Ecualizador real + Refuerzo de bajos ---

  Future<void> _showEqualizerSheet() async {
    AndroidEqualizerParameters? params;
    if (Platform.isAndroid) {
      try {
        params = await _audioHandler.equalizer.parameters;
      } catch (_) {
        params = null;
      }
    }

    if (!mounted) return;
    if (params == null) {
      _showSnack('Reproduce una canción primero para activar el ecualizador.');
      return;
    }

    final eqParams = params;
    final bandValues = List<double>.generate(
      eqParams.bands.length,
      (i) => eqParams.bands[i].gain.clamp(eqParams.minDecibels, eqParams.maxDecibels),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final dark = widget.darkMode;
            final acc = _playerAccent;

            Future<void> applyPreset(String presetName) async {
              final weights = kEqPresets[presetName] ?? [0.0, 0.0, 0.0, 0.0, 0.0];
              final span = min(eqParams.maxDecibels.abs(), eqParams.minDecibels.abs()) * 0.65;
              setState(() {
                _eqEnabled = true;
                _eqPreset = presetName;
              });
              setSheetState(() {});
              try {
                await _audioHandler.equalizer.setEnabled(true);
                for (int i = 0; i < eqParams.bands.length; i++) {
                  final w = i < weights.length ? weights[i] : weights.last;
                  final target = (w * span).clamp(eqParams.minDecibels, eqParams.maxDecibels);
                  bandValues[i] = target;
                  await eqParams.bands[i].setGain(target);
                }
                _eqSavedGains = List<double>.from(bandValues);
                if (presetName == 'Bass Boost') {
                  _loudnessBoost = 0.28;
                } else if (presetName == 'Urbano') {
                  _loudnessBoost = 0.20;
                } else if (presetName == 'Plano') {
                  _loudnessBoost = 0.0;
                }
                await _applySavedEqualizer();
                setSheetState(() {});
                _savePrefs();
              } catch (_) {}
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 26),
                  decoration: BoxDecoration(
                    color: withA(_surface, dark ? 0.90 : 0.95),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    border: Border(
                      top: BorderSide(color: withA(Colors.white, dark ? 0.20 : 0.85), width: 1.2),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: withA(_text, 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.equalizer_rounded, color: acc, size: 24),
                              const SizedBox(width: 8),
                              Text('Ecualizador', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _text)),
                            ],
                          ),
                          Switch(
                            value: _eqEnabled,
                            onChanged: (v) async {
                              setState(() => _eqEnabled = v);
                              setSheetState(() {});
                              await _applySavedEqualizer();
                              _savePrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Presets rapidos
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: kEqPresets.keys.map((preset) {
                            final selected = _eqEnabled && _eqPreset == preset;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () => applyPreset(preset),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: selected ? acc : _surfaceAlt,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    preset,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: selected ? Colors.white : _text,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Sliders verticales por banda de frecuencia
                      Opacity(
                        opacity: _eqEnabled ? 1.0 : 0.45,
                        child: SizedBox(
                          height: 180,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: List.generate(eqParams.bands.length, (i) {
                              final band = eqParams.bands[i];
                              final val = bandValues[i];
                              return Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      '${val >= 0 ? '+' : ''}${val.toStringAsFixed(0)}dB',
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: acc),
                                    ),
                                    Expanded(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: SliderTheme(
                                          data: SliderTheme.of(ctx).copyWith(
                                            trackHeight: 4,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                            activeTrackColor: acc,
                                            inactiveTrackColor: _border,
                                            thumbColor: Colors.white,
                                          ),
                                          child: Slider(
                                            min: eqParams.minDecibels,
                                            max: eqParams.maxDecibels,
                                            value: val,
                                            onChanged: !_eqEnabled
                                                ? null
                                                : (v) async {
                                                    setSheetState(() {
                                                      bandValues[i] = v;
                                                      _eqPreset = 'Personal';
                                                    });
                                                    try {
                                                      await band.setGain(v);
                                                    } catch (_) {}
                                                  },
                                            onChangeEnd: (_) {
                                              _eqSavedGains = List<double>.from(bandValues);
                                              _savePrefs();
                                              unawaited(_applySavedEqualizer());
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      formatFrequency(band.centerFrequency),
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _subtext),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Barra de refuerzo de potencia / bajos (LoudnessEnhancer)
                      Opacity(
                        opacity: _eqEnabled ? 1.0 : 0.45,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                          decoration: BoxDecoration(
                            color: _surfaceAlt,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.speaker_rounded, size: 16, color: acc),
                                      const SizedBox(width: 6),
                                      Text('Refuerzo de potencia', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _text)),
                                    ],
                                  ),
                                  Text(
                                    '${(_loudnessBoost / 0.50 * 100).round()}%',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: acc),
                                  ),
                                ],
                              ),
                              Slider(
                                min: 0.0,
                                max: 0.50,
                                value: _loudnessBoost.clamp(0.0, 0.50),
                                activeColor: acc,
                                inactiveColor: _border,
                                onChanged: !_eqEnabled
                                    ? null
                                    : (v) async {
                                        setState(() => _loudnessBoost = v);
                                        setSheetState(() {});
                                        try {
                                          await _audioHandler.loudnessEnhancer.setEnabled(v > 0.01);
                                          await _audioHandler.loudnessEnhancer.setTargetGain(v);
                                        } catch (_) {}
                                      },
                                onChangeEnd: (_) {
                                  _savePrefs();
                                  unawaited(_applySavedEqualizer());
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --- Editor rapido de titulo, artista y portada (con galeria) ---

  Future<void> _showEditTrackSheet(MediaTrack track) async {
    final titleCtrl = TextEditingController(text: track.title);
    final artistCtrl = TextEditingController(text: track.artist);
    String? tempCover = track.coverPath;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            final acc = _playerAccent;
            final hasCustomCover = tempCover != null && File(tempCover!).existsSync();

            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                    decoration: BoxDecoration(
                      color: withA(_surface, widget.darkMode ? 0.92 : 0.96),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                      border: Border(
                        top: BorderSide(color: withA(Colors.white, widget.darkMode ? 0.20 : 0.85), width: 1.2),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 14),
                            decoration: BoxDecoration(
                              color: withA(_text, 0.25),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Text('Editar canción', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _text)),
                          const SizedBox(height: 14),

                          // Vista previa de portada + boton cambiar foto
                          Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: hasCustomCover
                                    ? Image.file(File(tempCover!), width: 76, height: 76, fit: BoxFit.cover)
                                    : Container(
                                        width: 76,
                                        height: 76,
                                        color: _surfaceAlt,
                                        child: Icon(Icons.music_note_rounded, color: acc, size: 32),
                                      ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(backgroundColor: acc),
                                      onPressed: () async {
                                        try {
                                          final picked = await ImagePicker().pickImage(
                                            source: ImageSource.gallery,
                                            maxWidth: 900,
                                            maxHeight: 900,
                                            imageQuality: 88,
                                          );
                                          if (picked != null) {
                                            final coversDir = Directory('$_docsDir/custom_covers');
                                            if (!await coversDir.exists()) {
                                              await coversDir.create(recursive: true);
                                            }
                                            final hash = track.path.hashCode.abs();
                                            final ts = DateTime.now().millisecondsSinceEpoch;
                                            final dest = File('${coversDir.path}/cov_${hash}_$ts.jpg');
                                            await File(picked.path).copy(dest.path);
                                            setSheetState(() => tempCover = dest.path);
                                          }
                                        } catch (_) {
                                          _showSnack('No se pudo abrir la galería.');
                                        }
                                      },
                                      icon: const Icon(Icons.photo_library_rounded, size: 17, color: Colors.white),
                                      label: const Text('Elegir portada', style: TextStyle(color: Colors.white, fontSize: 12)),
                                    ),
                                    if (hasCustomCover)
                                      TextButton(
                                        onPressed: () => setSheetState(() => tempCover = ''),
                                        child: Text('Quitar portada', style: TextStyle(color: _subtext, fontSize: 11)),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          TextField(
                            controller: titleCtrl,
                            style: TextStyle(color: _text, fontSize: 14),
                            decoration: InputDecoration(
                              labelText: 'Título',
                              labelStyle: TextStyle(color: _subtext),
                              filled: true,
                              fillColor: _surfaceAlt,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: artistCtrl,
                            style: TextStyle(color: _text, fontSize: 14),
                            decoration: InputDecoration(
                              labelText: 'Artista',
                              labelStyle: TextStyle(color: _subtext),
                              filled: true,
                              fillColor: _surfaceAlt,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text('Cancelar', style: TextStyle(color: _subtext)),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: acc),
                                onPressed: () async {
                                  final newTitle = titleCtrl.text.trim();
                                  final newArtist = artistCtrl.text.trim();
                                  setState(() {
                                    if (newTitle.isNotEmpty) track.title = newTitle;
                                    if (newArtist.isNotEmpty) track.artist = newArtist;
                                    if (tempCover == '') {
                                      track.coverPath = null;
                                    } else if (tempCover != null) {
                                      CoverColorExtractor.invalidate(tempCover!);
                                      track.coverPath = tempCover;
                                    }
                                    _trackOverrides[track.path] = {
                                      'title': track.title,
                                      'artist': track.artist,
                                      'coverPath': track.coverPath ?? '',
                                    };
                                  });
                                  await _savePrefs();
                                  unawaited(_saveCachedLibrary(_allTracks));
                                  if (_currentTrack?.path == track.path) {
                                    final Uri? art = (track.coverPath != null && File(track.coverPath!).existsSync())
                                        ? Uri.file(track.coverPath!)
                                        : _defaultLogoUri;
                                    _audioHandler.updateCurrentMetadata(
                                      track.path,
                                      title: track.title,
                                      artist: track.artist,
                                      artUri: art,
                                    );
                                    await _refreshDynamicColorFor(track);
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _showSnack('Cambios guardados.');
                                },
                                child: const Text('Guardar', style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --- Editor de letra de la cancion (soporta texto plano o formato .lrc sincronizado) ---

  Future<void> _showEditLyricsDialog(MediaTrack track) async {
    String initialText = _customLyrics[track.path] ?? '';
    if (initialText.isEmpty) {
      try {
        final lrc = File('${pathWithoutExtension(track.path)}.lrc');
        if (await lrc.exists()) initialText = await lrc.readAsString();
      } catch (_) {}
    }

    final ctrl = TextEditingController(text: initialText);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Letra de la canción', style: TextStyle(color: _text, fontWeight: FontWeight.w600, fontSize: 17)),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pega la letra normal o en formato sincronizado [00:15.00] Línea...',
                style: TextStyle(color: _subtext, fontSize: 11),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 9,
                style: TextStyle(color: _text, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Pega aquí la letra...',
                  hintStyle: TextStyle(color: _subtext),
                  filled: true,
                  fillColor: _surfaceAlt,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (initialText.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  _customLyrics.remove(track.path);
                  _currentLyrics = [];
                });
                _savePrefs();
                Navigator.pop(ctx);
                _showSnack('Letra eliminada.');
              },
              child: Text('Borrar', style: TextStyle(color: _subtext)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancelar', style: TextStyle(color: _subtext)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _playerAccent),
            onPressed: () {
              final raw = ctrl.text.trim();
              setState(() {
                if (raw.isEmpty) {
                  _customLyrics.remove(track.path);
                  _currentLyrics = [];
                } else {
                  _customLyrics[track.path] = raw;
                  _currentLyrics = LyricsParser.parse(raw);
                }
                _lastScrolledLyricIdx = -1;
              });
              _savePrefs();
              Navigator.pop(ctx);
              _showSnack('Letra guardada.');
            },
            child: const Text('Guardar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // --- Menu de opciones por cancion ---

  Future<void> _showTrackOptionsSheet(MediaTrack track) async {
    final isFav = _favorites.contains(track.path);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
            decoration: BoxDecoration(
              color: withA(_surface, widget.darkMode ? 0.92 : 0.96),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
              border: Border(
                top: BorderSide(color: withA(Colors.white, widget.darkMode ? 0.18 : 0.85)),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: withA(_text, 0.25), borderRadius: BorderRadius.circular(2)),
                ),
                ListTile(
                  title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 15)),
                  subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _subtext, fontSize: 12)),
                ),
                Divider(height: 1, color: _border),
                if (!track.isVideo) ...[
                  ListTile(
                    leading: Icon(Icons.playlist_play_rounded, color: _accent),
                    title: Text('Reproducir siguiente', style: TextStyle(color: _text, fontSize: 14)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _playNextInQueue(track);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.queue_music_rounded, color: _subtext),
                    title: Text('Agregar al final de la cola', style: TextStyle(color: _text, fontSize: 14)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _appendToQueue(track);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.playlist_add_rounded, color: _subtext),
                    title: Text('Agregar a una lista', style: TextStyle(color: _text, fontSize: 14)),
                    onTap: () {
                      if (track.isOnline) _rememberOnlineTrack(track);
                      Navigator.pop(ctx);
                      _showAddToPlaylistDialog(track.path);
                    },
                  ),
                  if (!track.isOnline)
                    ListTile(
                      leading: Icon(Icons.edit_rounded, color: _subtext),
                      title: Text('Editar nombre, artista y portada', style: TextStyle(color: _text, fontSize: 14)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showEditTrackSheet(track);
                      },
                    ),
                ],
                ListTile(
                  leading: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFav ? _accent : _subtext),
                  title: Text(isFav ? 'Quitar de Favoritos' : 'Guardar en Favoritos', style: TextStyle(color: _text, fontSize: 14)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleFavorite(track.path, track: track);
                  },
                ),
                if (!track.isOnline)
                  ListTile(
                    leading: Icon(Icons.lock_outline_rounded, color: _subtext),
                    title: Text('Mover a Zona Privada', style: TextStyle(color: _text, fontSize: 14)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _moveToPrivate(track.path);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Favoritos, playlists, velocidad, temporizador ---

  void _toggleFavorite(String path, {MediaTrack? track}) {
    if (track != null && track.isOnline) _rememberOnlineTrack(track);
    setState(() {
      if (_favorites.contains(path)) {
        _favorites.remove(path);
        _showSnack('Quitado de Favoritos.');
      } else {
        _favorites.add(path);
        _showSnack('Guardado en Favoritos.');
      }
    });
    _savePrefs();
  }

  void _moveToPrivate(String path) {
    setState(() => _privatePaths.add(path));
    _savePrefs();
    _showSnack('Movido a Zona Privada.');
  }

  void _removeFromPrivate(String path) {
    setState(() => _privatePaths.remove(path));
    _savePrefs();
    _showSnack('Devuelto a tu biblioteca.');
  }

  Future<void> _showCreatePlaylistDialog({String? initialTrackPath}) async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Nueva lista', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _text),
          decoration: InputDecoration(
            hintText: 'Ej: Noche, Chill, Gym',
            hintStyle: TextStyle(color: _subtext),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancelar', style: TextStyle(color: _subtext)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              setState(() {
                _playlists.putIfAbsent(name, () => []);
                if (initialTrackPath != null && !_playlists[name]!.contains(initialTrackPath)) {
                  _playlists[name]!.add(initialTrackPath);
                } else {
                  _musicFilter = 'PL::$name';
                }
              });
              _savePrefs();
              Navigator.pop(ctx);
              _showSnack('Lista "$name" creada.');
            },
            child: const Text('Crear', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddToPlaylistDialog(String trackPath) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final names = _playlists.keys.toList()..sort();
        return AlertDialog(
          backgroundColor: _surface,
          title: Text('Agregar a lista', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
          content: SizedBox(
            width: 300,
            child: names.isEmpty
                ? Text('Crea tu primera lista abajo.', style: TextStyle(color: _subtext, fontSize: 13))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: names.length,
                    itemBuilder: (_, i) {
                      final n = names[i];
                      final exists = _playlists[n]!.contains(trackPath);
                      return ListTile(
                        leading: Icon(
                          exists ? Icons.check_circle_rounded : Icons.queue_music_rounded,
                          color: exists ? _accent : _subtext,
                        ),
                        title: Text(n, style: TextStyle(color: _text, fontWeight: FontWeight.w500)),
                        onTap: () {
                          setState(() {
                            if (exists) {
                              _playlists[n]!.remove(trackPath);
                              _showSnack('Quitada de "$n".');
                            } else {
                              _playlists[n]!.add(trackPath);
                              _showSnack('Agregada a "$n".');
                            }
                          });
                          _savePrefs();
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cerrar', style: TextStyle(color: _subtext)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () {
                Navigator.pop(ctx);
                _showCreatePlaylistDialog(initialTrackPath: trackPath);
              },
              icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
              label: const Text('Nueva', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSpeedDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Velocidad', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: kSpeedOptions.map((s) {
            final active = (_speed - s).abs() < 0.01;
            return ListTile(
              title: Text(
                '${s == s.roundToDouble() ? s.toInt() : s}x${s == 1.0 ? ' (Normal)' : ''}',
                style: TextStyle(
                  color: active ? _playerAccent : _text,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: active ? Icon(Icons.check_rounded, color: _playerAccent) : null,
              onTap: () {
                setState(() => _speed = s);
                _audioHandler.setSpeedLive(s);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _showSleepTimerDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Temporizador', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [5, 15, 30, 60, 0].map((m) {
            return ListTile(
              title: Text(
                m == 0 ? 'Desactivar' : '$m minutos',
                style: TextStyle(color: _text),
              ),
              onTap: () {
                setState(() => _sleepRemainingSec = m * 60);
                Navigator.pop(ctx);
                _showSnack(m == 0 ? 'Temporizador apagado.' : 'Se pausará en $m min.');
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  // --- Logo, Portada clasica, Disco de Vinilo girando y Panel de Letras ---

  Widget _buildLogoAvatar(double size) {
    if (_hasLogoAsset) {
      return Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: ClipOval(
          child: Image.asset(
            'assets/logo.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Icon(Icons.headphones_rounded, color: _accent, size: size * 0.55),
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: withA(_accent, 0.2),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.headphones_rounded, color: _accent, size: size * 0.55),
    );
  }

  Widget _buildVinylDisc(MediaTrack? track, double size) {
    final acc = _playerAccent;
    final coverFile = (track?.coverPath != null) ? File(track!.coverPath!) : null;
    final labelSize = size * 0.44;

    Widget labelContent;
    if (coverFile != null && coverFile.existsSync()) {
      labelContent = ClipOval(
        child: Image.file(coverFile, width: labelSize, height: labelSize, fit: BoxFit.cover),
      );
    } else if (track?.remoteArtUrl != null && track!.remoteArtUrl!.isNotEmpty) {
      labelContent = ClipOval(
        child: Image.network(
          track.remoteArtUrl!,
          width: labelSize,
          height: labelSize,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Icon(Icons.headphones_rounded, color: Colors.white, size: labelSize * 0.45),
        ),
      );
    } else if (_hasLogoAsset) {
      labelContent = Container(
        width: labelSize,
        height: labelSize,
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.contain)),
      );
    } else {
      labelContent = Container(
        width: labelSize,
        height: labelSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [acc, Color.lerp(acc, Colors.black, 0.35) ?? acc],
          ),
        ),
        child: Icon(Icons.headphones_rounded, color: Colors.white, size: labelSize * 0.45),
      );
    }

    return AnimatedScale(
      scale: _isPlaying ? 1.0 : 0.94,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: withA(acc, _isPlaying ? 0.36 : 0.12),
              blurRadius: _isPlaying ? 34 : 18,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: withA(Colors.black, 0.55),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            RotationTransition(
              turns: _vinylController,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [
                      Color(0xFF22222A),
                      Color(0xFF101016),
                      Color(0xFF1A1A22),
                      Color(0xFF0A0A0E),
                    ],
                    stops: [0.22, 0.48, 0.72, 1.0],
                  ),
                  border: Border.all(color: withA(Colors.white, 0.14), width: 1.5),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Surcos finos del vinilo
                    for (final factor in [0.88, 0.76, 0.64, 0.54])
                      Container(
                        width: size * factor,
                        height: size * factor,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: withA(Colors.white, 0.06), width: 1),
                        ),
                      ),
                    // Etiqueta central con portada o logo
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: withA(acc, 0.65), width: 2),
                      ),
                      child: labelContent,
                    ),
                    // Orificio central del vinilo
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _bg,
                        shape: BoxShape.circle,
                        border: Border.all(color: withA(Colors.white, 0.35), width: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Brillo diagonal fijo sobre el disco mientras gira
            IgnorePointer(
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    colors: [
                      Colors.transparent,
                      withA(Colors.white, 0.10),
                      Colors.transparent,
                      withA(Colors.white, 0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBigCover(MediaTrack? track, double size) {
    final acc = _playerAccent;
    final coverFile = (track?.coverPath != null) ? File(track!.coverPath!) : null;
    Widget inner;

    if (coverFile != null && coverFile.existsSync()) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Image.file(
          coverFile,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    } else if (track?.remoteArtUrl != null && track!.remoteArtUrl!.isNotEmpty) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Image.network(
          track.remoteArtUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: _surfaceAlt,
            child: Icon(Icons.headphones_rounded, size: size * 0.36, color: acc),
          ),
        ),
      );
    } else if (_hasLogoAsset) {
      inner = Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.08),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.contain,
        ),
      );
    } else {
      inner = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              blendSolid(acc, _surfaceAlt, 0.16),
              _surfaceAlt,
            ],
          ),
          border: Border.all(color: withA(Colors.white, widget.darkMode ? 0.12 : 0.6)),
        ),
        child: Icon(Icons.headphones_rounded, size: size * 0.36, color: acc),
      );
    }

    return AnimatedScale(
      scale: _isPlaying ? 1.0 : 0.93,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: withA(acc, _isPlaying ? 0.36 : 0.10),
              blurRadius: _isPlaying ? 34 : 16,
              spreadRadius: _isPlaying ? -2 : -6,
              offset: const Offset(0, 14),
            ),
            BoxShadow(
              color: withA(Colors.black, widget.darkMode ? 0.45 : 0.16),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: inner,
      ),
    );
  }

  Widget _buildLyricsStage(MediaTrack track, double size) {
    final acc = _playerAccent;
    final dark = widget.darkMode;

    return Container(
      width: double.infinity,
      height: size,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [withA(Colors.white, 0.10), withA(const Color(0xFF14141E), 0.72)]
              : [withA(Colors.white, 0.85), withA(Colors.white, 0.60)],
        ),
        border: Border.all(color: dark ? withA(Colors.white, 0.16) : withA(Colors.black, 0.08)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.lyrics_rounded, size: 16, color: acc),
                  const SizedBox(width: 6),
                  Text('Letra', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _text)),
                ],
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showEditLyricsDialog(track),
                icon: Icon(Icons.edit_rounded, size: 14, color: acc),
                label: Text(
                  _currentLyrics.isEmpty ? 'Pegar letra' : 'Editar',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: acc),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _currentLyrics.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lyrics_outlined, size: 36, color: withA(_subtext, 0.6)),
                        const SizedBox(height: 8),
                        Text(
                          'Sin letra guardada todavía',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Toca "Pegar letra" o coloca un archivo .lrc junto a tu canción.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: _subtext),
                        ),
                      ],
                    ),
                  )
                : StreamBuilder<Duration>(
                    stream: _audioHandler.unifiedPositionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final activeIdx = LyricsParser.activeIndex(_currentLyrics, pos);

                      if (activeIdx >= 0 && activeIdx != _lastScrolledLyricIdx && _lyricsScrollCtrl.hasClients) {
                        _lastScrolledLyricIdx = activeIdx;
                        final targetOffset = max(0.0, (activeIdx * 42.0) - (size * 0.30));
                        final maxScroll = _lyricsScrollCtrl.position.maxScrollExtent;
                        _lyricsScrollCtrl.animateTo(
                          targetOffset.clamp(0.0, maxScroll),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                        );
                      }

                      return ListView.builder(
                        controller: _lyricsScrollCtrl,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        itemCount: _currentLyrics.length,
                        itemBuilder: (_, i) {
                          final line = _currentLyrics[i];
                          final isSynced = line.time != null;
                          final isActive = isSynced && i == activeIdx;

                          return GestureDetector(
                            onTap: isSynced
                                ? () => _audioHandler.seek(line.time!)
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 220),
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontSize: isActive ? 17 : 14,
                                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  color: isActive
                                      ? acc
                                      : (isSynced ? withA(_text, 0.56) : _text),
                                ),
                                child: Text(
                                  line.text,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- Controles de reproduccion con vida y acabado Liquid Glass ---

  Widget _buildGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 50,
    double iconSize = 26,
    bool active = false,
    bool showActiveDot = false,
    Color? accentOverride,
  }) {
    final dark = widget.darkMode;
    final acc = accentOverride ?? _playerAccent;
    final fg = active
        ? (dark ? Colors.white : acc)
        : (dark ? withA(Colors.white, 0.90) : _text);

    return _SpringPressButton(
      onTap: onTap,
      pressedScale: 0.87,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: active
                    ? [
                        withA(acc, dark ? 0.42 : 0.28),
                        withA(acc, dark ? 0.18 : 0.12),
                      ]
                    : (dark
                        ? [
                            withA(Colors.white, 0.14),
                            withA(Colors.white, 0.04),
                          ]
                        : [
                            withA(Colors.white, 0.90),
                            withA(Colors.white, 0.55),
                          ]),
              ),
              border: Border.all(
                color: active
                    ? withA(acc, 0.65)
                    : (dark ? withA(Colors.white, 0.18) : withA(Colors.black, 0.08)),
                width: 1.15,
              ),
              boxShadow: [
                if (active)
                  BoxShadow(
                    color: withA(acc, 0.34),
                    blurRadius: 16,
                    spreadRadius: -2,
                  ),
                BoxShadow(
                  color: withA(Colors.black, dark ? 0.28 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(icon, size: iconSize, color: fg),
          ),
          if (showActiveDot) ...[
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: active ? 5 : 0,
              height: active ? 5 : 0,
              decoration: BoxDecoration(
                color: acc,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: withA(acc, 0.7), blurRadius: 6),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroPlayPauseOrb({double size = 74, double iconSize = 38, Color? accentOverride}) {
    final acc = accentOverride ?? _playerAccent;
    final lightTint = Color.lerp(acc, Colors.white, 0.34) ?? acc;
    final deepTint = Color.lerp(acc, Colors.black, 0.24) ?? acc;

    return _SpringPressButton(
      onTap: _togglePlayPause,
      pressedScale: 0.90,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0.0, 0.42, 1.0],
            colors: [lightTint, acc, deepTint],
          ),
          border: Border.all(
            color: withA(Colors.white, 0.45),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: withA(acc, _isPlaying ? 0.62 : 0.34),
              blurRadius: _isPlaying ? 28 : 16,
              spreadRadius: _isPlaying ? 1 : -2,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: withA(Colors.black, 0.32),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 4,
              left: size * 0.20,
              right: size * 0.20,
              height: size * 0.28,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      withA(Colors.white, 0.38),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: Tween<double>(begin: 0.65, end: 1.0).animate(anim),
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: _loadingOnlineTrack
                  ? SizedBox(
                      key: const ValueKey<String>('loading'),
                      width: iconSize * 0.68,
                      height: iconSize * 0.68,
                      child: const CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                    )
                  : Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey<bool>(_isPlaying),
                      color: Colors.white,
                      size: iconSize,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Construccion Principal ---

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return AnimatedBuilder(
      animation: _sheetController,
      builder: (context, _) {
        final sheetOpen = _sheetController.value > 0.01;
        return PopScope(
          canPop: !sheetOpen && !_videoFullscreen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_videoFullscreen) {
                _exitVideoFullscreen();
              } else if (sheetOpen) {
                _closePlayerSheet();
              }
            }
          },
          child: Scaffold(
            backgroundColor: _bg,
            body: Stack(
              children: [
                SafeArea(
                  bottom: false,
                  child: _buildActiveTabBody(),
                ),

                Positioned(
                  left: 14,
                  right: 14,
                  bottom: safeBottom + 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_currentTrack != null) _buildMiniPlayerGlass(),
                      if (_currentTrack != null) const SizedBox(height: 10),
                      _buildLiquidGlassBottomNav(),
                    ],
                  ),
                ),

                if (_currentTrack != null && _sheetController.value > 0.0)
                  FractionalTranslation(
                    translation: Offset(0, 1.0 - _sheetController.value),
                    child: Material(
                      color: _bg,
                      child: _currentTrack!.isVideo
                          ? _buildVideoPlayerSheet()
                          : _buildMusicPlayerSheet(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActiveTabBody() {
    switch (_activeTab) {
      case 0:
        return _buildMediaListTab(isVideo: false);
      case 1:
        return _buildOnlineSearchTab();
      case 2:
        return _buildMediaListTab(isVideo: true);
      case 3:
        return _buildPrivateTab();
      default:
        return _buildSettingsTab();
    }
  }

  // --- Pestana Buscador de Musica en Linea ---

  Widget _buildOnlineSearchTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  _buildLogoAvatar(40),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'relaxPlayer',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent),
                      ),
                      Text(
                        'En línea',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _text),
                      ),
                    ],
                  ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.equalizer_rounded, color: _eqEnabled ? _accent : _subtext, size: 23),
                tooltip: 'Ecualizador',
                onPressed: _showEqualizerSheet,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Barra de busqueda en linea
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _onlineSearchCtrl,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(color: _text, fontSize: 14),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _searchOnlineMusic,
                  decoration: InputDecoration(
                    hintText: 'Busca cualquier canción o artista...',
                    hintStyle: TextStyle(color: _subtext, fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded, color: _subtext, size: 20),
                    suffixIcon: _onlineSearchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.close_rounded, color: _subtext, size: 18),
                            onPressed: () {
                              _onlineSearchCtrl.clear();
                              setState(() {
                                _onlineResults = [];
                                _onlineError = null;
                              });
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: _surface,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: _border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: _border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: _accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SpringPressButton(
                onTap: () => _searchOnlineMusic(_onlineSearchCtrl.text),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Expanded(
            child: _searchingOnline
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: _accent),
                          const SizedBox(height: 14),
                          Text('Buscando en línea...', style: TextStyle(fontSize: 13, color: _subtext)),
                        ],
                      ),
                    ),
                  )
                : _onlineResults.isEmpty
                    ? ListView(
                        padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                        children: [
                          if (_onlineError != null) ...[
                            Container(
                              padding: const EdgeInsets.all(16),
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                color: _surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: withA(_accent, 0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.wifi_off_rounded, color: _accent, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(_onlineError!, style: TextStyle(fontSize: 12, color: _text)),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // Busquedas recientes
                          if (_recentOnlineSearches.isNotEmpty) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Recientes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _recentOnlineSearches.clear());
                                    _savePrefs();
                                  },
                                  child: Text('Limpiar', style: TextStyle(fontSize: 11, color: _subtext)),
                                ),
                              ],
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _recentOnlineSearches.map((term) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    _onlineSearchCtrl.text = term;
                                    _searchOnlineMusic(term);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: _surface,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: _border),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.history_rounded, size: 14, color: _subtext),
                                        const SizedBox(width: 6),
                                        Text(term, style: TextStyle(fontSize: 12, color: _text)),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 18),
                          ],

                          // Explorar por estilo
                          Text('Explorar estilos', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: kOnlineQuickGenres.map((genre) {
                              return InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () {
                                  _onlineSearchCtrl.text = genre;
                                  _searchOnlineMusic(genre);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: withA(_accent, 0.14),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: withA(_accent, 0.32)),
                                  ),
                                  child: Text(
                                    genre,
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _text),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 22),

                          // Tarjeta informativa limpia
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _surface,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: _border),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: withA(_accent, 0.18),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(Icons.public_rounded, color: _accent, size: 22),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Escucha sin descargar', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Mezcla canciones en línea en la misma cola con tus temas descargados, usando tu ecualizador y crossfade.',
                                        style: TextStyle(fontSize: 11, color: _subtext),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        itemCount: _onlineResults.length,
                        itemExtent: 68,
                        padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                        itemBuilder: (_, i) {
                          final t = _onlineResults[i];
                          final isCurrent = _currentTrack?.path == t.path;
                          final isFav = _favorites.contains(t.path);
                          final durText = t.durationMs != null && t.durationMs! > 0
                              ? '  ·  ${formatTime(Duration(milliseconds: t.durationMs!))}'
                              : '';

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: isCurrent ? withA(_accent, 0.16) : _surface,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _playTrack(t, _onlineResults, openSheet: true),
                                onLongPress: () => _showTrackOptionsSheet(t),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: (t.remoteArtUrl != null && t.remoteArtUrl!.isNotEmpty)
                                            ? Image.network(
                                                t.remoteArtUrl!,
                                                width: 46,
                                                height: 46,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) => Container(
                                                  width: 46,
                                                  height: 46,
                                                  color: _surfaceAlt,
                                                  child: Icon(Icons.music_note_rounded, color: _accent, size: 22),
                                                ),
                                              )
                                            : Container(
                                                width: 46,
                                                height: 46,
                                                color: _surfaceAlt,
                                                child: Icon(Icons.music_note_rounded, color: _accent, size: 22),
                                              ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              t.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: isCurrent ? _accent : _text,
                                              ),
                                            ),
                                            Text(
                                              '${t.artist}$durText',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 11, color: _subtext),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                          size: 19,
                                          color: isFav ? _accent : _subtext,
                                        ),
                                        onPressed: () => _toggleFavorite(t.path, track: t),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.more_vert_rounded, size: 20, color: _subtext),
                                        onPressed: () => _showTrackOptionsSheet(t),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  // --- Pestana Musica / Videos ---

  Widget _buildMediaListTab({required bool isVideo}) {
    final sectionTitle = isVideo ? 'Videos' : 'Música';
    final filter = isVideo ? _videoFilter : _musicFilter;
    final sort = isVideo ? _videoSort : _musicSort;
    final searchCtrl = isVideo ? _videoSearchCtrl : _musicSearchCtrl;

    final allInTab = _getList(isVideo: isVideo, onlyPrivate: false);
    final folders = allInTab.map((t) => t.folder).toSet().toList()..sort();
    final plNames = isVideo ? <String>[] : (_playlists.keys.toList()..sort());
    final chips = <String>[
      'Todas',
      'Favoritos',
      if (!isVideo) 'Top',
      ...plNames.map((n) => 'PL::$n'),
      ...folders.take(8),
    ];

    final tracks = _filteredList(isVideo);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  _buildLogoAvatar(40),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'relaxPlayer',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent),
                      ),
                      Text(
                        sectionTitle,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _text),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  if (!isVideo)
                    IconButton(
                      icon: Icon(Icons.equalizer_rounded, color: _eqEnabled ? _accent : _subtext, size: 23),
                      tooltip: 'Ecualizador',
                      onPressed: _showEqualizerSheet,
                    ),
                  IconButton(
                    icon: _scanning
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
                          )
                        : Icon(Icons.refresh_rounded, color: _accent, size: 24),
                    tooltip: 'Actualizar biblioteca',
                    onPressed: () => _scanDeviceMedia(showToast: true),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          TextField(
            controller: searchCtrl,
            style: TextStyle(color: _text, fontSize: 14),
            onChanged: (v) {
              setState(() {
                if (isVideo) {
                  _videoQuery = v;
                } else {
                  _musicQuery = v;
                }
              });
            },
            decoration: InputDecoration(
              hintText: isVideo ? 'Buscar video...' : 'Buscar canción o artista...',
              hintStyle: TextStyle(color: _subtext, fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded, color: _subtext, size: 20),
              filled: true,
              fillColor: _surface,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _accent),
              ),
            ),
          ),
          const SizedBox(height: 10),

          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ...chips.map((c) {
                  final active = c == filter;
                  final fg = active ? Colors.white : _text;
                  Widget labelWidget;
                  if (c == 'Favoritos') {
                    labelWidget = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_rounded, size: 13, color: active ? Colors.white : _accent),
                        const SizedBox(width: 5),
                        Text('Favoritos', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
                      ],
                    );
                  } else if (c == 'Top') {
                    labelWidget = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.local_fire_department_rounded, size: 14, color: active ? Colors.white : _accent),
                        const SizedBox(width: 4),
                        Text('Top', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
                      ],
                    );
                  } else if (c.startsWith('PL::')) {
                    labelWidget = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.queue_music_rounded, size: 14, color: active ? Colors.white : _accent),
                        const SizedBox(width: 5),
                        Text(c.substring(4), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
                      ],
                    );
                  } else {
                    labelWidget = Text(c, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg));
                  }

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        setState(() {
                          if (isVideo) {
                            _videoFilter = c;
                          } else {
                            _musicFilter = c;
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                        decoration: BoxDecoration(
                          color: active ? _accent : _surfaceAlt,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        alignment: Alignment.center,
                        child: labelWidget,
                      ),
                    ),
                  );
                }),
                if (!isVideo)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _showCreatePlaylistDialog(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: withA(_accent, 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded, size: 14, color: _accent),
                          const SizedBox(width: 4),
                          Text('Lista', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _accent)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                (!isVideo && filter == 'Top')
                    ? 'Top ${tracks.length} más escuchadas'
                    : '${tracks.length} ${isVideo ? 'videos' : 'canciones'}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
              ),
              if (!isVideo && filter == 'Top')
                Text(
                  'Por reproducciones',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent),
                )
              else
              Row(
                children: [
                  ('recientes', 'Recientes'),
                  ('az', 'A-Z'),
                  ('carpeta', 'Origen'),
                ].map((pair) {
                  final active = sort == pair.$1;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      setState(() {
                        if (isVideo) {
                          _videoSort = pair.$1;
                        } else {
                          _musicSort = pair.$1;
                        }
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: active ? withA(_accent, 0.18) : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        pair.$2,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                          color: active ? _accent : _subtext,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 6),

          Expanded(
            child: tracks.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 24, 24, _bottomScrollClearance),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildLogoAvatar(82),
                          const SizedBox(height: 14),
                          Text(
                            (!isVideo && filter == 'Top')
                                ? 'Aún no tienes un Top'
                                : (_scanning
                                    ? 'Buscando archivos...'
                                    : 'No encontré ${isVideo ? 'videos' : 'canciones'}'),
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            (!isVideo && filter == 'Top')
                                ? 'Escucha tus canciones y aquí aparecerán tus más reproducidas.'
                                : 'relaxPlayer lee automáticamente tu Música, Descargas y Videos.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: _subtext),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: _accent),
                            onPressed: () => _scanDeviceMedia(showToast: true),
                            icon: const Icon(Icons.refresh_rounded, size: 18, color: Colors.white),
                            label: const Text('Volver a escanear', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: tracks.length,
                    itemExtent: 64,
                    padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final isCurrent = _currentTrack?.path == t.path;
                      final isFav = _favorites.contains(t.path);
                      final isTopView = !isVideo && filter == 'Top';
                      final playCnt = _trackPlayCounts[t.path] ?? 0;
                      final hasThumb = !isVideo && t.coverPath != null && File(t.coverPath!).existsSync();

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: isCurrent ? withA(_accent, 0.16) : _surface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _playTrack(t, tracks, openSheet: true),
                            onLongPress: () => _showTrackOptionsSheet(t),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Row(
                                children: [
                                  if (isTopView)
                                    Container(
                                      width: 28,
                                      alignment: Alignment.center,
                                      margin: const EdgeInsets.only(right: 6),
                                      child: Text(
                                        '#${i + 1}',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: i < 3 ? _accent : _subtext,
                                        ),
                                      ),
                                    ),
                                  hasThumb
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: Image.file(
                                            File(t.coverPath!),
                                            width: 42,
                                            height: 42,
                                            fit: BoxFit.cover,
                                          ),
                                        )
                                      : (!isVideo && t.remoteArtUrl != null && t.remoteArtUrl!.isNotEmpty)
                                          ? ClipRRect(
                                              borderRadius: BorderRadius.circular(10),
                                              child: Image.network(
                                                t.remoteArtUrl!,
                                                width: 42,
                                                height: 42,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) => Container(
                                                  width: 42,
                                                  height: 42,
                                                  color: _surfaceAlt,
                                                  child: Icon(Icons.public_rounded, size: 20, color: _accent),
                                                ),
                                              ),
                                            )
                                          : Container(
                                          width: 42,
                                          height: 42,
                                          decoration: BoxDecoration(
                                            color: isCurrent ? withA(_accent, 0.25) : _surfaceAlt,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                            isCurrent
                                                ? Icons.graphic_eq_rounded
                                                : (isVideo ? Icons.play_circle_fill_rounded : Icons.music_note_rounded),
                                            size: 21,
                                            color: isCurrent ? _accent : _subtext,
                                          ),
                                        ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: isCurrent ? _accent : _text,
                                          ),
                                        ),
                                        Text(
                                          isVideo
                                              ? '${t.folder} / ${t.ext}'
                                              : (isTopView
                                                  ? '${t.artist}  ·  $playCnt ${playCnt == 1 ? 'vez' : 'veces'}'
                                                  : '${t.artist} / ${t.ext}'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11, color: _subtext),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                      size: 19,
                                      color: isFav ? _accent : _subtext,
                                    ),
                                    onPressed: () => _toggleFavorite(t.path),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.more_vert_rounded, size: 20, color: _subtext),
                                    onPressed: () => _showTrackOptionsSheet(t),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- Pestana Zona Privada ---

  Widget _buildPrivateTab() {
    if (!_vaultUnlocked) {
      return Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(28, 28, 28, _bottomScrollClearance),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: withA(_accent, 0.16), shape: BoxShape.circle),
                child: Icon(Icons.lock_rounded, size: 32, color: _accent),
              ),
              const SizedBox(height: 14),
              Text('Zona Privada', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: _text)),
              const SizedBox(height: 14),
              SizedBox(
                width: 230,
                child: TextField(
                  controller: _pinCtrl,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _text),
                  decoration: InputDecoration(
                    labelText: 'PIN (inicial: 1234)',
                    labelStyle: TextStyle(color: _subtext, fontSize: 12),
                    filled: true,
                    fillColor: _surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () {
                  if (_pinCtrl.text.trim() == _pin) {
                    _pinCtrl.clear();
                    setState(() => _vaultUnlocked = true);
                  } else {
                    _showSnack('PIN incorrecto.');
                  }
                },
                child: const Text('Desbloquear', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    final isVid = _privateFilter == 'video';
    final items = _getList(isVideo: isVid, onlyPrivate: true);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Zona Privada', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: _text)),
              TextButton(
                onPressed: () => setState(() => _vaultUnlocked = false),
                child: Text('Bloquear', style: TextStyle(color: _accent, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ('audio', 'Música'),
              ('video', 'Videos'),
            ].map((pair) {
              final active = _privateFilter == pair.$1;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => setState(() => _privateFilter = pair.$1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
                    decoration: BoxDecoration(
                      color: active ? _accent : _surfaceAlt,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      pair.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : _text,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                      child: Text(
                        'No tienes ${isVid ? 'videos' : 'canciones'} ocultos.',
                        style: TextStyle(color: _subtext, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    padding: EdgeInsets.only(bottom: _bottomScrollClearance),
                    itemBuilder: (_, i) {
                      final t = items[i];
                      return Card(
                        color: _surface,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          leading: Icon(isVid ? Icons.movie_rounded : Icons.music_note_rounded, color: _accent),
                          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _text, fontSize: 13, fontWeight: FontWeight.w600)),
                          trailing: IconButton(
                            icon: Icon(Icons.visibility_rounded, color: _subtext, size: 20),
                            onPressed: () => _removeFromPrivate(t.path),
                          ),
                          onTap: () => _playTrack(t, items, openSheet: true),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- Pestana Ajustes ---

  Widget _buildSettingsTab() {
    final maxSec = max(60, _dailySeconds.values.fold<int>(0, max));
    final totalMin = _dailySeconds.values.fold<int>(0, (a, b) => a + b) ~/ 60;
    final nMus = _getList(isVideo: false, onlyPrivate: false).length;
    final nVid = _getList(isVideo: true, onlyPrivate: false).length;
    final top5 = _getTopTracks(limit: 5);

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, _bottomScrollClearance),
      children: [
        Row(
          children: [
            _buildLogoAvatar(38),
            const SizedBox(width: 10),
            Text('Ajustes relaxPlayer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _text)),
          ],
        ),
        const SizedBox(height: 14),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Tu semana', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                  Text(
                    '$totalMin min / $_totalPlays reproducciones',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 98,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: kWeekDays.map((d) {
                    final sec = _dailySeconds[d] ?? 0;
                    final h = max(8.0, (sec / maxSec) * 72.0);
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          width: 20,
                          height: h,
                          decoration: BoxDecoration(color: _accent, borderRadius: BorderRadius.circular(7)),
                        ),
                        const SizedBox(height: 4),
                        Text(d, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _subtext)),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Top 5 mas escuchadas (mini ranking personal)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.local_fire_department_rounded, size: 18, color: _accent),
                      const SizedBox(width: 6),
                      Text('Top más escuchadas', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                    ],
                  ),
                  if (top5.isNotEmpty)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          _musicFilter = 'Top';
                          _activeTab = 0;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text('Ver todo', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (top5.isEmpty)
                Text(
                  'Escucha algunas canciones y aquí aparecerá tu ranking personal.',
                  style: TextStyle(fontSize: 12, color: _subtext),
                )
              else
                ...List.generate(top5.length, (idx) {
                  final t = top5[idx];
                  final cnt = _trackPlayCounts[t.path] ?? 0;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _playTrack(t, _getTopTracks(limit: 25), openSheet: true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 26,
                            child: Text(
                              '#${idx + 1}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: idx < 3 ? _accent : _subtext,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text),
                                ),
                                Text(
                                  t.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: _subtext),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: withA(_accent, 0.16),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$cnt',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Reproduccion inteligente: Transicion suave (Crossfade) + Pausa al desconectar audifonos
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pausa al desconectar audífonos', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                        Text('Se detiene sola si quitas el cable o el Bluetooth', style: TextStyle(fontSize: 11, color: _subtext)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _autoPauseDisconnect,
                    onChanged: (v) {
                      setState(() => _autoPauseDisconnect = v);
                      _audioHandler.autoPauseOnDisconnect = v;
                      _savePrefs();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Transición suave (Crossfade)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                  Text(
                    _crossfadeSeconds == 0 ? 'Apagado' : '${_crossfadeSeconds}s',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _accent),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Mezcla el final de una canción con el inicio de la siguiente',
                style: TextStyle(fontSize: 11, color: _subtext),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [0, 2, 4, 6, 8].map((sec) {
                  final selected = _crossfadeSeconds == sec;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: sec == 8 ? 0 : 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() => _crossfadeSeconds = sec);
                          _audioHandler.crossfadeSeconds = sec;
                          _savePrefs();
                          _showSnack(sec == 0 ? 'Crossfade desactivado.' : 'Crossfade ajustado a ${sec}s.');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: selected ? _accent : _surfaceAlt,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            sec == 0 ? 'Off' : '${sec}s',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: selected ? Colors.white : _text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Apariencia + Colores Camaleon + Modo Vinilo
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Modo oscuro', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                  Switch(
                    value: widget.darkMode,
                    onChanged: (v) {
                      widget.onThemeChanged(darkMode: v);
                      SharedPreferences.getInstance().then((p) => p.setBool('dark_mode', v));
                    },
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Colores camaleón', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                        Text('Adapta el reproductor al color de cada portada', style: TextStyle(fontSize: 11, color: _subtext)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _chameleonMode,
                    onChanged: (v) {
                      setState(() {
                        _chameleonMode = v;
                        if (!v) _dynamicAccent = null;
                      });
                      _savePrefs();
                      if (v && _currentTrack != null) {
                        _refreshDynamicColorFor(_currentTrack!);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Modo disco de vinilo', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                        Text('Muestra un vinilo girando al reproducir', style: TextStyle(fontSize: 11, color: _subtext)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _vinylMode,
                    onChanged: (v) {
                      setState(() => _vinylMode = v);
                      _syncVinylAnimation();
                      _savePrefs();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text('Color principal', style: TextStyle(fontSize: 12, color: _subtext)),
              const SizedBox(height: 10),
              Row(
                children: kAccentThemes.entries.map((entry) {
                  final selected = widget.accentName == entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        widget.onThemeChanged(accentName: entry.key);
                        SharedPreferences.getInstance().then((p) => p.setString('accent', entry.key));
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: entry.value,
                          shape: BoxShape.circle,
                          border: selected ? Border.all(color: _text, width: 3) : null,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Acceso rapido al Ecualizador
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ecualizador y bajos', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                  Text(
                    _eqEnabled ? 'Activo ($_eqPreset)' : 'Desactivado',
                    style: TextStyle(fontSize: 11, color: _eqEnabled ? _accent : _subtext),
                  ),
                ],
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: _showEqualizerSheet,
                icon: const Icon(Icons.equalizer_rounded, size: 16, color: Colors.white),
                label: const Text('Abrir', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // PIN
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newPinCtrl,
                  maxLength: 6,
                  style: TextStyle(color: _text, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Cambiar PIN',
                    labelStyle: TextStyle(color: _subtext, fontSize: 12),
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: _surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () {
                  final val = _newPinCtrl.text.trim();
                  if (val.length >= 4) {
                    setState(() => _pin = val);
                    _newPinCtrl.clear();
                    _savePrefs();
                    _showSnack('PIN actualizado.');
                  } else {
                    _showSnack('Usa mínimo 4 caracteres.');
                  }
                },
                child: const Text('Guardar', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Biblioteca
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(18)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Biblioteca', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _text)),
                  Text('$nMus canciones y $nVid videos detectados', style: TextStyle(fontSize: 11, color: _subtext)),
                ],
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => _scanDeviceMedia(showToast: true),
                icon: const Icon(Icons.refresh_rounded, size: 16, color: Colors.white),
                label: const Text('Actualizar', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Mini Reproductor con efecto cristal ---

  Widget _buildMiniPlayerGlass() {
    final track = _currentTrack!;
    final coverFile = (track.coverPath != null) ? File(track.coverPath!) : null;
    final dark = widget.darkMode;
    final acc = _playerAccent;

    Widget thumb;
    if (coverFile != null && coverFile.existsSync()) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(coverFile, width: 42, height: 42, fit: BoxFit.cover),
      );
    } else if (!track.isVideo && track.remoteArtUrl != null && track.remoteArtUrl!.isNotEmpty) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          track.remoteArtUrl!,
          width: 42,
          height: 42,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 42,
            height: 42,
            color: withA(acc, 0.25),
            child: Icon(Icons.music_note_rounded, color: acc, size: 22),
          ),
        ),
      );
    } else if (!track.isVideo && _hasLogoAsset) {
      thumb = Container(
        width: 42,
        height: 42,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Image.asset('assets/logo.png', fit: BoxFit.contain),
      );
    } else {
      thumb = Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: withA(acc, 0.25), borderRadius: BorderRadius.circular(12)),
        child: Icon(track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded, color: acc, size: 22),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: withA(Colors.black, dark ? 0.42 : 0.12),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openPlayerSheet,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? [
                            withA(Colors.white, 0.15),
                            withA(const Color(0xFF1A1A26), 0.72),
                            withA(acc, 0.18),
                          ]
                        : [
                            withA(Colors.white, 0.84),
                            withA(Colors.white, 0.62),
                            withA(acc, 0.12),
                          ],
                  ),
                  border: Border.all(
                    color: dark ? withA(Colors.white, 0.22) : withA(Colors.white, 0.90),
                    width: 1.1,
                  ),
                ),
                child: Row(
                  children: [
                    thumb,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text),
                          ),
                          Text(
                            track.isVideo ? 'Video - Toca para ver' : track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: _subtext),
                          ),
                        ],
                      ),
                    ),
                    _SpringPressButton(
                      onTap: _togglePlayPause,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.lerp(acc, Colors.white, 0.22) ?? acc,
                              acc,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(color: withA(acc, 0.40), blurRadius: 10),
                          ],
                        ),
                        child: _loadingOnlineTrack
                            ? const Padding(
                                padding: EdgeInsets.all(9),
                                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                              )
                            : Icon(
                                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 21,
                              ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _SpringPressButton(
                      onTap: _nextTrack,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dark ? withA(Colors.white, 0.10) : withA(Colors.black, 0.06),
                        ),
                        child: Icon(Icons.skip_next_rounded, color: _text, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Barra de navegacion inferior estilo LIQUID GLASS ---

  Widget _buildLiquidGlassBottomNav() {
    final dark = widget.darkMode;
    const items = [
      (0, Icons.music_note_rounded, 'Música'),
      (1, Icons.search_rounded, 'Buscar'),
      (2, Icons.video_library_rounded, 'Videos'),
      (3, Icons.lock_rounded, 'Privado'),
      (4, Icons.tune_rounded, 'Ajustes'),
    ];

    return Container(
      height: 68,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(34),
        boxShadow: [
          BoxShadow(
            color: withA(Colors.black, dark ? 0.50 : 0.14),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: withA(_accent, dark ? 0.16 : 0.10),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(34),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0.0, 0.45, 1.0],
                colors: dark
                    ? [
                        withA(Colors.white, 0.18),
                        withA(const Color(0xFF171722), 0.58),
                        withA(_accent, 0.14),
                      ]
                    : [
                        withA(Colors.white, 0.82),
                        withA(Colors.white, 0.52),
                        withA(_accent, 0.12),
                      ],
              ),
              border: Border.all(
                color: dark ? withA(Colors.white, 0.25) : withA(Colors.white, 0.92),
                width: 1.25,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const padH = 5.0;
                final innerW = constraints.maxWidth - (padH * 2);
                final tabW = innerW / items.length;

                return Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 24,
                      right: 24,
                      height: 1.5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              withA(Colors.white, dark ? 0.50 : 0.95),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      left: padH + (_activeTab * tabW),
                      top: 5,
                      bottom: 5,
                      width: tabW,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: dark
                                ? [withA(_accent, 0.40), withA(_accent, 0.18)]
                                : [withA(Colors.white, 0.90), withA(_accent, 0.20)],
                          ),
                          border: Border.all(
                            color: dark ? withA(Colors.white, 0.30) : withA(Colors.white, 0.95),
                            width: 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: withA(_accent, dark ? 0.30 : 0.18),
                              blurRadius: 14,
                              spreadRadius: -2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: padH),
                      child: Row(
                        children: items.map((it) {
                          final active = _activeTab == it.$1;
                          final activeColor = dark ? Colors.white : _accent;
                          final inactiveColor = dark ? withA(Colors.white, 0.62) : _subtext;

                          return Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (_activeTab != it.$1) {
                                  HapticFeedback.selectionClick();
                                  setState(() => _activeTab = it.$1);
                                }
                              },
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  AnimatedScale(
                                    scale: active ? 1.12 : 1.0,
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOutBack,
                                    child: Icon(
                                      it.$2,
                                      size: 22,
                                      color: active ? activeColor : inactiveColor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    it.$3,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                                      color: active ? activeColor : inactiveColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // --- Pantalla completa del Reproductor de Musica ---

  Widget _buildMusicPlayerSheet() {
    final track = _currentTrack!;
    final isFav = _favorites.contains(track.path);
    final acc = _playerAccent;
    final topSolid = blendSolid(acc, _bg, 0.34);
    final screenH = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    final stageSize = min(290.0, min(screenW * 0.70, screenH * 0.32));
    final dark = widget.darkMode;

    return GestureDetector(
      onVerticalDragUpdate: (details) {
        final delta = details.primaryDelta ?? 0;
        if (delta != 0) {
          _sheetController.value = (_sheetController.value - delta / screenH).clamp(0.0, 1.0);
        }
      },
      onVerticalDragEnd: (details) {
        final vel = details.primaryVelocity ?? 0;
        if (vel > 450 || _sheetController.value < 0.72) {
          _closePlayerSheet();
        } else {
          _openPlayerSheet();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 480),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: const Alignment(0, 0.76),
            colors: [topSolid, _bg],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Cabecera
                Column(
                  children: [
                    Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: withA(_text, 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildGlassCircleButton(
                          icon: Icons.keyboard_arrow_down_rounded,
                          size: 38,
                          iconSize: 25,
                          onTap: _closePlayerSheet,
                        ),
                        Column(
                          children: [
                            Text(
                              track.isOnline ? 'EN LÍNEA' : 'REPRODUCIENDO',
                              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: track.isOnline ? acc : _subtext),
                            ),
                            Text('relaxPlayer', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_sleepRemainingSec > 0)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Text(
                                  formatTime(Duration(seconds: _sleepRemainingSec)),
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: acc),
                                ),
                              ),
                            _buildGlassCircleButton(
                              icon: Icons.edit_rounded,
                              size: 38,
                              iconSize: 18,
                              onTap: () => _showEditTrackSheet(track),
                            ),
                            const SizedBox(width: 6),
                            _buildGlassCircleButton(
                              icon: Icons.bedtime_outlined,
                              size: 38,
                              iconSize: 19,
                              active: _sleepRemainingSec > 0,
                              onTap: _showSleepTimerDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),

                // Escenario central: Portada / Vinilo girando / Letras (desliza a los lados para cambiar cancion)
                GestureDetector(
                  onHorizontalDragEnd: (details) {
                    if (_showLyricsPanel) return;
                    final vel = details.primaryVelocity ?? 0;
                    if (vel < -240) {
                      HapticFeedback.lightImpact();
                      _nextTrack();
                    } else if (vel > 240) {
                      HapticFeedback.lightImpact();
                      _prevTrack();
                    }
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    child: _showLyricsPanel
                        ? KeyedSubtree(
                            key: const ValueKey('lyrics'),
                            child: _buildLyricsStage(track, stageSize),
                          )
                        : KeyedSubtree(
                            key: ValueKey('art_${_vinylMode}_${track.path}'),
                            child: _vinylMode
                                ? _buildVinylDisc(track, stageSize)
                                : _buildBigCover(track, stageSize),
                          ),
                  ),
                ),

                // Titulo, artista y acciones rapidas
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: _text),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: _subtext),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildGlassCircleButton(
                      icon: Icons.playlist_add_rounded,
                      size: 38,
                      iconSize: 20,
                      onTap: () => _showAddToPlaylistDialog(track.path),
                    ),
                    const SizedBox(width: 8),
                    _buildGlassCircleButton(
                      icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      size: 38,
                      iconSize: 19,
                      active: isFav,
                      onTap: () => _toggleFavorite(track.path, track: track),
                    ),
                  ],
                ),

                // Barra de progreso
                StreamBuilder<Duration>(
                  stream: _audioHandler.unifiedPositionStream,
                  builder: (context, posSnap) {
                    final dur = _audioPlayer.duration ?? Duration.zero;
                    final pos = posSnap.data ?? Duration.zero;
                    final maxSec = max(1.0, dur.inMilliseconds / 1000.0);
                    final curSec = (_draggingSeekSec ?? (pos.inMilliseconds / 1000.0)).clamp(0.0, maxSec);

                    return Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4.5,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
                            activeTrackColor: acc,
                            inactiveTrackColor: dark ? withA(Colors.white, 0.14) : _border,
                            thumbColor: Colors.white,
                            overlayColor: withA(acc, 0.24),
                          ),
                          child: Slider(
                            min: 0.0,
                            max: maxSec,
                            value: curSec,
                            onChanged: (v) => setState(() => _draggingSeekSec = v),
                            onChangeEnd: (v) async {
                              await _audioHandler.seek(Duration(milliseconds: (v * 1000).round()));
                              if (mounted) setState(() => _draggingSeekSec = null);
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                formatTime(Duration(milliseconds: (curSec * 1000).round())),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
                              ),
                              Text(
                                formatTime(dur),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),

                // Controles principales
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildGlassCircleButton(
                      icon: Icons.shuffle_rounded,
                      size: 42,
                      iconSize: 20,
                      active: _shuffle,
                      showActiveDot: true,
                      onTap: () {
                        setState(() => _shuffle = !_shuffle);
                        _showSnack(_shuffle ? 'Modo aleatorio activado.' : 'Modo aleatorio desactivado.');
                      },
                    ),
                    _buildGlassCircleButton(
                      icon: Icons.skip_previous_rounded,
                      size: 52,
                      iconSize: 28,
                      onTap: _prevTrack,
                    ),
                    _buildHeroPlayPauseOrb(size: 72, iconSize: 38),
                    _buildGlassCircleButton(
                      icon: Icons.skip_next_rounded,
                      size: 52,
                      iconSize: 28,
                      onTap: _nextTrack,
                    ),
                    _buildGlassCircleButton(
                      icon: Icons.repeat_rounded,
                      size: 42,
                      iconSize: 20,
                      active: _repeat,
                      showActiveDot: true,
                      onTap: () {
                        setState(() => _repeat = !_repeat);
                        _audioHandler.setRepeatOne(_repeat);
                        _showSnack(_repeat ? 'Repetir canción activado.' : 'Repetir canción desactivado.');
                      },
                    ),
                  ],
                ),

                // Barra de herramientas rapidas: Ecualizador, Vinilo, Letra, Cola
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildPlayerToolChip(
                      icon: Icons.equalizer_rounded,
                      label: 'EQ',
                      active: _eqEnabled,
                      onTap: _showEqualizerSheet,
                    ),
                    _buildPlayerToolChip(
                      icon: Icons.album_rounded,
                      label: 'Vinilo',
                      active: _vinylMode && !_showLyricsPanel,
                      onTap: () {
                        setState(() {
                          _showLyricsPanel = false;
                          _vinylMode = !_vinylMode;
                        });
                        _syncVinylAnimation();
                        _savePrefs();
                      },
                    ),
                    _buildPlayerToolChip(
                      icon: Icons.lyrics_rounded,
                      label: 'Letra',
                      active: _showLyricsPanel,
                      onTap: () => setState(() => _showLyricsPanel = !_showLyricsPanel),
                    ),
                    _buildPlayerToolChip(
                      icon: Icons.queue_music_rounded,
                      label: 'Cola',
                      active: false,
                      onTap: _showQueueBottomSheet,
                    ),
                  ],
                ),

                // Capsula cristalina de velocidad + volumen en vivo
                Container(
                  padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? [withA(Colors.white, 0.10), withA(Colors.white, 0.03)]
                          : [withA(Colors.white, 0.85), withA(Colors.white, 0.55)],
                    ),
                    border: Border.all(
                      color: dark ? withA(Colors.white, 0.14) : withA(Colors.black, 0.06),
                    ),
                  ),
                  child: Row(
                    children: [
                      _SpringPressButton(
                        onTap: _showSpeedDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: withA(acc, dark ? 0.22 : 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: withA(acc, 0.35)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.speed_rounded, size: 14, color: acc),
                              const SizedBox(width: 4),
                              Text(
                                '${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}x',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _text),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _volume <= 0.01 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        size: 18,
                        color: _subtext,
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                            activeTrackColor: acc,
                            inactiveTrackColor: dark ? withA(Colors.white, 0.14) : _border,
                            thumbColor: acc,
                          ),
                          child: Slider(
                            min: 0.0,
                            max: 1.0,
                            value: _volume,
                            onChanged: (v) {
                              setState(() => _volume = v);
                              _audioHandler.setVolumeLive(v);
                            },
                            onChangeEnd: (_) => _savePrefs(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(_volume * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerToolChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final dark = widget.darkMode;
    final acc = _playerAccent;
    final fg = active ? (dark ? Colors.white : acc) : _subtext;

    return _SpringPressButton(
      onTap: onTap,
      pressedScale: 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: active
              ? withA(acc, dark ? 0.30 : 0.18)
              : (dark ? withA(Colors.white, 0.08) : withA(Colors.black, 0.05)),
          border: Border.all(
            color: active
                ? withA(acc, 0.55)
                : (dark ? withA(Colors.white, 0.12) : withA(Colors.black, 0.06)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
            ),
          ],
        ),
      ),
    );
  }

  // --- Reproductor de Video con pantalla completa, doble toque (-10s/+10s) y brillo/volumen al deslizar ---

  Widget _buildVideoGestureSurface(VideoPlayerController? vc, bool initialized) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = max(1.0, constraints.maxWidth);
        final h = max(1.0, constraints.maxHeight);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _videoTapDownX = d.localPosition.dx,
          onTap: () {
            if (_videoFullscreen) {
              setState(() => _videoControlsVisible = !_videoControlsVisible);
              if (_videoControlsVisible) _scheduleHideVideoControls();
            } else {
              _togglePlayPause();
            }
          },
          onDoubleTapDown: (d) => _videoTapDownX = d.localPosition.dx,
          onDoubleTap: () {
            if (!initialized || vc == null) return;
            if (_videoTapDownX < w * 0.42) {
              final target = vc.value.position - const Duration(seconds: 10);
              vc.seekTo(target < Duration.zero ? Duration.zero : target);
              HapticFeedback.lightImpact();
              _showVideoHud(Icons.replay_10_rounded, '-10 s');
            } else if (_videoTapDownX > w * 0.58) {
              final target = vc.value.position + const Duration(seconds: 10);
              vc.seekTo(target > vc.value.duration ? vc.value.duration : target);
              HapticFeedback.lightImpact();
              _showVideoHud(Icons.forward_10_rounded, '+10 s');
            } else {
              _togglePlayPause();
            }
          },
          onVerticalDragStart: (d) {
            _videoDragMode = d.localPosition.dx < (w * 0.5) ? 'brightness' : 'volume';
          },
          onVerticalDragUpdate: (d) {
            final delta = -(d.primaryDelta ?? 0) / max(140.0, h * 0.65);
            if (_videoDragMode == 'brightness') {
              final next = (_videoBrightness + delta).clamp(0.15, 1.0);
              setState(() => _videoBrightness = next);
              _showVideoHud(Icons.brightness_6_rounded, 'Brillo ${(next * 100).round()}%');
            } else if (_videoDragMode == 'volume') {
              final next = (_volume + delta).clamp(0.0, 1.0);
              setState(() => _volume = next);
              vc?.setVolume(next);
              _showVideoHud(
                next <= 0.01 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                'Volumen ${(next * 100).round()}%',
              );
            }
          },
          onVerticalDragEnd: (_) {
            if (_videoDragMode == 'volume') _savePrefs();
            _videoDragMode = '';
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: w,
                height: h,
                color: Colors.black,
                alignment: Alignment.center,
                child: initialized && vc != null
                    ? AspectRatio(
                        aspectRatio: vc.value.aspectRatio > 0 ? vc.value.aspectRatio : 16 / 9,
                        child: VideoPlayer(vc),
                      )
                    : CircularProgressIndicator(color: _accent),
              ),
              // Filtro suave de brillo al deslizar el lado izquierdo
              if (_videoBrightness < 0.99)
                IgnorePointer(
                  child: Container(
                    color: withA(Colors.black, (1.0 - _videoBrightness).clamp(0.0, 0.85)),
                  ),
                ),
              // HUD flotante cristalino para gestos (-10s, +10s, Brillo, Volumen)
              if (_videoHudLabel != null && _videoHudIcon != null)
                IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                        decoration: BoxDecoration(
                          color: withA(Colors.black, 0.58),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: withA(Colors.white, 0.25)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_videoHudIcon, color: Colors.white, size: 22),
                            const SizedBox(width: 8),
                            Text(
                              _videoHudLabel!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVideoPlayerSheet() {
    final track = _currentTrack!;
    final isFav = _favorites.contains(track.path);
    final vc = _videoController;
    final initialized = vc != null && vc.value.isInitialized;

    // Modo pantalla completa horizontal inmersiva
    if (_videoFullscreen) {
      return Container(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: _buildVideoGestureSurface(vc, initialized)),
            if (_videoControlsVisible)
              Positioned(
                top: 12,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    _buildGlassCircleButton(
                      icon: Icons.fullscreen_exit_rounded,
                      size: 40,
                      iconSize: 22,
                      accentOverride: _accent,
                      onTap: _exitVideoFullscreen,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            if (_videoControlsVisible)
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (initialized)
                      VideoProgressIndicator(
                        vc,
                        allowScrubbing: true,
                        colors: VideoProgressColors(
                          playedColor: _accent,
                          bufferedColor: withA(_accent, 0.35),
                          backgroundColor: withA(Colors.white, 0.25),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildGlassCircleButton(
                          icon: Icons.skip_previous_rounded,
                          size: 42,
                          iconSize: 24,
                          accentOverride: _accent,
                          onTap: _prevTrack,
                        ),
                        const SizedBox(width: 16),
                        _buildHeroPlayPauseOrb(size: 56, iconSize: 30, accentOverride: _accent),
                        const SizedBox(width: 16),
                        _buildGlassCircleButton(
                          icon: Icons.skip_next_rounded,
                          size: 42,
                          iconSize: 24,
                          accentOverride: _accent,
                          onTap: _nextTrack,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // Modo vertical normal con gestos y boton de pantalla completa
    return SafeArea(
      child: Container(
        color: _bg,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(
          children: [
            Row(
              children: [
                _buildGlassCircleButton(
                  icon: Icons.arrow_back_rounded,
                  size: 40,
                  iconSize: 22,
                  accentOverride: _accent,
                  onTap: _closePlayerSheet,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text),
                  ),
                ),
                _buildGlassCircleButton(
                  icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 40,
                  iconSize: 20,
                  active: isFav,
                  accentOverride: _accent,
                  onTap: () => _toggleFavorite(track.path),
                ),
                const SizedBox(width: 8),
                _buildGlassCircleButton(
                  icon: Icons.fullscreen_rounded,
                  size: 40,
                  iconSize: 22,
                  accentOverride: _accent,
                  onTap: _enterVideoFullscreen,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: _buildVideoGestureSurface(vc, initialized),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Doble toque a los lados: -10s / +10s   |   Desliza: Brillo (izq) y Volumen (der)',
              style: TextStyle(fontSize: 10, color: _subtext),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (initialized)
              VideoProgressIndicator(
                vc,
                allowScrubbing: true,
                colors: VideoProgressColors(
                  playedColor: _accent,
                  bufferedColor: withA(_accent, 0.3),
                  backgroundColor: _border,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildGlassCircleButton(
                  icon: Icons.skip_previous_rounded,
                  size: 46,
                  iconSize: 26,
                  accentOverride: _accent,
                  onTap: _prevTrack,
                ),
                _buildGlassCircleButton(
                  icon: Icons.replay_10_rounded,
                  size: 42,
                  iconSize: 22,
                  accentOverride: _accent,
                  onTap: () {
                    if (!initialized) return;
                    final target = vc.value.position - const Duration(seconds: 10);
                    vc.seekTo(target < Duration.zero ? Duration.zero : target);
                  },
                ),
                _buildHeroPlayPauseOrb(size: 64, iconSize: 34, accentOverride: _accent),
                _buildGlassCircleButton(
                  icon: Icons.forward_10_rounded,
                  size: 42,
                  iconSize: 22,
                  accentOverride: _accent,
                  onTap: () {
                    if (!initialized) return;
                    final target = vc.value.position + const Duration(seconds: 10);
                    vc.seekTo(target > vc.value.duration ? vc.value.duration : target);
                  },
                ),
                _buildGlassCircleButton(
                  icon: Icons.skip_next_rounded,
                  size: 46,
                  iconSize: 26,
                  accentOverride: _accent,
                  onTap: _nextTrack,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.volume_down_rounded, size: 19, color: _subtext),
                Expanded(
                  child: Slider(
                    min: 0.0,
                    max: 1.0,
                    value: _volume,
                    activeColor: _accent,
                    inactiveColor: _border,
                    onChanged: (v) {
                      setState(() => _volume = v);
                      vc?.setVolume(v);
                    },
                    onChangeEnd: (_) => _savePrefs(),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(_volume * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
