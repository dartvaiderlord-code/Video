import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';
import 'certificate_trust.dart';
import 'certificate_dialog.dart';
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
  late bool hostMode =
      widget.initialHostMode ??
      (defaultTargetPlatform == TargetPlatform.windows);
  bool working = false;
  int height = 1080, fps = 120, bitrate = 35;
  String codec = 'H264';
  bool keepResolution = true, fullQuality = true, preview = false;
  String? audioSourceId = '0';
  final chatText = TextEditingController();
  bool showChat = false;
  List<DesktopCapturerSource> sources = [];
  DesktopCapturerSource? source;
  final Map<String, String> certificates = {};
  final Map<String, String> certificatePins = {};
  bool get locked => working || session.busy || session.connected;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_update);
    session.chat.addListener(_update);
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
    final savedPins = prefs.getString('trustedCertificatePinsByOrigin');
    if (savedPins != null) {
      try {
        final pins = Map<String, String>.from(jsonDecode(savedPins) as Map);
        certificatePins.addAll(
          Map.fromEntries(
            pins.entries.where(
              (e) => RegExp(
                r'^(?:[A-F0-9]{2}:){31}[A-F0-9]{2}$',
              ).hasMatch(e.value),
            ),
          ),
        );
      } catch (_) {
        /* Ignore malformed local preferences. */
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

  Future<CertificateAcceptance> _confirmCertificate(
    ServerCertificate certificate,
  ) async {
    if (!mounted) return CertificateAcceptance.reject;
    return confirmServerCertificate(context, certificate);
  }

  Future<void> _rememberCertificate(ServerCertificate certificate) async {
    certificatePins[certificate.origin.origin] = certificate.fingerprint;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        'trustedCertificatePinsByOrigin',
        jsonEncode(certificatePins),
      )) {
        throw StateError('Не удалось записать настройки.');
      }
    } catch (_) {
      _message(
        'Сертификат запомнен только до закрытия приложения: не удалось сохранить настройки.',
      );
    }
  }

  Future<void> _forgetTrust() async {
    try {
      final origin = _endpoint().origin;
      certificates.remove(origin);
      certificatePins.remove(origin);
      final prefs = await SharedPreferences.getInstance();
      final caSaved = await prefs.setString(
        'trustedCaByOrigin',
        jsonEncode(certificates),
      );
      final pinSaved = await prefs.setString(
        'trustedCertificatePinsByOrigin',
        jsonEncode(certificatePins),
      );
      if (!caSaved || !pinSaved) {
        throw StateError('Не удалось полностью удалить сохранённое доверие.');
      }
      _update();
      _message('Доверие к CA и сертификату этого сервера удалено.');
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
          if (audioSourceId != null &&
              audioSourceId != '0' &&
              !list.any(
                (s) => s.type == SourceType.Window && s.id == audioSourceId,
              )) {
            audioSourceId = null;
          }
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
            fullQuality: fullQuality,
          ),
          _ca(endpoint),
          audioSourceId: audioSourceId,
          preview: preview,
          certificatePin: certificatePins[endpoint.origin],
          confirmCertificate: _confirmCertificate,
          onCertificateRemembered: _rememberCertificate,
        );
      } else {
        await session.watch(
          RoomInvite.parse(invite.text),
          code.text,
          _ca(endpoint),
          certificatePin: certificatePins[endpoint.origin],
          confirmCertificate: _confirmCertificate,
          onCertificateRemembered: _rememberCertificate,
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
    session.chat.removeListener(_update);
    chatText.dispose();
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

  Widget _chatPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Чат команды · ${session.chat.members.length} на борту'),
        value: showChat,
        onChanged: (v) => setState(() => showChat = v),
      ),
      if (showChat) ...[
        SizedBox(
          height: 180,
          child: ListView(
            reverse: true,
            children: session.chat.messages.reversed
                .map(
                  (m) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: SelectableText('${m.name}: ${m.text}'),
                  ),
                )
                .toList(),
          ),
        ),
        TextField(
          controller: chatText,
          maxLength: 2000,
          decoration: InputDecoration(
            labelText: 'Сообщение команде',
            suffixIcon: IconButton(
              icon: const Icon(Icons.send),
              onPressed: _sendChat,
            ),
          ),
          onSubmitted: (_) => _sendChat(),
        ),
      ],
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: session.chat.busy
                ? null
                : () => session.chat.toggleVoice(),
            icon: Icon(session.chat.enabled ? Icons.call_end : Icons.mic),
            label: Text(
              session.chat.enabled
                  ? 'Выйти из голосового чата'
                  : 'Войти в голосовой чат',
            ),
          ),
          if (session.chat.enabled)
            OutlinedButton.icon(
              onPressed: session.chat.toggleMute,
              icon: Icon(session.chat.muted ? Icons.mic_off : Icons.mic),
              label: Text(
                session.chat.muted ? 'Включить микрофон' : 'Выключить микрофон',
              ),
            ),
        ],
      ),
      if (session.chat.error.isNotEmpty)
        Text(
          session.chat.error,
          style: const TextStyle(color: Colors.orangeAccent),
        ),
      const Text(
        'Голосовой чат необязателен. Микрофон включается только после нажатия кнопки. Для избежания эха используйте наушники.',
        style: TextStyle(fontSize: 12, color: Color(0xffb7a68e)),
      ),
    ],
  );
  void _sendChat() {
    session.chat.post(chatText.text);
    chatText.clear();
  }

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
                    (defaultTargetPlatform == TargetPlatform.windows)
                        ? 'Windows · экран и системный звук'
                        : 'Android · нативный просмотр',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  if (defaultTargetPlatform == TargetPlatform.windows) ...[
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Капитан'),
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
                        onPressed: locked ? null : _forgetTrust,
                        child: const Text('Сбросить доверие'),
                      ),
                    ],
                  ),
                  const Text(
                    'Недоверенный сертификат можно подтвердить при подключении. Импорт root.crt необязателен; сохранённое доверие можно сбросить.',
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
                        key: ValueKey(sources),
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
                          labelText:
                              'Источник трансляции · для 120+ FPS выбирайте DXGI',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('audio-${sources.hashCode}'),
                      initialValue: audioSourceId ?? 'none',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Звук для зрителей',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '0',
                          child: Text('Весь системный звук'),
                        ),
                        const DropdownMenuItem(
                          value: 'none',
                          child: Text('Без звука'),
                        ),
                        ...sources
                            .where((s) => s.type == SourceType.Window)
                            .map(
                              (s) => DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  'Приложение: ${s.name}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                      ],
                      onChanged: locked
                          ? null
                          : (v) => setState(
                              () => audioSourceId = v == 'none' ? null : v,
                            ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Звук выбранного приложения и его дочерних процессов — независимо от захватываемого экрана. Windows 11 / Server 2022 (build 20348+). Выбор одного приложения.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xffb7a68e),
                        ),
                      ),
                    ),
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
                          150,
                          200,
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
                      title: const Text('Предпросмотр у капитана'),
                      subtitle: const Text(
                        'Выключен по умолчанию, чтобы оставить больше ресурсов для передачи видео.',
                      ),
                      value: preview,
                      onChanged: locked
                          ? null
                          : (v) => setState(() => preview = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Сохранять разрешение и FPS'),
                      subtitle: const Text(
                        'Высокий стартовый битрейт. Отключить автоматическое уменьшение кадра и FPS кодировщиком. Требует достаточного канала и мощности устройств.',
                      ),
                      value: fullQuality,
                      onChanged: locked
                          ? null
                          : (v) => setState(() => fullQuality = v),
                    ),
                    if (!fullQuality)
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
                  if (session.connected) _chatPanel(),
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
