import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// ---------- НАСТРОЙКИ ----------
const limitBytes = 3 * 1024 * 1024 * 1024; // лимит 3 ГБ
const openaiModel = 'gpt-4o-mini';
const geminiModel = 'gemini-flash-latest';
const claudeModel = 'claude-haiku-5-5';
// --------------------------------

late Directory dir;
late File seenFile, viewedFile;
late SharedPreferences prefs;
final loader = Loader();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  final base = await getApplicationDocumentsDirectory();
  dir = Directory('${base.path}/shorts')..createSync(recursive: true);
  seenFile = File('${base.path}/seen.txt')..createSync();
  viewedFile = File('${base.path}/viewed.txt')..createSync();
  loader.seen = seenFile.readAsLinesSync().toSet();
  loader.viewed = viewedFile.readAsLinesSync().toSet();
  runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const Feed()));
}

String idOf(File f) => f.uri.pathSegments.last.replaceAll('.mp4', '');

List<File> allFiles() => dir
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.mp4'))
    .toList()
  ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

class RateLimit implements Exception {}

class BadKey implements Exception {}

// ---------- ИИ-провайдеры ----------
const providers = ['gemini', 'claude', 'openai'];
const providerNames = {
  'gemini': 'Gemini Flash',
  'claude': 'Claude Haiku',
  'openai': 'OpenAI mini',
};

String keyOf(String p) => (prefs.getString('key_$p') ?? '').trim();
List<String> activeProviders() =>
    providers.where((p) => keyOf(p).isNotEmpty).toList();

Future<String> askProvider(String p, String prompt, String b64) async {
  final key = keyOf(p);
  http.Response res;
  if (p == 'claude') {
    res = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'content-type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': claudeModel,
            'max_tokens': 10,
            'messages': [
              {
                'role': 'user',
                'content': [
                  if (b64.isNotEmpty)
                    {
                      'type': 'image',
                      'source': {
                        'type': 'base64',
                        'media_type': 'image/jpeg',
                        'data': b64
                      }
                    },
                  {'type': 'text', 'text': prompt},
                ]
              }
            ],
          }),
        )
        .timeout(const Duration(seconds: 40));
    _check(res);
    return jsonDecode(res.body)['content'][0]['text'] as String;
  }
  if (p == 'openai') {
    res = await http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': openaiModel,
            'max_tokens': 10,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': prompt},
                  if (b64.isNotEmpty)
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:image/jpeg;base64,$b64'}
                    },
                ]
              }
            ],
          }),
        )
        .timeout(const Duration(seconds: 40));
    _check(res);
    return jsonDecode(res.body)['choices'][0]['message']['content'] as String;
  }
  // gemini
  res = await http
      .post(
        Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$geminiModel:generateContent'),
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': key,
        },
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
                if (b64.isNotEmpty)
                  {
                    'inline_data': {'mime_type': 'image/jpeg', 'data': b64}
                  },
              ]
            }
          ],
          'generationConfig': {'temperature': 0},
        }),
      )
      .timeout(const Duration(seconds: 40));
  _check(res);
  return jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text']
      as String;
}

void _check(http.Response r) {
  if (r.statusCode == 429) throw RateLimit();
  if (r.statusCode == 401 || r.statusCode == 403 || r.statusCode == 400) {
    throw BadKey();
  }
  if (r.statusCode != 200) throw Exception('ИИ: ${r.statusCode}');
}

// ---------- Загрузчик ----------
class Loader {
  final yt = YoutubeExplode();
  final changed = ValueNotifier<int>(0);
  Set<String> seen = {}, viewed = {};
  bool fast = false, paused = false, started = false;
  String status = '', playingId = '';
  final cooldown = <String, DateTime>{};
  final lastUse = <String, DateTime>{};
  int rr = 0;
  double backoff = 1;

  // Сколько секунд ждать между скачиваниями: зависит от того,
  // сколько непросмотренного уже лежит, и от лимитов ИИ.
  int interval() {
    if (fast) return 1;
    final unseen =
        allFiles().where((f) => !viewed.contains(idOf(f))).length;
    final base = unseen < 15
        ? 10
        : unseen < 50
            ? 20 // ~3 в минуту
            : unseen < 100
                ? 40
                : unseen < 200
                    ? 90
                    : 180;
    return (base * backoff).round();
  }

