import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

late final RelaxAudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _audioHandler = await AudioService.init(
    builder: () => RelaxAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.relaxplayer.channel.audio',
      androidNotificationChannelName: 'relaxPlayer',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationClickStartsActivity: true,
    ),
  );
  runApp(const RelaxPlayerApp());
}

// --- Servicio de audio nativo con controles completos en barra de notificaciones ---

class RelaxAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();

  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;
  Future<void> Function()? onTrackCompleted;

  bool _completionSent = false;

  RelaxAudioHandler() {
    player.playbackEventStream.listen(_broadcastState);
    player.playingStream.listen((_) => _broadcastState(player.playbackEvent));
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (!_completionSent) {
          _completionSent = true;
          onTrackCompleted?.call();
        }
      } else if (state == ProcessingState.ready) {
        _completionSent = false;
      }
      _broadcastState(player.playbackEvent);
    });
    player.durationStream.listen((dur) {
      final current = mediaItem.value;
      if (current != null && dur != null && dur > Duration.zero && current.duration != dur) {
        mediaItem.add(current.copyWith(duration: dur));
      }
    });
  }

  Future<void> playMediaTrack({
    required String path,
    required String title,
    required String artist,
    required String album,
    Uri? artUri,
    required double volume,
    required double speed,
    required bool repeatOne,
  }) async {
    _completionSent = false;
    mediaItem.add(
      MediaItem(
        id: path,
        title: title,
        artist: artist,
        album: album,
        artUri: artUri,
      ),
    );
    final dur = await player.setFilePath(path);
    if (dur != null && dur > Duration.zero) {
      final current = mediaItem.value;
      if (current != null && current.id == path) {
        mediaItem.add(current.copyWith(duration: dur));
      }
    }
    await player.setVolume(volume);
    await player.setSpeed(speed);
    await player.setLoopMode(repeatOne ? LoopMode.one : LoopMode.off);
    _broadcastState(player.playbackEvent);
    await player.play();
    _broadcastState(player.playbackEvent);
  }

  void updateCurrentArtwork(String path, {String? title, String? artist, Uri? artUri}) {
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

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
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
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
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
        processingState: stateMap[player.processingState] ?? AudioProcessingState.idle,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: 0,
      ),
    );
  }

  @override
  Future<void> play() async {
    await player.play();
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> pause() async {
    await player.pause();
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
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

const List<double> kSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
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
  });
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
    with SingleTickerProviderStateMixin {
  AudioPlayer get _audioPlayer => _audioHandler.player;
  VideoPlayerController? _videoController;

  late final AnimationController _sheetController;
  final TextEditingController _musicSearchCtrl = TextEditingController();
  final TextEditingController _videoSearchCtrl = TextEditingController();
  final TextEditingController _pinCtrl = TextEditingController();
  final TextEditingController _newPinCtrl = TextEditingController();

  List<MediaTrack> _allTracks = [];
  List<MediaTrack> _activeAudioQueue = [];
  List<MediaTrack> _activeVideoQueue = [];

  MediaTrack? _currentTrack;
  bool _isPlaying = false;
  bool _scanning = false;
  bool _hasLogoAsset = false;
  Uri? _defaultLogoUri;
  String _cacheDir = '';

  int _activeTab = 0; // 0: Musica, 1: Videos, 2: Privado, 3: Ajustes
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

  String _pin = '1234';
  Set<String> _favorites = {};
  Set<String> _privatePaths = {};
  Map<String, List<String>> _playlists = {};
  int _totalPlays = 0;
  Map<String, int> _dailySeconds = {for (final d in kWeekDays) d: 0};

  int _sleepRemainingSec = 0;
  Timer? _clockTimer;
  int _statsAccumSec = 0;
  double? _draggingSeekSec;

  StreamSubscription<PlayerState>? _playerStateSub;
  final Random _rng = Random();

  Color get _bg => widget.darkMode ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F8);
  Color get _surface => widget.darkMode ? const Color(0xFF15151C) : const Color(0xFFFFFFFF);
  Color get _surfaceAlt => widget.darkMode ? const Color(0xFF1E1E28) : const Color(0xFFEAEAF0);
  Color get _text => widget.darkMode ? const Color(0xFFF6F6F9) : const Color(0xFF111118);
  Color get _subtext => widget.darkMode ? const Color(0xFF9E9EAA) : const Color(0xFF5D5D6B);
  Color get _border => widget.darkMode ? const Color(0xFF282836) : const Color(0xFFDCDCE6);
  Color get _accent => kAccentThemes[widget.accentName] ?? const Color(0xFF9B5DE5);

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
    _initEverything();
  }

  Future<void> _initEverything() async {
    final tmp = await getTemporaryDirectory();
    _cacheDir = tmp.path;
    await _prepareLogoAsset();
    await _loadPrefs();
    _bindAudioStreams();
    _startClockTimer();
    await _scanDeviceMedia(showToast: false);
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
    final privList = prefs.getStringList('private_paths') ?? [];
    final plRaw = prefs.getString('playlists');
    final dailyRaw = prefs.getString('daily_seconds');

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

    if (!mounted) return;
    setState(() {
      _pin = prefs.getString('pin') ?? '1234';
      _volume = prefs.getDouble('volume') ?? 0.85;
      _favorites = favList.toSet();
      _privatePaths = privList.toSet();
      _playlists = parsedPl;
      _totalPlays = prefs.getInt('total_plays') ?? 0;
      _dailySeconds = parsedDaily;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', widget.darkMode);
    await prefs.setString('accent', widget.accentName);
    await prefs.setString('pin', _pin);
    await prefs.setDouble('volume', _volume);
    await prefs.setStringList('favorites', _favorites.toList());
    await prefs.setStringList('private_paths', _privatePaths.toList());
    await prefs.setString('playlists', jsonEncode(_playlists));
    await prefs.setInt('total_plays', _totalPlays);
    await prefs.setString('daily_seconds', jsonEncode(_dailySeconds));
  }

  void _bindAudioStreams() {
    // Conectar botones Siguiente / Anterior / Fin de pista de la notificacion
    _audioHandler.onSkipNext = () async {
      await _nextTrack();
    };
    _audioHandler.onSkipPrevious = () async {
      await _prevTrack();
    };
    _audioHandler.onTrackCompleted = () async {
      await _nextTrack();
    };

    _playerStateSub = _audioPlayer.playerStateStream.listen((st) {
      if (!mounted) return;
      if (_currentTrack != null && !_currentTrack!.isVideo) {
        if (_isPlaying != st.playing) {
          setState(() => _isPlaying = st.playing);
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
    _clockTimer?.cancel();
    _playerStateSub?.cancel();
    _audioHandler.onSkipNext = null;
    _audioHandler.onSkipPrevious = null;
    _audioHandler.onTrackCompleted = null;
    _videoController?.dispose();
    _sheetController.dispose();
    _musicSearchCtrl.dispose();
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

  // --- Permisos y escaneo automatico ---

  Future<void> _requestAndroidPermissions() async {
    if (!Platform.isAndroid) return;
    await Permission.notification.request();
    await Permission.audio.request();
    await Permission.videos.request();
    await Permission.storage.request();
  }

  Future<void> _scanDeviceMedia({bool showToast = true}) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    if (showToast) _showSnack('Actualizando música y videos...');

    await _requestAndroidPermissions();

    List<MediaTrack> found = await _walkMediaDirectories();

    if (found.isEmpty && Platform.isAndroid) {
      final manageStatus = await Permission.manageExternalStorage.status;
      if (!manageStatus.isGranted) {
        await Permission.manageExternalStorage.request();
        found = await _walkMediaDirectories();
      }
    }

    if (!mounted) return;
    setState(() {
      _allTracks = found;
      _scanning = false;
    });

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

  List<MediaTrack> _filteredList(bool isVideo) {
    final filter = isVideo ? _videoFilter : _musicFilter;
    final query = (isVideo ? _videoQuery : _musicQuery).trim().toLowerCase();
    final sort = isVideo ? _videoSort : _musicSort;

    List<MediaTrack> base;
    if (!isVideo && filter.startsWith('PL::')) {
      final plName = filter.substring(4);
      final paths = _playlists[plName] ?? [];
      final byPath = {for (final t in _getList(isVideo: false, onlyPrivate: false)) t.path: t};
      base = [for (final p in paths) if (byPath.containsKey(p)) byPath[p]!];
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

  // --- Reproduccion de audio (con controles completos en notificacion) y video ---

  Future<void> _playTrack(MediaTrack track, List<MediaTrack> queue, {bool openSheet = true}) async {
    _totalPlays++;
    _savePrefs();

    if (track.isVideo) {
      await _audioHandler.pause();
      await _disposeVideo();
      _activeVideoQueue = List<MediaTrack>.from(queue.isEmpty ? [track] : queue);
      setState(() {
        _currentTrack = track;
        _isPlaying = true;
      });
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
          } else {
            setState(() => _isPlaying = val.isPlaying);
          }
        });
        if (mounted) setState(() => _isPlaying = true);
      } catch (_) {
        _showSnack('No se pudo abrir este video.');
      }
      return;
    }

    // Audio nativo con controles Anterior / Play-Pausa / Siguiente en la notificacion
    await _disposeVideo();
    await Id3Reader.loadTrackMetadata(track, _cacheDir);

    final validQueue = queue.isEmpty ? [track] : List<MediaTrack>.from(queue);
    _activeAudioQueue = validQueue;

    if (mounted) {
      setState(() {
        _currentTrack = track;
        _isPlaying = true;
        _draggingSeekSec = null;
      });
    }
    if (openSheet) _openPlayerSheet();

    try {
      final Uri? art = (track.coverPath != null && File(track.coverPath!).existsSync())
          ? Uri.file(track.coverPath!)
          : _defaultLogoUri;

      await _audioHandler.playMediaTrack(
        path: track.path,
        title: track.title,
        artist: track.artist,
        album: track.folder,
        artUri: art,
        volume: _volume,
        speed: _speed,
        repeatOne: _repeat,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _isPlaying = false);
        _showSnack('No se pudo reproducir este archivo.');
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
    if (mounted) setState(() => _isPlaying = false);
  }

  Future<void> _togglePlayPause() async {
    if (_currentTrack == null) {
      final list = _filteredList(_activeTab == 1);
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

  Future<void> _nextTrack() async {
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
    await _playTrack(_activeAudioQueue[nextIdx], _activeAudioQueue, openSheet: keepSheet);
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

  // --- Animacion fluida 60 FPS al subir y bajar ---

  void _openPlayerSheet() {
    if (_currentTrack == null) return;
    _sheetController.animateTo(1.0, curve: Curves.easeOutCubic);
  }

  void _closePlayerSheet() {
    if (_currentTrack != null && _currentTrack!.isVideo) {
      _videoController?.pause();
      setState(() => _isPlaying = false);
    }
    _sheetController.animateBack(0.0, curve: Curves.easeInOutCubic);
  }

  // --- Favoritos, playlists, velocidad, temporizador ---

  void _toggleFavorite(String path) {
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
                  color: active ? _accent : _text,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: active ? Icon(Icons.check_rounded, color: _accent) : null,
              onTap: () {
                setState(() => _speed = s);
                _audioPlayer.setSpeed(s);
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

  // --- Logo y Portada ---

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

  Widget _buildBigCover(MediaTrack? track, double size) {
    final coverFile = (track?.coverPath != null) ? File(track!.coverPath!) : null;
    if (coverFile != null && coverFile.existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.file(
          coverFile,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    if (_hasLogoAsset) {
      return Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.08),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.contain,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _surfaceAlt,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: withA(_accent, 0.35)),
      ),
      child: Icon(Icons.headphones_rounded, size: size * 0.36, color: _accent),
    );
  }

  // --- Construccion Principal con Dock Liquid Glass flotando sobre la lista ---

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return AnimatedBuilder(
      animation: _sheetController,
      builder: (context, _) {
        final sheetOpen = _sheetController.value > 0.01;
        return PopScope(
          canPop: !sheetOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && sheetOpen) {
              _closePlayerSheet();
            }
          },
          child: Scaffold(
            backgroundColor: _bg,
            body: Stack(
              children: [
                // Capa 1: Contenido a pantalla completa (las canciones pasan detras del vidrio liquido)
                SafeArea(
                  bottom: false,
                  child: _buildActiveTabBody(),
                ),

                // Capa 2: Mini reproductor esmerilado + Barra inferior estilo Liquid Glass flotante
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

                // Capa 3: Reproductor pantalla completa (100% opaco, subida y bajada fluida)
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
        return _buildMediaListTab(isVideo: true);
      case 2:
        return _buildPrivateTab();
      default:
        return _buildSettingsTab();
    }
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
                '${tracks.length} ${isVideo ? 'videos' : 'canciones'}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _subtext),
              ),
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
                            _scanning
                                ? 'Buscando archivos...'
                                : 'No encontré ${isVideo ? 'videos' : 'canciones'}',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'relaxPlayer lee automáticamente tu Música, Descargas y Videos.',
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
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: isCurrent ? withA(_accent, 0.16) : _surface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _playTrack(t, tracks, openSheet: true),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Row(
                                children: [
                                  Container(
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
                                          '${t.folder} / ${t.ext}',
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
                                    icon: Icon(Icons.lock_outline_rounded, size: 19, color: _subtext),
                                    onPressed: () => _moveToPrivate(t.path),
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
              const SizedBox(height: 8),
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

  // --- Mini Reproductor con efecto cristal a juego ---

  Widget _buildMiniPlayerGlass() {
    final track = _currentTrack!;
    final coverFile = (track.coverPath != null) ? File(track.coverPath!) : null;
    final dark = widget.darkMode;

    Widget thumb;
    if (coverFile != null && coverFile.existsSync()) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(coverFile, width: 42, height: 42, fit: BoxFit.cover),
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
        decoration: BoxDecoration(color: withA(_accent, 0.25), borderRadius: BorderRadius.circular(12)),
        child: Icon(track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded, color: _accent, size: 22),
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
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openPlayerSheet,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? [
                            withA(Colors.white, 0.15),
                            withA(const Color(0xFF1A1A26), 0.72),
                            withA(_accent, 0.16),
                          ]
                        : [
                            withA(Colors.white, 0.84),
                            withA(Colors.white, 0.62),
                            withA(_accent, 0.12),
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
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: _text, size: 26),
                      onPressed: _togglePlayPause,
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next_rounded, color: _subtext, size: 24),
                      onPressed: _nextTrack,
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

  // --- Barra de navegacion inferior estilo LIQUID GLASS (capsula flotante + gota deslizante) ---

  Widget _buildLiquidGlassBottomNav() {
    final dark = widget.darkMode;
    const items = [
      (0, Icons.music_note_rounded, 'Música'),
      (1, Icons.video_library_rounded, 'Videos'),
      (2, Icons.lock_rounded, 'Privado'),
      (3, Icons.tune_rounded, 'Ajustes'),
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
          filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
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
                    // Brillo especular superior que simula la curvatura del vidrio liquido
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

                    // Gota / burbuja de vidrio liquido que se desliza suavemente entre pestanas
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
                                ? [
                                    withA(_accent, 0.40),
                                    withA(_accent, 0.18),
                                  ]
                                : [
                                    withA(Colors.white, 0.90),
                                    withA(_accent, 0.20),
                                  ],
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

                    // Botones de navegacion
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

  // --- Pantalla completa del Reproductor de Musica (100% opaca + deslizamiento interactivo) ---

  Widget _buildMusicPlayerSheet() {
    final track = _currentTrack!;
    final isFav = _favorites.contains(track.path);
    final topSolid = blendSolid(_accent, _bg, 0.30);
    final screenH = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    final coverSize = min(310.0, min(screenW * 0.74, screenH * 0.35));

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
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: const Alignment(0, 0.72),
            colors: [topSolid, _bg],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
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
                        IconButton(
                          icon: Icon(Icons.keyboard_arrow_down_rounded, size: 30, color: _text),
                          onPressed: _closePlayerSheet,
                        ),
                        Column(
                          children: [
                            Text('REPRODUCIENDO', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: _subtext)),
                            Text('relaxPlayer', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_sleepRemainingSec > 0)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  formatTime(Duration(seconds: _sleepRemainingSec)),
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _accent),
                                ),
                              ),
                            IconButton(
                              icon: Icon(
                                Icons.bedtime_outlined,
                                size: 22,
                                color: _sleepRemainingSec > 0 ? _accent : _subtext,
                              ),
                              onPressed: _showSleepTimerDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),

                _buildBigCover(track, coverSize),

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
                    IconButton(
                      icon: Icon(Icons.playlist_add_rounded, size: 24, color: _subtext),
                      onPressed: () => _showAddToPlaylistDialog(track.path),
                    ),
                    IconButton(
                      icon: Icon(
                        isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        size: 24,
                        color: isFav ? _accent : _subtext,
                      ),
                      onPressed: () => _toggleFavorite(track.path),
                    ),
                  ],
                ),

                StreamBuilder<Duration>(
                  stream: _audioPlayer.positionStream,
                  builder: (context, posSnap) {
                    final dur = _audioPlayer.duration ?? Duration.zero;
                    final pos = posSnap.data ?? Duration.zero;
                    final maxSec = max(1.0, dur.inMilliseconds / 1000.0);
                    final curSec = (_draggingSeekSec ?? (pos.inMilliseconds / 1000.0)).clamp(0.0, maxSec);

                    return Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                            activeTrackColor: _accent,
                            inactiveTrackColor: _border,
                            thumbColor: _text,
                            overlayColor: withA(_accent, 0.2),
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

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: Icon(Icons.shuffle_rounded, size: 23, color: _shuffle ? _accent : _subtext),
                      onPressed: () {
                        setState(() => _shuffle = !_shuffle);
                        _showSnack(_shuffle ? 'Modo aleatorio activado.' : 'Modo aleatorio desactivado.');
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_previous_rounded, size: 36, color: _text),
                      onPressed: _prevTrack,
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(34),
                      onTap: _togglePlayPause,
                      child: Container(
                        width: 66,
                        height: 66,
                        decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
                        child: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next_rounded, size: 36, color: _text),
                      onPressed: _nextTrack,
                    ),
                    IconButton(
                      icon: Icon(Icons.repeat_rounded, size: 23, color: _repeat ? _accent : _subtext),
                      onPressed: () {
                        setState(() => _repeat = !_repeat);
                        _audioPlayer.setLoopMode(_repeat ? LoopMode.one : LoopMode.off);
                        _showSnack(_repeat ? 'Repetir canción activado.' : 'Repetir canción desactivado.');
                      },
                    ),
                  ],
                ),

                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _showSpeedDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _surfaceAlt,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.speed_rounded, size: 14, color: _accent),
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
                    Icon(Icons.volume_down_rounded, size: 19, color: _subtext),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          activeTrackColor: _accent,
                          inactiveTrackColor: _border,
                          thumbColor: _accent,
                        ),
                        child: Slider(
                          min: 0.0,
                          max: 1.0,
                          value: _volume,
                          onChanged: (v) {
                            setState(() => _volume = v);
                            _audioPlayer.setVolume(v);
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Reproductor de Video integrado ---

  Widget _buildVideoPlayerSheet() {
    final track = _currentTrack!;
    final isFav = _favorites.contains(track.path);
    final vc = _videoController;
    final initialized = vc != null && vc.value.isInitialized;

    return SafeArea(
      child: Container(
        color: _bg,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_rounded, color: _text),
                  onPressed: _closePlayerSheet,
                ),
                Expanded(
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: isFav ? _accent : _subtext,
                  ),
                  onPressed: () => _toggleFavorite(track.path),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: initialized
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AspectRatio(
                          aspectRatio: vc.value.aspectRatio > 0 ? vc.value.aspectRatio : 16 / 9,
                          child: VideoPlayer(vc),
                        ),
                      )
                    : CircularProgressIndicator(color: _accent),
              ),
            ),
            const SizedBox(height: 10),
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
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(Icons.skip_previous_rounded, size: 32, color: _text),
                  onPressed: _prevTrack,
                ),
                IconButton(
                  icon: Icon(Icons.replay_10_rounded, size: 28, color: _subtext),
                  onPressed: () {
                    if (!initialized) return;
                    final target = vc.value.position - const Duration(seconds: 10);
                    vc.seekTo(target < Duration.zero ? Duration.zero : target);
                  },
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
                    child: Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.forward_10_rounded, size: 28, color: _subtext),
                  onPressed: () {
                    if (!initialized) return;
                    final target = vc.value.position + const Duration(seconds: 10);
                    vc.seekTo(target > vc.value.duration ? vc.value.duration : target);
                  },
                ),
                IconButton(
                  icon: Icon(Icons.skip_next_rounded, size: 32, color: _text),
                  onPressed: _nextTrack,
                ),
              ],
            ),
            const SizedBox(height: 6),
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
