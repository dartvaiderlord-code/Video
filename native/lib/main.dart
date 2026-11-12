import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TavernApp());
}

const gold = Color(0xffe5b866);

class TavernApp extends StatelessWidget {
  const TavernApp({super.key, this.initialHostMode});
  final bool? initialHostMode;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Пиратский трактир',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff171412),
      colorScheme: ColorScheme.fromSeed(
        seedColor: gold,
        brightness: Brightness.dark,
        primary: gold,
        surface: const Color(0xff282018),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
      useMaterial3: true,
    ),
    home: TavernHome(initialHostMode: initialHostMode),
  );
}

class TavernHome extends StatefulWidget {
  const TavernHome({super.key, this.initialHostMode});
  final bool? initialHostMode;
  @override
  State<TavernHome> createState() => _TavernHomeState();
}

class _TavernHomeState extends State<TavernHome> with WidgetsBindingObserver {
  final session = TavernSession();
  final server = TextEditingController();
  final invite = TextEditingController();
  final code = TextEditingController();
  late bool hostMode = widget.initialHostMode ?? Platform.isWindows;
  bool working = false;
  int height = 1080, fps = 60, bitrate = 20;
  String codec = 'H264';
  bool keepResolution = true;
  List<DesktopCapturerSource> sources = [];
  DesktopCapturerSource? source;
  final Map<String, String> certificates = {};
  bool get locked => working || session.busy || session.connected;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_update);
    unawaited(_load());
  }

  void _update() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    server.text = prefs.getString('server') ?? '';
    final saved = prefs.getString('trustedCaByOrigin');
    if (saved != null) {
      try {
        certificates.addAll(Map<String, String>.from(jsonDecode(saved) as Map));
      } catch (_) {
        /* Ignore corrupt local preferences. */
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Do not leave a capture session running after the app is detached.
    if (state == AppLifecycleState.detached) unawaited(session.stop());
  }

  Uri _endpoint() => hostMode
      ? serverOrigin(server.text)
      : RoomInvite.parse(invite.text).server;
  Uint8List? _ca(Uri origin) => certificates[origin.origin] == null
      ? null
      : base64Decode(certificates[origin.origin]!);
  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _importCa() async {
    try {
      final endpoint = _endpoint();
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['crt', 'pem'],
        withData: true,
      );
      if (picked == null) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null) {
        throw const FormatException('Не удалось прочитать файл сертификата.');
      }
      final fingerprint = certificateFingerprint(bytes);
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Доверять сертификатам этого CA?'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Только для подключения к ${endpoint.origin}. Сверьте SHA-256 с владельцем сервера. Импортируйте root.crt, не ключ CA.',
                ),
                const SizedBox(height: 16),
                SelectableText(fingerprint),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Доверять'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      certificates[endpoint.origin] = base64Encode(bytes);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('trustedCaByOrigin', jsonEncode(certificates));
      _update();
      _message('Корневой сертификат сохранён для ${endpoint.origin}.');
    } catch (e) {
      _message(e.toString());
    }
  }

  Future<void> _forgetCa() async {
    try {
      certificates.remove(_endpoint().origin);
      await (await SharedPreferences.getInstance()).setString(
        'trustedCaByOrigin',
        jsonEncode(certificates),
      );
      _update();
      _message('Дополнительное доверие удалено.');
    } catch (e) {
      _message(e.toString());
    }
  }

  Future<void> _refreshSources() async {
    setState(() => working = true);
    try {
      final list = await session.sources();
      if (mounted) {
        setState(() {
          sources = list;
          source = list.isEmpty ? null : list.first;
        });
      }
    } catch (e) {
      _message('Не удалось получить экраны: $e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _start() async {
    setState(() => working = true);
    try {
      final endpoint = _endpoint();
      validateRoomCode(code.text);
      if (hostMode && source == null) {
        throw const FormatException('Выберите экран или окно.');
      }
      await (await SharedPreferences.getInstance()).setString(
        'server',
        endpoint.origin,
      );
      if (hostMode) {
        await session.host(
          endpoint,
          code.text,
          source!,
          CaptureProfile(
            height: height,
            fps: fps,
            mbps: bitrate,
            codec: codec,
            keepResolution: keepResolution,
          ),
          _ca(endpoint),
        );
      } else {
        await session.watch(
          RoomInvite.parse(invite.text),
          code.text,
          _ca(endpoint),
        );
      }
    } catch (e) {
      _message(e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _message('Скопировано.');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_update);
    unawaited(session.shutdown());
    server.dispose();
    invite.dispose();
    code.dispose();
    super.dispose();
  }

  Widget _choice<T>(
    String label,
    T value,
    List<T> values,
    ValueChanged<T> changed, {
    String Function(T)? format,
  }) => SizedBox(
    width: 175,
    child: DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: values
          .map(
            (v) => DropdownMenuItem(
              value: v,
              child: Text(format?.call(v) ?? '$v'),
            ),
          )
          .toList(),
      onChanged: locked
          ? null
          : (v) {
              if (v != null) setState(() => changed(v));
            },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('🏴‍☠️ Пиратский трактир'),
      backgroundColor: const Color(0xff211b16),
    ),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'ОДИН ЭКРАН. ВСЯ КОМАНДА.',
                    style: TextStyle(color: gold, letterSpacing: 2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isWindows
                        ? 'Windows · экран и системный звук'
                        : 'Android · нативный просмотр',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  if (Platform.isWindows) ...[
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Капитан: передавать'),
                          icon: Icon(Icons.screen_share),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Зритель'),
                          icon: Icon(Icons.live_tv),
                        ),
                      ],
                      selected: {hostMode},
                      onSelectionChanged: locked
                          ? null
                          : (value) => setState(() => hostMode = value.first),
                    ),
                    const SizedBox(height: 20),
                  ],
                  TextField(
                    controller: hostMode ? server : invite,
                    enabled: !locked,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: hostMode
                          ? 'Адрес сервера'
                          : 'Полная ссылка приглашения',
                      hintText: hostMode
                          ? 'https://ваш-сервер:8443'
                          : 'https://…/#room=…&token=…',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: code,
                    enabled: !locked,
                    obscureText: true,
                    autocorrect: false,
                    maxLength: 64,
                    decoration: InputDecoration(
                      labelText: hostMode
                          ? 'Придумайте код комнаты'
                          : 'Код от капитана',
                      helperText:
                          '4–64 символа. Код не сохраняется на устройстве.',
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: locked ? null : _importCa,
                        icon: const Icon(Icons.verified_user_outlined),
                        label: const Text('Импорт root.crt для своего сервера'),
                      ),
                      TextButton(
                        onPressed: locked ? null : _forgetCa,
                        child: const Text('Удалить доверие к CA'),
                      ),
                    ],
                  ),
                  const Text(
                    'С обычным доверенным HTTPS-сертификатом импорт не нужен. Проверка TLS всегда включена.',
                    style: TextStyle(fontSize: 12, color: Color(0xffb7a68e)),
                  ),
                  if (hostMode) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: locked ? null : _refreshSources,
                      icon: const Icon(Icons.monitor),
                      label: const Text('Найти экраны и окна'),
                    ),
                    if (sources.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<DesktopCapturerSource>(
                        initialValue: source,
                        isExpanded: true,
                        items: sources
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: locked
                            ? null
                            : (s) => setState(() => source = s),
                        decoration: const InputDecoration(
                          labelText: 'Источник трансляции',
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _choice<int>('Высота, p', height, [
                          720,
                          1080,
                          1440,
                          2160,
                        ], (v) => height = v),
                        _choice<int>('Частота, FPS', fps, [
                          30,
                          60,
                          120,
                          144,
                          165,
                          240,
                        ], (v) => fps = v),
                        _choice<int>('Мбит/с на зрителя', bitrate, [
                          8,
                          12,
                          20,
                          35,
                          50,
                          80,
                          100,
                        ], (v) => bitrate = v),
                        _choice<String>('Предпочтение кодека', codec, [
                          'H264',
                          'VP9',
                          'VP8',
                        ], (v) => codec = v),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Приоритет чёткости'),
                      subtitle: const Text(
                        'Включён: сохранять разрешение. Выключен: сохранять FPS при нехватке канала.',
                      ),
                      value: keepResolution,
                      onChanged: locked
                          ? null
                          : (v) => setState(() => keepResolution = v),
                    ),
                    const Text(
                      'FPS и битрейт — цели, не обещание. Аппаратный кодек используется, если его предоставляет WebRTC/драйвер. Каждый зритель расходует исходящий канал отдельно.',
                      style: TextStyle(fontSize: 12, color: Color(0xffb7a68e)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: locked ? null : _start,
                        icon: Icon(
                          hostMode ? Icons.screen_share : Icons.play_arrow,
                        ),
                        label: Text(
                          hostMode
                              ? 'Поднять флаг и передавать'
                              : 'Подняться на борт',
                        ),
                      ),
                      if (session.busy || session.connected || session.hasVideo)
                        OutlinedButton(
                          onPressed: () => session.stop('Вы отключились.'),
                          child: const Text('Отключиться'),
                        ),
                      if (working || session.busy)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(session.status, style: const TextStyle(color: gold)),
                  if (session.warning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        session.warning,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  if (session.invitation.isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Приглашение для команды'),
                            const SizedBox(height: 8),
                            SelectableText(session.invitation),
                            TextButton.icon(
                              onPressed: () => _copy(session.invitation),
                              icon: const Icon(Icons.copy),
                              label: const Text('Копировать ссылку'),
                            ),
                            const Text(
                              'Передайте друзьям также придуманный код комнаты.',
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (session.hasVideo) ...[
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ColoredBox(
                        color: Colors.black,
                        child: RTCVideoView(
                          session.renderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                          mirror: false,
                        ),
                      ),
                    ),
                    if (!hostMode)
                      Wrap(
                        children: [
                          TextButton.icon(
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      _Fullscreen(renderer: session.renderer),
                                ),
                              );
                            },
                            icon: const Icon(Icons.fullscreen),
                            label: const Text('На весь экран'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              try {
                                await session.toggleAudio();
                              } catch (_) {
                                _message('Не удалось изменить громкость.');
                              }
                            },
                            icon: Icon(
                              session.playbackMuted
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                            ),
                            label: const Text('Звук'),
                          ),
                        ],
                      ),
                  ],
                  if (session.metrics.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(
                        session.metrics,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text(
                    'Без записи на сервере · комнаты совместимы с браузером',
                    style: TextStyle(color: Color(0xffb7a68e)),
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

class _Fullscreen extends StatefulWidget {
  const _Fullscreen({required this.renderer});
  final RTCVideoRenderer renderer;
  @override
  State<_Fullscreen> createState() => _FullscreenState();
}

class _FullscreenState extends State<_Fullscreen> {
  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: [
        Positioned.fill(
          child: RTCVideoView(
            widget.renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        ),
        Positioned(
          top: 24,
          left: 12,
          child: IconButton.filledTonal(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    ),
  );
}