  // true = берём, false = мимо, null = пауза (ничего не отмечаем)
  Future<bool?> judge(Video v) async {
    final prompt = 'Ты куратор ленты коротких видео. Интересы пользователя: '
        '${prefs.getString('interests') ?? ''}.\n\nВидео:\n'
        'Название: ${v.title}\nКанал: ${v.author}\n'
        'Просмотры: ${v.engagement.viewCount}\n'
        'Описание: ${v.description}\n\n'
        'Ответь одним словом: YES, если ролик по-настоящему интересный, '
        'качественный и подходит под интересы. NO, если это реклама, спам, '
        'кликбейт, мусор или не по теме.';
    var b64 = '';
    try {
      final r = await http
          .get(Uri.parse('https://i.ytimg.com/vi/${v.id.value}/hqdefault.jpg'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) b64 = base64Encode(r.bodyBytes);
    } catch (_) {}

    while (true) {
      if (paused) return null;
      final act = activeProviders();
      if (act.isEmpty) throw BadKey();
      final now = DateTime.now();
      final ready = act
          .where((p) => (cooldown[p] ?? DateTime(2000)).isBefore(now))
          .toList();
      if (ready.isEmpty) {
        _status('Все ИИ на паузе по лимиту, жду');
        await _wait(15);
        continue;
      }
      final p = ready[rr++ % ready.length];
      final gap = now.difference(lastUse[p] ?? DateTime(2000)).inSeconds;
      if (gap < 5) await _wait(5 - gap);
      lastUse[p] = DateTime.now();
      try {
        final text = await askProvider(p, prompt, b64);
        backoff = max(1, backoff * 0.9);
        return text.trim().toUpperCase().startsWith('YES');
      } on RateLimit {
        cooldown[p] = DateTime.now().add(const Duration(minutes: 2));
        backoff = min(8, backoff * 1.5);
        _status('${providerNames[p]}: лимит, переключаюсь');
      } on BadKey {
        cooldown[p] = DateTime.now().add(const Duration(minutes: 10));
        _status('${providerNames[p]}: ключ не принят');
      }
    }
  }

  void markViewed(String id) {
    if (viewed.add(id)) {
      viewedFile.writeAsStringSync('$id\n', mode: FileMode.append);
    }
  }

  void _markSeen(String id) {
    if (seen.add(id)) {
      seenFile.writeAsStringSync('$id\n', mode: FileMode.append);
    }
  }

  void _status(String s) {
    status = s;
    changed.value++;
  }

  Future<void> _wait(int n, {bool respectFast = false}) async {
    for (var i = 0; i < n; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (respectFast && fast) break;
    }
  }

  void cleanup() {
    final files = allFiles();
    var total = files.fold<int>(0, (s, f) => s + f.lengthSync());
    final order = [
      ...files.where((f) => viewed.contains(idOf(f))),
      ...files.where((f) => !viewed.contains(idOf(f))),
    ];
    for (final f in order) {
      if (total <= limitBytes) break;
      if (idOf(f) == playingId) continue;
      total -= f.lengthSync();
      f.deleteSync();
    }
  }

  Future<bool> _download(Video v) async {
    final id = v.id.value;
    final m = await yt.videos.streamsClient.getManifest(v.id);
    final st = m.muxed.withHighestBitrate();
    final tmp = File('${dir.path}/$id.part');
    await yt.videos.streamsClient.get(st).pipe(tmp.openWrite());
    await tmp.rename('${dir.path}/$id.mp4');
    cleanup();
    return true;
  }

  Future<bool> _fromQuery(String q) async {
    var got = false;
    var page = await yt.search.search('$q #shorts');
    for (var p = 0; p < 3; p++) {
      for (final v in page) {
        if (paused) return got;
        final d = v.duration;
        if (d == null || d.inSeconds > 61 || d.inSeconds < 5) continue;
        final id = v.id.value;
        if (seen.contains(id)) continue;

        _status('ИИ смотрит: ${v.title}');
        final ok = await judge(v);
        if (ok == null) return got;
        _markSeen(id);
        if (!ok) continue;

        try {
          _status('Качаю: ${v.title}');
          await _download(v);
          got = true;
          _status('Сохранено: ${allFiles().length} шт, след. через ${interval()} с');
        } catch (e) {
          _status('Пропуск: $e');
        }
        await _wait(interval(), respectFast: true);
      }
      final next = await page.nextPage();
      if (next == null) break;
      page = next;
    }
    return got;
  }

  Future<void> run() async {
    if (started) return;
    started = true;
    while (true) {
      if (paused) {
        await _wait(2);
        continue;
      }
      final hasKey = activeProviders().isNotEmpty;
      final topics = (prefs.getString('interests') ?? '')
          .split(RegExp(r'[,\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (!hasKey || topics.isEmpty) {
        _status('Откройте ⚙: нужен хотя бы один ключ и интересы');
        await _wait(5);
        continue;
      }
      topics.shuffle();
      var got = false;
      for (final q in topics) {
        if (paused) break;
        try {
          got = await _fromQuery(q) || got;
        } on RateLimit {
          _status('Лимит ИИ, жду 2 минуты');
          await _wait(120);
        } on BadKey {
          _status('Нет рабочих ключей ИИ, проверьте ⚙');
          await _wait(30);
        } catch (e) {
          _status('Ошибка: $e');
          await _wait(10);
        }
      }
      if (!got) await _wait(300);
    }
  }
}

// ---------- Лента ----------
class Feed extends StatefulWidget {
  const Feed({super.key});
  @override
  State<Feed> createState() => _FeedState();
}

class _FeedState extends State<Feed> {
  List<File> files = [];
  final pc = PageController();
  int page = 0;
  bool first = true;

  @override
  void initState() {
    super.initState();
    loader.changed.addListener(refresh);
    refresh();
    loader.run();
    if (activeProviders().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => settings());
    }
  }

  void refresh() {
    if (!mounted) return;
    final list = allFiles();
    final cur = page < files.length ? files[page].path : null;
    var target = page;
    if (first && list.isNotEmpty) {
      first = false;
      final i = list.indexWhere((f) => !loader.viewed.contains(idOf(f)));
      target = i < 0 ? 0 : i;
    } else if (cur != null) {
      final i = list.indexWhere((f) => f.path == cur);
      if (i >= 0) target = i;
    }
    setState(() => files = list);
    if (target != page) {
      page = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (pc.hasClients) pc.jumpToPage(target);
      });
    }
  }

  void settings() {
    final keys = {
      for (final p in providers)
        p: TextEditingController(text: prefs.getString('key_$p') ?? '')
    };
    final topics =
        TextEditingController(text: prefs.getString('interests') ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Настройки'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'Ключи разных ИИ (хватит одного, чем больше, тем быстрее отбор)',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
            for (final p in providers)
              TextField(
                controller: keys[p],
                decoration:
                    InputDecoration(labelText: 'Ключ ${providerNames[p]}'),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: topics,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Интересы через запятую',
                  hintText: 'смешные животные, лайфхаки, наука'),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              for (final p in providers) {
                await prefs.setString('key_$p', keys[p]!.text.trim());
              }
              await prefs.setString('interests', topics.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        files.isEmpty
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    loader.status.isEmpty ? 'Пока нет видео' : loader.status,
                    textAlign: TextAlign.center),
              ))
            : PageView.builder(
                controller: pc,
                scrollDirection: Axis.vertical,
                itemCount: files.length,
                onPageChanged: (i) {
                  if (page < files.length) loader.markViewed(idOf(files[page]));
                  page = i;
                  loader.playingId = idOf(files[i]);
                },
                itemBuilder: (_, i) =>
                    Player(key: ValueKey(files[i].path), file: files[i]),
              ),
        SafeArea(
          child: Row(children: [
            Expanded(
                child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(loader.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            )),
            IconButton(
                icon: Icon(Icons.bolt,
                    color: loader.fast ? Colors.yellow : Colors.white38),
                onPressed: () => setState(() => loader.fast = !loader.fast)),
            IconButton(
                icon: Icon(loader.paused ? Icons.play_arrow : Icons.pause,
                    color: Colors.white38),
                onPressed: () =>
                    setState(() => loader.paused = !loader.paused)),
            IconButton(
                icon: const Icon(Icons.settings, color: Colors.white38),
                onPressed: settings),
          ]),
        ),
      ]),
    );
  }
}

class Player extends StatefulWidget {
  final File file;
  const Player({super.key, required this.file});
  @override
  State<Player> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  late VideoPlayerController c;

  @override
  void initState() {
    super.initState();
    c = VideoPlayerController.file(widget.file)
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) setState(() {});
        c.play();
      });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => c.value.isPlaying ? c.pause() : c.play(),
        child: c.value.isInitialized
            ? Center(
                child: AspectRatio(
                    aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
            : const SizedBox(),
      );
}
