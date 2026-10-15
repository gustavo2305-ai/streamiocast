import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ChromecastStremioApp());
}

class ChromecastStremioApp extends StatelessWidget {
  const ChromecastStremioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StreamioCast • Netflix Edition',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0C10),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE50914), // Vermelho Netflix
          secondary: Color(0xFF10B981), // Verde Live / Online
          surface: Color(0xFF141720),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0C10),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF141722),
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ============================================================================
// MICRO-SERVIDOR HTTP LOCAL PARA SERVIR LEGENDAS (.SRT -> .VTT COM CORS)
// ============================================================================
class LocalSubtitleServer {
  HttpServer? _server;
  String _currentVtt = 'WEBVTT\n\n';

  int get port => _server?.port ?? 0;

  Future<void> ensureStarted() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server!.listen((HttpRequest req) {
        req.response.headers.add('Access-Control-Allow-Origin', '*');
        req.response.headers.add('Access-Control-Allow-Methods', 'GET, OPTIONS');
        req.response.headers.add('Access-Control-Allow-Headers', '*');
        req.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
        req.response.write(_currentVtt);
        req.response.close();
      });
    } catch (_) {}
  }

  String srtToWebVtt(String raw) {
    var txt = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceFirst('\uFEFF', '');
    if (txt.trimLeft().startsWith('WEBVTT')) return txt;
    final reg = RegExp(r'(\d{2}:\d{2}:\d{2}),(\d{3})');
    txt = txt.replaceAllMapped(reg, (m) => '${m.group(1)}.${m.group(2)}');
    return 'WEBVTT\n\n$txt';
  }

  Future<String> hostSubtitleFromUrl(String subUrl, String localIp) async {
    await ensureStarted();
    final res = await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds: 10));
    final decoded = utf8.decode(res.bodyBytes, allowMalformed: true);
    _currentVtt = srtToWebVtt(decoded);
    return 'http://$localIp:$port/sub_${DateTime.now().millisecondsSinceEpoch}.vtt';
  }
}

// ============================================================================
// SERVIDOR WEB LOCAL EMBUTIDO & PWA NETFLIX PARA ACESSO VIA IPHONE (PORTA 8080)
// ============================================================================
class LocalWebRemoteServer {
  HttpServer? _server;
  final List<ChannelItem> Function() getChannels;
  final Map<String, StreamHealth> Function() getHealthMap;
  final List<StremioAddon> Function() getAddons;
  final ActivePlaybackContext? Function() getCurrentPlayback;
  final String Function() getPlayerState;
  final double Function() getVolume;
  final String Function() getCastIp;
  final Future<void> Function({
    required String url,
    required String title,
    String poster,
    String? subtitleUrl,
    Map<String, dynamic>? seriesContext,
  }) onPlayMedia;
  final Future<void> Function(String cmd) onMediaCmd;
  final Future<void> Function(double vol) onSetVolume;
  final Future<void> Function(List<ChannelItem> channels) onTestChannels;

  LocalWebRemoteServer({
    required this.getChannels,
    required this.getHealthMap,
    required this.getAddons,
    required this.getCurrentPlayback,
    required this.getPlayerState,
    required this.getVolume,
    required this.getCastIp,
    required this.onPlayMedia,
    required this.onMediaCmd,
    required this.onSetVolume,
    required this.onTestChannels,
  });

  int get port => _server?.port ?? 8080;

  Future<void> start({int port = 8080}) async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handleRequest);
    } catch (_) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
        _server!.listen(_handleRequest);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  void _addCors(HttpResponse res) {
    res.headers.add('Access-Control-Allow-Origin', '*');
    res.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.add('Access-Control-Allow-Headers', '*');
  }

  Future<void> _handleRequest(HttpRequest req) async {
    _addCors(req.response);
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }

    final path = req.uri.path;

    try {
      // 1. ROTA RAIZ: SERVE O APP WEB / PWA NETFLIX
      if (path == '/' || path == '/index.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write(_webAppHtml);
        await req.response.close();
        return;
      }

      // 2. API: STATUS DA TRANSMISSÃO
      if (path == '/api/status') {
        final cur = getCurrentPlayback();
        final data = {
          'connected': true,
          'castIp': getCastIp(),
          'playerState': getPlayerState(),
          'volume': getVolume(),
          'currentPlayback': cur == null
              ? null
              : {
                  'title': cur.title,
                  'poster': cur.poster,
                  'type': cur.type,
                  'isSeries': cur.isSeries,
                  'seriesId': cur.seriesId,
                  'seriesTitle': cur.seriesTitle,
                  'season': cur.season,
                  'episode': cur.episode,
                },
        };
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(data));
        await req.response.close();
        return;
      }

      // 3. API: LISTA DE CANAIS COM STATUS ONLINE/OFFLINE
      if (path == '/api/channels') {
        final channels = getChannels();
        final health = getHealthMap();
        final list = channels.map((c) {
          final h = health[c.url];
          return {
            'name': c.name,
            'group': c.group,
            'logo': c.logo,
            'url': c.url,
            'status': h?.status.name ?? 'unknown',
            'latency': h?.latencyMs,
          };
        }).toList();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'channels': list}));
        await req.response.close();
        return;
      }

      // 4. API: CATÁLOGO DE FILMES / SÉRIES
      if (path == '/api/catalog') {
        final type = req.uri.queryParameters['type'] ?? 'series';
        final search = req.uri.queryParameters['search'] ?? '';
        final extra = search.trim().isNotEmpty ? '/search=${Uri.encodeComponent(search.trim())}.json' : '.json';
        final u = 'https://v3-cinemeta.strem.io/catalog/$type/top$extra';
        final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
        req.response.headers.contentType = ContentType.json;
        req.response.write(r.body);
        await req.response.close();
        return;
      }

      // 5. API: EPISÓDIOS E TEMPORADAS DA SÉRIE
      if (path == '/api/series') {
        final id = req.uri.queryParameters['id'] ?? '';
        final u = 'https://v3-cinemeta.strem.io/meta/series/${Uri.encodeComponent(id)}.json';
        final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
        final bySeason = <String, List<Map<String, dynamic>>>{};
        final allEps = <Map<String, dynamic>>[];
        if (r.statusCode == 200) {
          final videos = jsonDecode(r.body)['meta']?['videos'] as List? ?? [];
          for (final v in videos) {
            final sNum = (v['season'] as num?)?.toInt() ?? 1;
            if (sNum == 0) continue;
            final map = Map<String, dynamic>.from(v);
            bySeason.putIfAbsent(sNum.toString(), () => []).add(map);
            allEps.add(map);
          }
        }
        for (final k in bySeason.keys) {
          bySeason[k]!.sort((a, b) => ((a['episode'] as num?) ?? 0).compareTo((b['episode'] as num?) ?? 0));
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'seasons': bySeason, 'all': allEps}));
        await req.response.close();
        return;
      }

      // 6. API: BUSCA DE STREAMS E LEGENDAS
      if (path == '/api/streams') {
        final type = req.uri.queryParameters['type'] ?? 'movie';
        final id = req.uri.queryParameters['id'] ?? '';
        final streams = <Map<String, dynamic>>[];
        final subtitles = <Map<String, String>>[];

        for (final a in getAddons().where((addon) => addon.enabled)) {
          try {
            final u = '${a.baseUrl}/stream/$type/${Uri.encodeComponent(id)}.json';
            final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 6));
            if (r.statusCode == 200) {
              final list = jsonDecode(r.body)['streams'] as List? ?? [];
              for (final s in list) {
                final directUrl = s['url']?.toString();
                final desc = '${s['name'] ?? ''} ${s['title'] ?? ''}'.trim();
                final upper = desc.toUpperCase();
                final isPtBr = upper.contains('DUBLADO') ||
                    upper.contains('DUAL') ||
                    upper.contains('PT-BR') ||
                    upper.contains('PORTUGUES') ||
                    upper.contains('🇧🇷') ||
                    upper.contains('🇵🇹');

                if (directUrl != null && directUrl.isNotEmpty) {
                  streams.add({
                    'addon': a.name,
                    'title': desc,
                    'url': directUrl,
                    'isPtBr': isPtBr,
                  });
                }
              }
            }
          } catch (_) {}
        }

        streams.sort((a, b) => (b['isPtBr'] ? 1 : 0).compareTo(a['isPtBr'] ? 1 : 0));

        try {
          final subUrl = 'https://opensubtitles-v3.strem.io/subtitles/$type/${Uri.encodeComponent(id)}.json';
          final sr = await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds: 6));
          if (sr.statusCode == 200) {
            final rawSubs = jsonDecode(sr.body)['subtitles'] as List? ?? [];
            for (final sub in rawSubs) {
              final lang = (sub['lang'] ?? '').toString().toLowerCase();
              final u = (sub['url'] ?? '').toString();
              if (u.isNotEmpty && (lang.contains('pob') || lang.contains('pt') || lang.contains('bra'))) {
                subtitles.add({'label': '🇧🇷 Português', 'url': u});
                break;
              }
            }
          }
        } catch (_) {}

        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'streams': streams, 'subtitles': subtitles}));
        await req.response.close();
        return;
      }

      // 7. API: REPRODUZIR NA TV
      if (path == '/api/play' && req.method == 'POST') {
        final bodyStr = await utf8.decodeStream(req);
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final url = (body['url'] ?? '').toString();
        final title = (body['title'] ?? 'Título').toString();
        final poster = (body['poster'] ?? '').toString();
        final subUrl = body['subtitleUrl']?.toString();
        final seriesContext = body['seriesContext'] as Map<String, dynamic>?;

        await onPlayMedia(
          url: url,
          title: title,
          poster: poster,
          subtitleUrl: subUrl,
          seriesContext: seriesContext,
        );

        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'success': true}));
        await req.response.close();
        return;
      }

      // 8. API: COMANDOS DE MÍDIA
      if (path == '/api/cmd' && req.method == 'POST') {
        final bodyStr = await utf8.decodeStream(req);
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final cmd = (body['type'] ?? '').toString();
        await onMediaCmd(cmd);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'success': true}));
        await req.response.close();
        return;
      }

      // 9. API: VOLUME
      if (path == '/api/volume' && req.method == 'POST') {
        final bodyStr = await utf8.decodeStream(req);
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final vol = (body['volume'] as num?)?.toDouble() ?? 0.8;
        await onSetVolume(vol);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'success': true}));
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      req.response.write('Not Found');
      await req.response.close();
    } catch (e) {
      req.response.statusCode = 500;
      req.response.write('Error: $e');
      await req.response.close();
    }
  }

  static const String _webAppHtml = r'''<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>StreamioCast • Netflix</title>
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="StreamioCast">
  <meta name="theme-color" content="#0A0C10">
  <link rel="apple-touch-icon" href="https://upload.wikimedia.org/wikipedia/commons/7/7a/Logonetflix.png">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
    body {
      background: #0A0C10;
      color: #FFFFFF;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding-bottom: 90px;
      overflow-x: hidden;
      user-select: none;
    }
    header {
      position: sticky;
      top: 0;
      z-index: 100;
      background: rgba(10, 12, 16, 0.95);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      padding: 12px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    }
    .logo-container { display: flex; align-items: center; gap: 6px; }
    .logo-badge {
      background: #E50914;
      color: #fff;
      font-size: 11px;
      font-weight: 900;
      padding: 3px 6px;
      border-radius: 4px;
      letter-spacing: 1px;
    }
    .logo-sub { font-size: 13px; font-weight: 300; letter-spacing: 2px; color: #bbb; }
    .status-pill {
      display: flex;
      align-items: center;
      gap: 6px;
      background: #141722;
      padding: 4px 10px;
      border-radius: 16px;
      font-size: 11px;
      font-weight: 600;
      border: 1px solid rgba(255,255,255,0.1);
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #666; }
    .dot.online { background: #10B981; box-shadow: 0 0 6px #10B981; }

    nav {
      position: sticky;
      top: 53px;
      z-index: 99;
      background: #0A0C10;
      display: flex;
      gap: 8px;
      padding: 8px 16px;
      overflow-x: auto;
      white-space: nowrap;
      border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    }
    nav::-webkit-scrollbar { display: none; }
    .nav-btn {
      background: #141722;
      color: #aaa;
      border: none;
      padding: 6px 14px;
      border-radius: 20px;
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s;
    }
    .nav-btn.active {
      background: #E50914;
      color: #fff;
    }

    .view { display: none; padding: 14px; }
    .view.active { display: block; }

    /* HERO BANNER */
    .hero-banner {
      position: relative;
      height: 280px;
      border-radius: 12px;
      overflow: hidden;
      margin-bottom: 20px;
      background-size: cover;
      background-position: center;
      display: flex;
      align-items: flex-end;
      padding: 16px;
      box-shadow: 0 8px 24px rgba(0,0,0,0.6);
    }
    .hero-grad {
      position: absolute;
      inset: 0;
      background: linear-gradient(to top, rgba(10,12,16,1) 0%, rgba(10,12,16,0.6) 50%, transparent 100%);
    }
    .hero-content { position: relative; z-index: 2; width: 100%; }
    .hero-tags { display: flex; gap: 6px; margin-bottom: 6px; }
    .tag { font-size: 9px; font-weight: bold; padding: 2px 6px; border-radius: 3px; }
    .tag-red { background: #E50914; color: #fff; }
    .tag-green { background: #10B981; color: #fff; }
    .hero-title { font-size: 22px; font-weight: 900; margin-bottom: 4px; }
    .hero-desc { font-size: 12px; color: #bbb; line-height: 1.3; margin-bottom: 12px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .hero-actions { display: flex; gap: 10px; }
    .btn-play {
      background: #fff;
      color: #000;
      border: none;
      padding: 8px 18px;
      border-radius: 6px;
      font-weight: bold;
      font-size: 13px;
      display: flex;
      align-items: center;
      gap: 6px;
      cursor: pointer;
    }
    .btn-info {
      background: rgba(255,255,255,0.2);
      color: #fff;
      border: none;
      padding: 8px 14px;
      border-radius: 6px;
      font-weight: 600;
      font-size: 13px;
      cursor: pointer;
    }

    /* SWIMLANES */
    .section-title { font-size: 16px; font-weight: bold; margin: 16px 0 10px 0; }
    .swimlane {
      display: flex;
      gap: 10px;
      overflow-x: auto;
      padding-bottom: 8px;
    }
    .swimlane::-webkit-scrollbar { display: none; }
    .movie-card {
      min-width: 105px;
      max-width: 105px;
      flex-shrink: 0;
      cursor: pointer;
    }
    .poster-wrap {
      width: 105px;
      height: 150px;
      border-radius: 8px;
      overflow: hidden;
      background: #141722;
      position: relative;
    }
    .poster-img { width: 100%; height: 100%; object-fit: cover; }
    .card-title { font-size: 11px; font-weight: 600; margin-top: 5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #ddd; }

    /* GRID */
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
      gap: 12px;
    }

    /* SEARCH */
    .search-box {
      width: 100%;
      background: #141722;
      border: 1px solid rgba(255,255,255,0.1);
      padding: 10px 14px;
      border-radius: 8px;
      color: #fff;
      font-size: 14px;
      margin-bottom: 14px;
      outline: none;
    }
    .search-box:focus { border-color: #E50914; }

    /* CHANNELS */
    .channel-item {
      background: #141722;
      border-radius: 8px;
      padding: 10px 14px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 8px;
      border: 1px solid rgba(255,255,255,0.05);
    }
    .ch-info { display: flex; align-items: center; gap: 12px; flex: 1; overflow: hidden; }
    .ch-logo { width: 40px; height: 40px; object-fit: contain; border-radius: 4px; background: #0A0C10; }
    .ch-name { font-size: 13px; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ch-group { font-size: 11px; color: #888; }
    .btn-cast {
      background: #10B981;
      color: #fff;
      border: none;
      padding: 6px 14px;
      border-radius: 6px;
      font-weight: bold;
      font-size: 12px;
      cursor: pointer;
    }

    /* REMOTE CONTROL */
    .remote-card {
      background: #141722;
      border-radius: 12px;
      padding: 20px;
      text-align: center;
      margin-bottom: 16px;
    }
    .remote-row {
      display: flex;
      justify-content: center;
      gap: 14px;
      margin: 16px 0;
    }
    .remote-btn {
      background: #202434;
      color: #fff;
      border: none;
      width: 58px;
      height: 58px;
      border-radius: 50%;
      font-size: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      transition: background 0.2s;
    }
    .remote-btn:active { background: #E50914; }
    .remote-btn.big {
      width: 72px;
      height: 72px;
      background: #E50914;
      font-size: 26px;
    }
    .vol-slider {
      width: 100%;
      margin-top: 14px;
      accent-color: #E50914;
    }

    /* MINI PLAYER */
    .mini-player {
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      background: rgba(20, 23, 34, 0.96);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border-top: 1px solid rgba(229, 9, 20, 0.4);
      padding: 10px 14px;
      display: flex;
      align-items: center;
      gap: 10px;
      z-index: 200;
      padding-bottom: max(10px, env(safe-area-inset-bottom));
      box-shadow: 0 -4px 16px rgba(0,0,0,0.5);
    }
    .mini-poster { width: 38px; height: 50px; border-radius: 4px; object-fit: cover; background: #0A0C10; }
    .mini-info { flex: 1; overflow: hidden; }
    .mini-title { font-size: 12px; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #fff; }
    .mini-sub { font-size: 10px; color: #10B981; }
    .mini-btn {
      background: none;
      border: none;
      color: #fff;
      font-size: 22px;
      cursor: pointer;
      padding: 4px;
    }
    .mini-btn.red { color: #E50914; }

    /* MODAL */
    .modal {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.85);
      z-index: 300;
      padding: 16px;
      overflow-y: auto;
    }
    .modal-content {
      background: #141722;
      border-radius: 12px;
      padding: 18px;
      max-width: 500px;
      margin: 20px auto;
      border: 1px solid rgba(255,255,255,0.1);
    }
    .modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
    .modal-close { background: none; border: none; color: #aaa; font-size: 24px; cursor: pointer; }
    .season-select {
      width: 100%;
      background: #0A0C10;
      color: #fff;
      border: 1px solid rgba(255,255,255,0.15);
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 14px;
      margin-bottom: 14px;
    }
    .ep-item {
      background: #0A0C10;
      border-radius: 8px;
      padding: 10px;
      margin-bottom: 8px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .ep-thumb { width: 64px; height: 42px; border-radius: 4px; object-fit: cover; background: #1a1d28; }
    .ep-info { flex: 1; overflow: hidden; }
    .ep-title { font-size: 12px; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ep-desc { font-size: 10px; color: #888; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  </style>
</head>
<body>
  <header>
    <div class="logo-container">
      <span class="logo-badge">STREAMIO</span>
      <span class="logo-sub">CAST</span>
    </div>
    <div class="status-pill">
      <span class="dot" id="castDot"></span>
      <span id="castStatusText">TV</span>
    </div>
  </header>

  <nav>
    <button class="nav-btn active" onclick="switchTab('inicio')">🏠 Início</button>
    <button class="nav-btn" onclick="switchTab('series')">📺 Séries</button>
    <button class="nav-btn" onclick="switchTab('filmes')">🎬 Filmes</button>
    <button class="nav-btn" onclick="switchTab('canais')">📡 TV Ao Vivo</button>
    <button class="nav-btn" onclick="switchTab('controle')">📱 Controle</button>
  </nav>

  <!-- ABA 0: INÍCIO -->
  <div id="tab-inicio" class="view active">
    <div id="heroBanner" class="hero-banner" style="display:none;">
      <div class="hero-grad"></div>
      <div class="hero-content">
        <div class="hero-tags">
          <span class="tag tag-red">TOP 10 HOJE</span>
          <span class="tag tag-green">🇧🇷 DUBLADO</span>
        </div>
        <h2 id="heroTitle" class="hero-title">Destaque</h2>
        <p id="heroDesc" class="hero-desc">Assista agora no Chromecast.</p>
        <div class="hero-actions">
          <button class="btn-play" onclick="playHero()">▶ Assistir</button>
          <button class="btn-info" onclick="infoHero()">ℹ Episódios</button>
        </div>
      </div>
    </div>

    <div class="section-title">🔥 Séries Populares</div>
    <div id="homeSeries" class="swimlane"></div>

    <div class="section-title">🎬 Filmes Recomendados</div>
    <div id="homeMovies" class="swimlane"></div>

    <div class="section-title">📡 Canais Ao Vivo em Destaque</div>
    <div id="homeChannels" class="swimlane"></div>
  </div>

  <!-- ABA 1: SÉRIES -->
  <div id="tab-series" class="view">
    <input type="text" class="search-box" placeholder="Buscar séries..." oninput="searchCatalog('series', this.value)">
    <div id="seriesGrid" class="grid"></div>
  </div>

  <!-- ABA 2: FILMES -->
  <div id="tab-filmes" class="view">
    <input type="text" class="search-box" placeholder="Buscar filmes..." oninput="searchCatalog('movie', this.value)">
    <div id="moviesGrid" class="grid"></div>
  </div>

  <!-- ABA 3: CANAIS AO VIVO -->
  <div id="tab-canais" class="view">
    <input type="text" class="search-box" placeholder="Filtrar canal..." oninput="filterChannels(this.value)">
    <div id="channelsList"></div>
  </div>

  <!-- ABA 4: CONTROLE REMOTO -->
  <div id="tab-controle" class="view">
    <div class="remote-card">
      <h3 id="remotePlayingTitle" style="font-size: 15px; margin-bottom: 4px;">Nenhuma mídia ativa</h3>
      <p id="remotePlayingSub" style="font-size: 12px; color: #888;">Conectado à TV</p>
      
      <div class="remote-row">
        <button class="remote-btn" onclick="sendCmd('SEEK_BACK')" title="Voltar 10s">⏪</button>
        <button id="remotePlayBtn" class="remote-btn big" onclick="sendCmd('PLAY_PAUSE')">▶</button>
        <button class="remote-btn" onclick="sendCmd('SEEK_FWD')" title="Avançar 30s">⏩</button>
      </div>

      <div class="remote-row">
        <button class="remote-btn" onclick="sendCmd('NEXT_EPISODE')" title="Próximo Episódio">⏭</button>
        <button class="remote-btn" onclick="sendCmd('STOP')" title="Parar TV">⏹</button>
      </div>

      <div style="margin-top: 14px; text-align: left;">
        <label style="font-size: 12px; color: #aaa;">Volume da TV:</label>
        <input type="range" min="0" max="1" step="0.05" class="vol-slider" id="volSlider" onchange="setVolume(this.value)">
      </div>
    </div>
  </div>

  <!-- MINI PLAYER FLUTUANTE (BOTTOM) -->
  <div id="miniPlayer" class="mini-player" style="display:none;">
    <img id="miniPoster" class="mini-poster" src="" alt="">
    <div class="mini-info" onclick="switchTab('controle')">
      <div id="miniTitle" class="mini-title">Título</div>
      <div class="mini-sub">Transmitindo na TV</div>
    </div>
    <button class="mini-btn" onclick="sendCmd('PLAY_PAUSE')" id="miniPlayBtn">⏸</button>
    <button id="miniNextBtn" class="mini-btn red" onclick="sendCmd('NEXT_EPISODE')" title="Próximo Episódio" style="display:none;">⏭</button>
    <button class="mini-btn" onclick="sendCmd('STOP')">⏹</button>
  </div>

  <!-- MODAL DE EPISÓDIOS DA SÉRIE -->
  <div id="seriesModal" class="modal">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="modalSeriesTitle" style="font-size:16px;">Série</h3>
        <button class="modal-close" onclick="closeModal('seriesModal')">&times;</button>
      </div>
      <select id="seasonDropdown" class="season-select" onchange="renderEpisodes()"></select>
      <div id="episodesList"></div>
    </div>
  </div>

  <!-- MODAL DE SELEÇÃO DE FONTES -->
  <div id="streamsModal" class="modal">
    <div class="modal-content">
      <div class="modal-header">
        <h3 id="modalStreamTitle" style="font-size:15px;">Fontes Disponíveis</h3>
        <button class="modal-close" onclick="closeModal('streamsModal')">&times;</button>
      </div>
      <div id="streamsList"></div>
    </div>
  </div>

  <script>
    let appStatus = {};
    let allChannels = [];
    let heroItem = null;
    let seriesEpisodesData = null;
    let currentSeriesMeta = null;

    function switchTab(name) {
      document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
      document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
      document.getElementById('tab-' + name).classList.add('active');
      event.target && event.target.classList.add('active');
      window.scrollTo(0,0);
    }

    function closeModal(id) {
      document.getElementById(id).style.display = 'none';
    }

    async function fetchStatus() {
      try {
        const res = await fetch('/api/status');
        const data = await res.json();
        appStatus = data;
        const dot = document.getElementById('castDot');
        const txt = document.getElementById('castStatusText');
        if (data.connected) {
          dot.classList.add('online');
          txt.innerText = data.castIp || 'Conectado';
        } else {
          dot.classList.remove('online');
          txt.innerText = 'Desconectado';
        }

        const mp = document.getElementById('miniPlayer');
        const nextBtn = document.getElementById('miniNextBtn');
        const playBtn = document.getElementById('miniPlayBtn');
        const rPlayBtn = document.getElementById('remotePlayBtn');

        if (data.currentPlayback) {
          mp.style.display = 'flex';
          document.getElementById('miniTitle').innerText = data.currentPlayback.title;
          document.getElementById('miniPoster').src = data.currentPlayback.poster || '';
          document.getElementById('remotePlayingTitle').innerText = data.currentPlayback.title;
          document.getElementById('remotePlayingSub').innerText = 'Transmitindo na TV • ' + (data.castIp || '');
          if (data.currentPlayback.isSeries) {
            nextBtn.style.display = 'inline-block';
          } else {
            nextBtn.style.display = 'none';
          }
        } else {
          mp.style.display = 'none';
          document.getElementById('remotePlayingTitle').innerText = 'Nenhuma mídia ativa';
          document.getElementById('remotePlayingSub').innerText = 'Selecione um filme, série ou canal';
        }

        const isPlaying = data.playerState === 'PLAYING';
        playBtn.innerText = isPlaying ? '⏸' : '▶';
        rPlayBtn.innerText = isPlaying ? '⏸' : '▶';

        if (data.volume !== undefined) {
          document.getElementById('volSlider').value = data.volume;
        }
      } catch(e) {}
    }

    async function loadHome() {
      try {
        const sRes = await fetch('/api/catalog?type=series');
        const sData = await sRes.json();
        const sMetas = sData.metas || [];
        if (sMetas.length > 0) {
          heroItem = sMetas[0];
          document.getElementById('heroBanner').style.display = 'flex';
          document.getElementById('heroBanner').style.backgroundImage = 'url(' + (heroItem.background || heroItem.poster) + ')';
          document.getElementById('heroTitle').innerText = heroItem.name;
          document.getElementById('heroDesc').innerText = heroItem.description || 'Assista na TV com legendas e áudio dublado.';
          renderSwimlane('homeSeries', sMetas, 'series');
        }

        const mRes = await fetch('/api/catalog?type=movie');
        const mData = await mRes.json();
        renderSwimlane('homeMovies', mData.metas || [], 'movie');

        const chRes = await fetch('/api/channels');
        const chData = await chRes.json();
        allChannels = chData.channels || [];
        renderHomeChannels(allChannels.slice(0, 10));
        renderChannels(allChannels);
      } catch(e) {}
    }

    function renderSwimlane(elemId, list, type) {
      const container = document.getElementById(elemId);
      container.innerHTML = list.slice(0, 12).map(item => `
        <div class="movie-card" onclick="openMedia('${type}', '${item.id}', '${escape(item.name)}', '${item.poster || ''}')">
          <div class="poster-wrap">
            <img class="poster-img" src="${item.poster || ''}" loading="lazy" onerror="this.src='https://placehold.co/105x150/141722/white?text=Capa'">
          </div>
          <div class="card-title">${item.name}</div>
        </div>
      `).join('');
    }

    function renderHomeChannels(channels) {
      const c = document.getElementById('homeChannels');
      c.innerHTML = channels.map(ch => `
        <div class="movie-card" onclick="playChannel('${escape(ch.url)}', '${escape(ch.name)}', '${ch.logo || ''}')">
          <div class="poster-wrap" style="height:100px; display:flex; align-items:center; justify-content:center; padding:8px;">
            <img src="${ch.logo || ''}" style="max-width:80%; max-height:80px; object-fit:contain;" onerror="this.src='https://placehold.co/80x80/141722/white?text=TV'">
          </div>
          <div class="card-title">${ch.name}</div>
        </div>
      `).join('');
    }

    async function searchCatalog(type, query) {
      const res = await fetch(`/api/catalog?type=${type}&search=${encodeURIComponent(query)}`);
      const data = await res.json();
      const list = data.metas || [];
      const gridId = type === 'series' ? 'seriesGrid' : 'moviesGrid';
      document.getElementById(gridId).innerHTML = list.map(item => `
        <div class="movie-card" onclick="openMedia('${type}', '${item.id}', '${escape(item.name)}', '${item.poster || ''}')">
          <div class="poster-wrap">
            <img class="poster-img" src="${item.poster || ''}" loading="lazy" onerror="this.src='https://placehold.co/105x150/141722/white?text=Capa'">
          </div>
          <div class="card-title">${item.name}</div>
        </div>
      `).join('');
    }

    function renderChannels(list) {
      const c = document.getElementById('channelsList');
      c.innerHTML = list.map(ch => `
        <div class="channel-item">
          <div class="ch-info">
            <img class="ch-logo" src="${ch.logo || ''}" onerror="this.src='https://placehold.co/40x40/0A0C10/white?text=TV'">
            <div>
              <div class="ch-name">${ch.name}</div>
              <div class="ch-group">${ch.group}</div>
            </div>
          </div>
          <button class="btn-cast" onclick="playChannel('${escape(ch.url)}', '${escape(ch.name)}', '${ch.logo || ''}')">▶ TV</button>
        </div>
      `).join('');
    }

    function filterChannels(q) {
      const filtered = allChannels.filter(c => c.name.toLowerCase().includes(q.toLowerCase()) || c.group.toLowerCase().includes(q.toLowerCase()));
      renderChannels(filtered);
    }

    async function openMedia(type, id, title, poster) {
      title = unescape(title);
      if (type === 'series') {
        currentSeriesMeta = { id, title, poster };
        document.getElementById('modalSeriesTitle').innerText = title;
        document.getElementById('seriesModal').style.display = 'block';
        document.getElementById('episodesList').innerHTML = '<div style="text-align:center; padding:20px; color:#aaa;">Carregando episódios...</div>';
        
        const res = await fetch(`/api/series?id=${encodeURIComponent(id)}`);
        seriesEpisodesData = await res.json();
        
        const select = document.getElementById('seasonDropdown');
        const seasons = Object.keys(seriesEpisodesData.seasons || {}).sort((a,b) => parseInt(a)-parseInt(b));
        select.innerHTML = seasons.map(s => `<option value="${s}">Temporada ${s}</option>`).join('');
        renderEpisodes();
      } else {
        openStreams(type, id, title, poster);
      }
    }

    function renderEpisodes() {
      if (!seriesEpisodesData || !currentSeriesMeta) return;
      const s = document.getElementById('seasonDropdown').value;
      const episodes = seriesEpisodesData.seasons[s] || [];
      const el = document.getElementById('episodesList');
      el.innerHTML = episodes.map(ep => `
        <div class="ep-item">
          <img class="ep-thumb" src="${ep.thumbnail || currentSeriesMeta.poster}" onerror="this.src='${currentSeriesMeta.poster}'">
          <div class="ep-info">
            <div class="ep-title">E${ep.episode} • ${ep.name || 'Episódio'}</div>
            <div class="ep-desc">${ep.overview || ''}</div>
          </div>
          <button class="btn-cast" onclick="openStreams('series', '${ep.id}', '${escape(currentSeriesMeta.title + ' - T' + s + 'E' + ep.episode + ': ' + ep.name)}', '${currentSeriesMeta.poster}', {seriesId:'${currentSeriesMeta.id}', seriesTitle:'${escape(currentSeriesMeta.title)}', season:${s}, episode:${ep.episode}, allEpisodes:seriesEpisodesData.all})">▶</button>
        </div>
      `).join('');
    }

    async function openStreams(type, id, title, poster, seriesContext) {
      title = unescape(title);
      closeModal('seriesModal');
      document.getElementById('modalStreamTitle').innerText = title;
      document.getElementById('streamsModal').style.display = 'block';
      document.getElementById('streamsList').innerHTML = '<div style="text-align:center; padding:20px; color:#aaa;">Buscando melhores fontes dubladas e legendadas...</div>';

      const res = await fetch(`/api/streams?type=${type}&id=${encodeURIComponent(id)}`);
      const data = await res.json();
      const streams = data.streams || [];
      const subs = data.subtitles || [];
      const defaultSub = subs.length > 0 ? subs[0].url : '';

      if (streams.length === 0) {
        document.getElementById('streamsList').innerHTML = '<div style="text-align:center; padding:20px; color:#aaa;">Nenhuma fonte encontrada nos add-ons.</div>';
        return;
      }

      document.getElementById('streamsList').innerHTML = streams.map(st => `
        <div class="channel-item">
          <div style="flex:1; overflow:hidden;">
            <div style="font-weight:bold; font-size:13px; display:flex; align-items:center; gap:6px;">
              ${st.isPtBr ? '<span class="tag tag-green">🇧🇷 DUBLADO</span>' : ''}
              <span>${st.addon}</span>
            </div>
            <div style="font-size:11px; color:#aaa; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">${st.title}</div>
          </div>
          <button class="btn-cast" onclick="playMedia('${escape(st.url)}', '${escape(title)}', '${poster}', '${escape(defaultSub)}', ${seriesContext ? JSON.stringify(seriesContext) : 'null'})">Assistir na TV</button>
        </div>
      `).join('');
    }

    async function playMedia(url, title, poster, subUrl, seriesContext) {
      url = unescape(url);
      title = unescape(title);
      subUrl = unescape(subUrl);
      closeModal('streamsModal');
      await fetch('/api/play', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url, title, poster, subtitleUrl: subUrl, seriesContext })
      });
      fetchStatus();
      switchTab('controle');
    }

    async function playChannel(url, name, logo) {
      await fetch('/api/play', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: unescape(url), title: unescape(name), poster: logo, type: 'channel' })
      });
      fetchStatus();
      switchTab('controle');
    }

    function playHero() {
      if (heroItem) openMedia(heroItem.type, heroItem.id, escape(heroItem.name), heroItem.poster);
    }
    function infoHero() {
      if (heroItem) openMedia(heroItem.type, heroItem.id, escape(heroItem.name), heroItem.poster);
    }

    async function sendCmd(type) {
      await fetch('/api/cmd', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type })
      });
      fetchStatus();
    }

    async function setVolume(vol) {
      await fetch('/api/volume', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ volume: parseFloat(vol) })
      });
    }

    loadHome();
    searchCatalog('series', '');
    searchCatalog('movie', '');
    fetchStatus();
    setInterval(fetchStatus, 3000);
  </script>
</body>
</html>
''';
}

// ============================================================================
// MOTOR CASTV2 (PORTA 8009) COM DETECÇÃO DE STATUS E TROCA DE FAIXAS
// ============================================================================
class CastTrack {
  final int trackId;
  final String type; // 'AUDIO' ou 'TEXT'
  final String name;
  final String language;

  CastTrack({required this.trackId, required this.type, required this.name, required this.language});
}

class CastV2Client {
  SecureSocket? _socket;
  String? _transportId;
  int? _mediaSessionId;
  int _reqId = 1;
  final List<int> _buffer = [];
  List<CastTrack> availableTracks = [];
  List<int> activeTrackIds = [];
  String playerState = 'IDLE'; // 'PLAYING', 'PAUSED', 'BUFFERING', 'IDLE'

  final void Function(String) onStatus;
  final VoidCallback onTracksChanged;
  final void Function(String state, String? idleReason, double currentTime, double duration)? onMediaStatusUpdate;

  CastV2Client({
    required this.onStatus,
    required this.onTracksChanged,
    this.onMediaStatusUpdate,
  });

  bool get isConnected => _socket != null;
  String get localLanIp => _socket?.address.address ?? '127.0.0.1';

  List<int> _encodeVarint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  List<int> _encodeStringField(int fieldNumber, String value) {
    final bytes = utf8.encode(value);
    final tag = (fieldNumber << 3) | 2;
    return [tag, ..._encodeVarint(bytes.length), ...bytes];
  }

  void _sendProto(String sourceId, String destId, String namespace, Map<String, dynamic> payload) {
    if (_socket == null) return;
    final jsonStr = jsonEncode(payload);
    final body = <int>[
      0x08, 0x00,
      ..._encodeStringField(2, sourceId),
      ..._encodeStringField(3, destId),
      ..._encodeStringField(4, namespace),
      0x28, 0x00,
      ..._encodeStringField(6, jsonStr),
    ];
    final len = body.length;
    final header = [
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
    ];
    _socket!.add(Uint8List.fromList([...header, ...body]));
  }

  Future<void> connect(String ip, {int port = 8009}) async {
    await disconnect();
    onStatus('Conectando ao Chromecast em $ip:$port...');
    try {
      _socket = await SecureSocket.connect(
        ip.trim(),
        port,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 8),
      );

      _socket!.listen(
        _onData,
        onError: (e) => onStatus('Erro de conexão: $e'),
        onDone: () {
          _socket = null;
          onStatus('Chromecast desconectado.');
        },
      );

      _sendProto('sender-0', 'receiver-0', 'urn:x-cast:com.google.cast.tp.connection', {'type': 'CONNECT'});
      _sendProto('sender-0', 'receiver-0', 'urn:x-cast:com.google.cast.receiver', {
        'type': 'LAUNCH',
        'appId': 'CC1AD845',
        'requestId': _reqId++,
      });
      onStatus('Conectado à TV ($ip)!');
    } catch (e) {
      onStatus('Falha ao conectar no IP $ip: $e');
    }
  }

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    while (_buffer.length >= 4) {
      final msgLen = (_buffer[0] << 24) | (_buffer[1] << 16) | (_buffer[2] << 8) | _buffer[3];
      if (_buffer.length < 4 + msgLen) break;
      final packet = _buffer.sublist(4, 4 + msgLen);
      _buffer.removeRange(0, 4 + msgLen);
      _parsePacket(packet);
    }
  }

  void _parsePacket(List<int> bytes) {
    final rawText = utf8.decode(bytes, allowMalformed: true);
    if (rawText.contains('"type":"PING"')) {
      _sendProto('sender-0', 'receiver-0', 'urn:x-cast:com.google.cast.tp.heartbeat', {'type': 'PONG'});
      return;
    }

    final jsonStart = rawText.indexOf('{"');
    if (jsonStart == -1) return;
    try {
      final data = jsonDecode(rawText.substring(jsonStart)) as Map<String, dynamic>;
      final type = data['type'];
      if (type == 'RECEIVER_STATUS') {
        final apps = data['status']?['applications'] as List?;
        if (apps != null && apps.isNotEmpty) {
          final newTransport = apps[0]['transportId'] as String?;
          if (newTransport != null && newTransport != _transportId) {
            _transportId = newTransport;
            _sendProto('sender-0', _transportId!, 'urn:x-cast:com.google.cast.tp.connection', {'type': 'CONNECT'});
          }
        }
      } else if (type == 'MEDIA_STATUS') {
        final stList = data['status'] as List?;
        if (stList != null && stList.isNotEmpty) {
          final st = stList[0] as Map<String, dynamic>;
          _mediaSessionId = st['mediaSessionId'] as int?;
          final pState = (st['playerState'] ?? 'UNKNOWN').toString();
          final idleReason = st['idleReason'] as String?;
          final currentTime = (st['currentTime'] as num?)?.toDouble() ?? 0.0;
          final duration = (st['media']?['duration'] as num?)?.toDouble() ?? 0.0;
          playerState = pState;

          final active = (st['activeTrackIds'] as List?)?.map((e) => (e as num).toInt()).toList() ?? [];
          activeTrackIds = active;

          final rawTracks = st['media']?['tracks'] as List?;
          if (rawTracks != null) {
            availableTracks = rawTracks.map((t) {
              return CastTrack(
                trackId: (t['trackId'] as num).toInt(),
                type: (t['type'] ?? '').toString(),
                name: (t['name'] ?? t['language'] ?? 'Faixa ${t['trackId']}').toString(),
                language: (t['language'] ?? '').toString(),
              );
            }).toList();
          }
          onTracksChanged();
          if (onMediaStatusUpdate != null) {
            onMediaStatusUpdate!(pState, idleReason, currentTime, duration);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> loadMedia(
    String ip,
    String url,
    String title, {
    String poster = '',
    String? vttSubtitleUrl,
    String subtitleLangLabel = 'Português (Brasil)',
  }) async {
    if (_socket == null) {
      await connect(ip);
    }
    if (_transportId == null) {
      _sendProto('sender-0', 'receiver-0', 'urn:x-cast:com.google.cast.receiver', {
        'type': 'LAUNCH',
        'appId': 'CC1AD845',
        'requestId': _reqId++,
      });
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    final target = _transportId ?? 'web-0';
    _sendProto('sender-0', target, 'urn:x-cast:com.google.cast.tp.connection', {'type': 'CONNECT'});

    final isHls = url.toLowerCase().contains('.m3u8');
    final tracks = <Map<String, dynamic>>[];
    final activeIds = <int>[];

    if (vttSubtitleUrl != null && vttSubtitleUrl.isNotEmpty) {
      tracks.add({
        'trackId': 1,
        'type': 'TEXT',
        'trackContentId': vttSubtitleUrl,
        'trackContentType': 'text/vtt',
        'name': subtitleLangLabel,
        'language': 'pt-BR',
        'subtype': 'SUBTITLES',
      });
      activeIds.add(1);
    }

    _sendProto('sender-0', target, 'urn:x-cast:com.google.cast.media', {
      'type': 'LOAD',
      'requestId': _reqId++,
      'autoplay': true,
      'currentTime': 0,
      if (activeIds.isNotEmpty) 'activeTrackIds': activeIds,
      'media': {
        'contentId': url,
        'contentType': isHls ? 'application/x-mpegURL' : 'video/mp4',
        'streamType': isHls ? 'LIVE' : 'BUFFERED',
        if (tracks.isNotEmpty) 'tracks': tracks,
        'textTrackStyle': {
          'backgroundColor': '#000000A0',
          'foregroundColor': '#FFFFFFFF',
          'edgeType': 'OUTLINE',
          'edgeColor': '#000000FF',
          'fontScale': 1.15,
        },
        'metadata': {
          'metadataType': 0,
          'title': title,
          if (poster.isNotEmpty) 'images': [{'url': poster}],
        },
      },
    });
    playerState = 'PLAYING';
    onStatus('Tocando na TV: $title ${vttSubtitleUrl != null ? "(Com Legenda)" : ""}');
  }

  void setActiveTracks(List<int> trackIds) {
    if (_socket == null || _transportId == null) return;
    activeTrackIds = trackIds;
    _sendProto('sender-0', _transportId!, 'urn:x-cast:com.google.cast.media', {
      'type': 'EDIT_TRACKS_INFO',
      'mediaSessionId': _mediaSessionId ?? 1,
      'activeTrackIds': trackIds,
      'requestId': _reqId++,
    });
    onStatus('Faixas de áudio e legenda alteradas na TV!');
    onTracksChanged();
  }

  void sendMediaCmd(String type, {double? seekTime}) {
    if (_socket == null || _transportId == null) return;
    _sendProto('sender-0', _transportId!, 'urn:x-cast:com.google.cast.media', {
      'type': type,
      'mediaSessionId': _mediaSessionId ?? 1,
      if (seekTime != null) 'currentTime': seekTime,
      'requestId': _reqId++,
    });
    if (type == 'PLAY') playerState = 'PLAYING';
    if (type == 'PAUSE') playerState = 'PAUSED';
    if (type == 'STOP') playerState = 'IDLE';
    onStatus('Comando enviado: $type');
  }

  void setVolume(double level) {
    if (_socket == null) return;
    _sendProto('sender-0', 'receiver-0', 'urn:x-cast:com.google.cast.receiver', {
      'type': 'SET_VOLUME',
      'volume': {'level': level.clamp(0.0, 1.0)},
      'requestId': _reqId++,
    });
  }

  Future<void> disconnect() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _transportId = null;
    playerState = 'IDLE';
  }
}

// ============================================================================
// MODELOS: CANAL, SAÚDE DE STREAM, EXTENSÃO E REPRODUÇÃO ATIVA
// ============================================================================
class ChannelItem {
  final String name;
  final String group;
  final String logo;
  final String url;

  ChannelItem({required this.name, required this.group, required this.logo, required this.url});

  Map<String, dynamic> toJson() => {'name': name, 'group': group, 'logo': logo, 'url': url};
  factory ChannelItem.fromJson(Map<String, dynamic> j) => ChannelItem(
        name: j['name'] ?? 'Canal',
        group: j['group'] ?? 'Geral',
        logo: j['logo'] ?? '',
        url: j['url'] ?? '',
      );
}

enum StreamHealthStatus { unknown, checking, online, offline }

class StreamHealth {
  final StreamHealthStatus status;
  final int? latencyMs;
  final String? error;

  const StreamHealth({required this.status, this.latencyMs, this.error});
}

class StremioAddon {
  final String name;
  final String baseUrl;
  bool enabled;

  StremioAddon({required this.name, required this.baseUrl, this.enabled = true});

  Map<String, dynamic> toJson() => {'name': name, 'baseUrl': baseUrl, 'enabled': enabled};
  factory StremioAddon.fromJson(Map<String, dynamic> j) => StremioAddon(
        name: j['name'] ?? 'Add-on',
        baseUrl: j['baseUrl'] ?? '',
        enabled: j['enabled'] ?? true,
      );
}

class ActivePlaybackContext {
  final String type; // 'series', 'movie', 'channel'
  final String title;
  final String poster;
  final String streamUrl;
  final String? seriesId;
  final String? seriesTitle;
  final int? season;
  final int? episode;
  final List<Map<String, dynamic>> allEpisodes;
  final String? vttSubtitleUrl;

  ActivePlaybackContext({
    required this.type,
    required this.title,
    required this.poster,
    required this.streamUrl,
    this.seriesId,
    this.seriesTitle,
    this.season,
    this.episode,
    this.allEpisodes = const [],
    this.vttSubtitleUrl,
  });

  bool get isSeries => type == 'series' && seriesId != null && season != null && episode != null;

  Map<String, dynamic>? findNextEpisode() {
    if (!isSeries) return null;
    // 1. Mesmo temporada, próximo episódio
    for (final ep in allEpisodes) {
      final s = (ep['season'] as num?)?.toInt();
      final e = (ep['episode'] as num?)?.toInt();
      if (s == season && e == episode! + 1) {
        return ep;
      }
    }
    // 2. Primeira temporada seguinte, ep 1
    for (final ep in allEpisodes) {
      final s = (ep['season'] as num?)?.toInt();
      final e = (ep['episode'] as num?)?.toInt();
      if (s == season! + 1 && e == 1) {
        return ep;
      }
    }
    // 3. Qualquer primeiro episódio da próxima temporada
    final nextSeasonEps = allEpisodes.where((ep) {
      final s = (ep['season'] as num?)?.toInt();
      return s == season! + 1;
    }).toList();
    if (nextSeasonEps.isNotEmpty) {
      nextSeasonEps.sort((a, b) => ((a['episode'] as num?) ?? 0).compareTo((b['episode'] as num?) ?? 0));
      return nextSeasonEps.first;
    }
    return null;
  }
}

// ============================================================================
// TELA PRINCIPAL (NETFLIX FLUID DASHBOARD)
// ============================================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _ipCtrl = TextEditingController(text: '192.168.101.7');
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _m3uUrlCtrl = TextEditingController();
  final TextEditingController _addonUrlCtrl = TextEditingController();

  late CastV2Client _cast;
  final LocalSubtitleServer _subServer = LocalSubtitleServer();
  LocalWebRemoteServer? _webServer;
  String _localLanIp = '192.168.101.5';

  String _status = 'Pronto! Conecte à TV ou selecione um conteúdo.';
  double _volume = 0.8;
  int _currentNavIndex = 0; // 0: Início, 1: Séries, 2: Filmes, 3: TV Ao Vivo, 4: Gerenciador

  // Contexto de reprodução atual e Autoplay de Séries
  ActivePlaybackContext? _currentPlayback;
  bool _autoPlayNextSeries = true;
  Timer? _autoPlayCountdownTimer;
  int _autoPlaySecondsLeft = 5;

  // Canais & Teste de Saúde (Health Check)
  List<ChannelItem> _allChannels = [];
  final Map<String, StreamHealth> _healthMap = {};
  bool _isTestingChannels = false;
  int _testProgress = 0;
  int _testTotal = 0;
  bool _filterOnlyOnlineChannels = false;
  String _selectedGroup = 'Todos';
  String _channelSearchQuery = '';

  // Extensões do Stremio
  List<StremioAddon> _stremioAddons = [];

  // Catálogo Stremio
  List<dynamic> _stremioMetas = [];
  List<dynamic> _popularSeries = [];
  List<dynamic> _popularMovies = [];
  String _stremioType = 'series';
  String _audioFilter = 'Todos'; // 'Todos', 'Dublado', 'Original'
  Map<String, dynamic>? _heroFeatured;

  @override
  void initState() {
    super.initState();
    _cast = CastV2Client(
      onStatus: (msg) {
        if (mounted) setState(() => _status = msg);
      },
      onTracksChanged: () {
        if (mounted) setState(() {});
      },
      onMediaStatusUpdate: _handleMediaStatusUpdate,
    );
    _subServer.ensureStarted();
    _detectLocalIp();
    _initDefaultChannels();
    _loadSavedData();
    _loadAddons();
    _fetchNetflixDashboard();
    _initWebServer();
  }

  @override
  void dispose() {
    _webServer?.stop();
    _autoPlayCountdownTimer?.cancel();
    _ipCtrl.dispose();
    _searchCtrl.dispose();
    _m3uUrlCtrl.dispose();
    _addonUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
            setState(() => _localLanIp = addr.address);
            return;
          }
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            setState(() => _localLanIp = addr.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  void _initWebServer() {
    _webServer = LocalWebRemoteServer(
      getChannels: () => _allChannels,
      getHealthMap: () => _healthMap,
      getAddons: () => _stremioAddons,
      getCurrentPlayback: () => _currentPlayback,
      getPlayerState: () => _cast.playerState,
      getVolume: () => _volume,
      getCastIp: () => _ipCtrl.text,
      onPlayMedia: ({required url, required title, poster = '', subtitleUrl, seriesContext}) async {
        String? hostedVtt;
        if (subtitleUrl != null && subtitleUrl.isNotEmpty) {
          try {
            if (!_cast.isConnected) await _cast.connect(_ipCtrl.text);
            hostedVtt = await _subServer.hostSubtitleFromUrl(subtitleUrl, _cast.localLanIp);
          } catch (_) {}
        }
        await _cast.loadMedia(
          _ipCtrl.text,
          url,
          title,
          poster: poster,
          vttSubtitleUrl: hostedVtt,
        );
        if (mounted) {
          setState(() {
            _currentPlayback = ActivePlaybackContext(
              type: seriesContext != null ? 'series' : 'movie',
              title: title,
              poster: poster,
              streamUrl: url,
              seriesId: seriesContext?['seriesId'],
              seriesTitle: seriesContext?['seriesTitle'],
              season: (seriesContext?['season'] as num?)?.toInt(),
              episode: (seriesContext?['episode'] as num?)?.toInt(),
              allEpisodes: (seriesContext?['allEpisodes'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e)).toList() ?? [],
              vttSubtitleUrl: hostedVtt,
            );
          });
        }
      },
      onMediaCmd: (cmd) async {
        if (cmd == 'PLAY_PAUSE') {
          if (_cast.playerState == 'PLAYING') {
            _cast.sendMediaCmd('PAUSE');
          } else {
            _cast.sendMediaCmd('PLAY');
          }
        } else if (cmd == 'NEXT_EPISODE') {
          await _skipToNextEpisode();
        } else if (cmd == 'SEEK_BACK') {
          _cast.sendMediaCmd('SEEK');
        } else if (cmd == 'SEEK_FWD') {
          _cast.sendMediaCmd('SEEK');
        } else if (cmd == 'STOP') {
          _cast.sendMediaCmd('STOP');
          if (mounted) setState(() => _currentPlayback = null);
        } else {
          _cast.sendMediaCmd(cmd);
        }
      },
      onSetVolume: (vol) async {
        setState(() => _volume = vol);
        _cast.setVolume(vol);
      },
      onTestChannels: (channels) async {
        await _startBatchChannelCheck(channels);
      },
    );
    _webServer!.start(port: 8080);
  }

  // Lista padrão verificada do Brasil
  void _initDefaultChannels() {
    _allChannels = [
      ChannelItem(
        name: 'SBT Nacional HD',
        group: 'Canais Abertos',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/9/93/Sistema_Brasileiro_de_Televis%C3%A3o_logo.svg',
        url: 'https://cdn.live.br1.jmvstream.com/w/LVW-10801/LVW10801_Xvg4R0u57n/chunklist.m3u8',
      ),
      ChannelItem(
        name: 'TV Cultura Fast HD',
        group: 'Canais Abertos',
        logo: 'https://upload.wikimedia.org/wikipedia/pt/c/c5/TV_Cultura_logo.png',
        url: 'https://fpa-gateway.tvcultura.com.br:8181/memfs/606caef0-a290-413d-9f1f-8fcdb3a73831.m3u8',
      ),
      ChannelItem(
        name: 'CNN Brasil (1080p)',
        group: 'Notícias',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/6/66/CNN_Brasil_logo.svg',
        url: 'https://d25usgadhphvwi.cloudfront.net/hls/main.m3u8',
      ),
      ChannelItem(
        name: 'Record News HD',
        group: 'Notícias',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/4/4e/Record_News_logo_2023.png',
        url: 'http://45.162.64.114/RECORD_NEWS/index.m3u8',
      ),
      ChannelItem(
        name: 'RedeTV! Paraná HD',
        group: 'Canais Abertos',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/1/15/RedeTV%21_logo.png',
        url: 'https://tv01.zas.media:1936/redetvparana/redetvparana/playlist.m3u8',
      ),
      ChannelItem(
        name: 'TV Brasil HD',
        group: 'Canais Abertos',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/7/77/TV_Brasil_logo_2023.png',
        url: 'http://45.162.64.114/TV_BRASIL/index.m3u8',
      ),
      ChannelItem(
        name: 'Canal Futura',
        group: 'Canais Abertos',
        logo: 'https://upload.wikimedia.org/wikipedia/pt/e/e0/Canal_Futura_logo.png',
        url: 'http://45.162.64.114/FUTURA/index.m3u8',
      ),
      ChannelItem(
        name: 'Jovem Pan News HD',
        group: 'Notícias',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/e/eb/Jovem_Pan_News_logo_2021.png',
        url: 'http://170.83.49.66:8083/JOVEMPANNEWSHD/index.m3u8',
      ),
      ChannelItem(
        name: 'SBT News Ao Vivo',
        group: 'Notícias',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/9/93/Sistema_Brasileiro_de_Televis%C3%A3o_logo.svg',
        url: 'https://dai.google.com/linear/hls/event/1XSOdtQ0SH2G8OEmEfGgjQ/master.m3u8',
      ),
      ChannelItem(
        name: 'Filmes Sucessos (Pluto TV)',
        group: 'Filmes',
        logo: 'https://images.pluto.tv/channels/5f120e94a5714d00074576a1/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-5f120e94a5714d00074576a1.m3u8',
      ),
      ChannelItem(
        name: 'Filmes Aventura (Pluto TV)',
        group: 'Filmes',
        logo: 'https://images.pluto.tv/channels/66c79a4262e5510008ff68a5/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-66c79a4262e5510008ff68a5.m3u8',
      ),
      ChannelItem(
        name: 'Netmovies TV Filmes HD',
        group: 'Filmes',
        logo: 'https://images.pluto.tv/channels/663b9de4f999220008230fa8/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-663b9de4f999220008230fa8.m3u8',
      ),
      ChannelItem(
        name: 'Cine Clássicos HD',
        group: 'Filmes',
        logo: 'https://images.pluto.tv/channels/5fa1612a669ba0000702017b/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-5fa1612a669ba0000702017b.m3u8',
      ),
      ChannelItem(
        name: 'Malhação Fast (Globo)',
        group: 'Séries & Novelas',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/8/82/TV_Globo_2021.svg',
        url: 'https://dfr80qz435crc.cloudfront.net/EFGH/Amagi/Globo/Malhacao_Fast_BR/576p-vtt/index.m3u8',
      ),
      ChannelItem(
        name: 'Os Dez Mandamentos 24h',
        group: 'Séries & Novelas',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/9/90/RecordTV_logo_2016.png',
        url: 'https://cc-38amk5g6kmcpo.akamaized.net/Os_Dez_Mandamentos.m3u8',
      ),
      ChannelItem(
        name: 'A Terra Prometida 24h',
        group: 'Séries & Novelas',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/9/90/RecordTV_logo_2016.png',
        url: 'https://dfr80qz435crc.cloudfront.net/IJKL/Amagi/Samsung/ATerraPrometida_BR/ATerraPrometida.m3u8',
      ),
      ChannelItem(
        name: 'Desenhos Clássicos 24h',
        group: 'Desenhos & Kids',
        logo: 'https://images.pluto.tv/channels/655e5c4d2c46f3000877a54b/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-655e5c4d2c46f3000877a54b.m3u8',
      ),
      ChannelItem(
        name: 'Anime Ação 24h',
        group: 'Animes',
        logo: 'https://images.pluto.tv/channels/604b79c558393100078faeef/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-604b79c558393100078faeef.m3u8',
      ),
      ChannelItem(
        name: 'Comedy Central Brasil',
        group: 'Entretenimento',
        logo: 'https://upload.wikimedia.org/wikipedia/commons/1/1a/Comedy_Central_2018_logo.svg',
        url: 'https://stmv2.srvif.com/gafeab/gafeab/playlist.m3u8',
      ),
      ChannelItem(
        name: 'Tastemade Brasil 24h',
        group: 'Entretenimento',
        logo: 'https://images.pluto.tv/channels/5fd1419a3b4f4b000773ba85/colorLogoPNG.png',
        url: 'https://jmp2.uk/plu-5fd1419a3b4f4b000773ba85.m3u8',
      ),
      ChannelItem(
        name: 'Red Bull TV (Esportes HLS)',
        group: 'Esportes',
        logo: 'https://images.pluto.tv/channels/5ad9b648e738977e2c312131/colorLogoPNG.png',
        url: 'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8',
      ),
    ];
  }

  // ==========================================================================
  // CARREGAMENTO & PERSISTÊNCIA (CHANNELS, ADDONS, IP)
  // ==========================================================================
  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('cast_ip');
    if (savedIp != null && savedIp.isNotEmpty) _ipCtrl.text = savedIp;
    _autoPlayNextSeries = prefs.getBool('autoplay_series') ?? true;

    final savedCh = prefs.getString('channels_json_v2');
    if (savedCh != null) {
      try {
        final list = jsonDecode(savedCh) as List;
        if (list.isNotEmpty) {
          setState(() {
            _allChannels = list.map((e) => ChannelItem.fromJson(e)).toList();
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cast_ip', _ipCtrl.text.trim());
    await prefs.setBool('autoplay_series', _autoPlayNextSeries);
    final subset = _allChannels.take(5000).map((e) => e.toJson()).toList();
    await prefs.setString('channels_json_v2', jsonEncode(subset));
  }

  Future<void> _loadAddons() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('stremio_addons_v2');
    if (saved != null) {
      try {
        final list = jsonDecode(saved) as List;
        setState(() {
          _stremioAddons = list.map((e) => StremioAddon.fromJson(e)).toList();
        });
        return;
      } catch (_) {}
    }

    _stremioAddons = [
      StremioAddon(name: 'BestCine (Dublado PT-BR)', baseUrl: 'https://bestcine.dpdns.org'),
      StremioAddon(name: 'Torrentio (Prioridade Dublado PT-BR)', baseUrl: 'https://torrentio.strem.fun/language=portuguese|sort=qualitysize'),
      StremioAddon(name: 'Cinemeta (Filmes & Séries)', baseUrl: 'https://v3-cinemeta.strem.io'),
      StremioAddon(name: 'OpenSubtitles v3 (Legendas PT-BR)', baseUrl: 'https://opensubtitles-v3.strem.io'),
      StremioAddon(name: 'Anime Kitsu', baseUrl: 'https://anime-kitsu.strem.fun'),
    ];
    _saveAddons();
  }

  Future<void> _saveAddons() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_stremioAddons.map((a) => a.toJson()).toList());
    await prefs.setString('stremio_addons_v2', raw);
  }

  void _removeAddon(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Text('Remover Extensão', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Deseja realmente remover "${_stremioAddons[index].name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _stremioAddons.removeAt(index);
              });
              _saveAddons();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Extensão removida com sucesso!')),
              );
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }

  Future<void> _installStremioAddon(String rawUrl) async {
    var u = rawUrl.trim().replaceAll('stremio://', 'https://');
    if (u.endsWith('/configure')) u = '${u.substring(0, u.length - 10)}/manifest.json';
    if (!u.endsWith('/manifest.json')) u = '$u/manifest.json';
    try {
      final res = await http.get(Uri.parse(u));
      final manifest = jsonDecode(res.body);
      final baseUrl = u.substring(0, u.length - '/manifest.json'.length);
      final newAddon = StremioAddon(name: manifest['name'] ?? 'Add-on Stremio', baseUrl: baseUrl);
      setState(() {
        _stremioAddons.add(newAddon);
        _status = 'Extensão ${newAddon.name} adicionada!';
      });
      _saveAddons();
      _addonUrlCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extensão "${newAddon.name}" instalada com sucesso!')),
        );
      }
    } catch (e) {
      setState(() => _status = 'Erro ao instalar extensão: $e');
    }
  }

  // ==========================================================================
  // CATÁLOGO & DASHBOARD NETFLIX
  // ==========================================================================
  Future<void> _fetchNetflixDashboard() async {
    try {
      // 1. Séries Populares
      final sRes = await http.get(Uri.parse('https://v3-cinemeta.strem.io/catalog/series/top.json'));
      if (sRes.statusCode == 200) {
        final sData = jsonDecode(sRes.body)['metas'] as List? ?? [];
        if (mounted) {
          setState(() {
            _popularSeries = sData;
            if (_heroFeatured == null && sData.isNotEmpty) {
              _heroFeatured = sData.first;
            }
          });
        }
      }

      // 2. Filmes Populares
      final mRes = await http.get(Uri.parse('https://v3-cinemeta.strem.io/catalog/movie/top.json'));
      if (mRes.statusCode == 200) {
        final mData = jsonDecode(mRes.body)['metas'] as List? ?? [];
        if (mounted) {
          setState(() {
            _popularMovies = mData;
          });
        }
      }

      _fetchCatalogType();
    } catch (_) {}
  }

  Future<void> _fetchCatalogType({String search = ''}) async {
    final extra = search.trim().isNotEmpty ? '/search=${Uri.encodeComponent(search.trim())}.json' : '.json';
    final url = 'https://v3-cinemeta.strem.io/catalog/$_stremioType/top$extra';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _stremioMetas = data['metas'] ?? []);
      }
    } catch (_) {}
  }

  // ==========================================================================
  // VERIFICADOR DE SAÚDE DOS CANAIS (HEALTH CHECK ENGINE)
  // ==========================================================================
  Future<StreamHealth> _testStream(String url) async {
    final sw = Stopwatch()..start();
    try {
      final client = http.Client();
      final req = http.Request('GET', Uri.parse(url.trim()));
      req.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
      req.headers['Range'] = 'bytes=0-1024';
      final streamedRes = await client.send(req).timeout(const Duration(milliseconds: 3500));
      sw.stop();
      client.close();
      if (streamedRes.statusCode >= 200 && streamedRes.statusCode < 400) {
        return StreamHealth(status: StreamHealthStatus.online, latencyMs: sw.elapsedMilliseconds);
      } else {
        return StreamHealth(status: StreamHealthStatus.offline, error: 'HTTP ${streamedRes.statusCode}');
      }
    } catch (_) {
      sw.stop();
      return const StreamHealth(status: StreamHealthStatus.offline, error: 'Sem Sinal');
    }
  }

  Future<void> _startBatchChannelCheck(List<ChannelItem> channels) async {
    if (_isTestingChannels || channels.isEmpty) return;
    setState(() {
      _isTestingChannels = true;
      _testProgress = 0;
      _testTotal = channels.length;
      _status = 'Iniciando teste de ${channels.length} canais...';
    });

    final queue = List<ChannelItem>.from(channels);

    Future<void> worker() async {
      while (queue.isNotEmpty && _isTestingChannels) {
        final ch = queue.removeAt(0);
        if (mounted) {
          setState(() {
            _healthMap[ch.url] = const StreamHealth(status: StreamHealthStatus.checking);
          });
        }
        final res = await _testStream(ch.url);
        if (mounted) {
          setState(() {
            _healthMap[ch.url] = res;
            _testProgress++;
          });
        }
      }
    }

    final workers = List.generate(5, (_) => worker());
    await Future.wait(workers);

    if (mounted) {
      final onlineTotal = _healthMap.values.where((h) => h.status == StreamHealthStatus.online).length;
      setState(() {
        _isTestingChannels = false;
        _status = 'Teste concluído! $onlineTotal/${channels.length} canais 100% funcionais.';
      });
    }
  }

  void _removeOfflineChannels() {
    final offlineUrls = _healthMap.entries
        .where((e) => e.value.status == StreamHealthStatus.offline)
        .map((e) => e.key)
        .toSet();

    if (offlineUrls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhum canal offline detectado. Execute o teste primeiro!')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Text('Limpar Canais Offline', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Deseja excluir definitivamente ${offlineUrls.length} canais que estão fora do ar?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _allChannels.removeWhere((c) => offlineUrls.contains(c.url));
              });
              _saveChannels();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${offlineUrls.length} canais offline removidos da lista!')),
              );
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }

  void _deleteSingleChannel(ChannelItem item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Text('Remover Canal', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Deseja excluir o canal "${item.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _allChannels.removeWhere((c) => c.url == item.url);
              });
              _saveChannels();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Canal "${item.name}" removido.')),
              );
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }

  void _clearAllChannels() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Text('Limpar Toda a Lista de Canais', style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Esta ação excluirá todos os canais atuais. Você poderá restaurar os canais padrão a qualquer momento.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _allChannels.clear();
                _healthMap.clear();
              });
              _saveChannels();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Lista de canais limpa com sucesso.')),
              );
            },
            child: const Text('Limpar Tudo'),
          ),
        ],
      ),
    );
  }

  void _restoreDefaultChannels() {
    setState(() {
      _initDefaultChannels();
    });
    _saveChannels();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Canais padrão do Brasil restaurados com sucesso!')),
    );
  }

  Future<void> _importM3uFromUrl(String url, String fallbackGroup) async {
    setState(() => _status = 'Baixando lista M3U8...');
    try {
      final res = await http.get(Uri.parse(url.trim()));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      _parseM3uContent(utf8.decode(res.bodyBytes, allowMalformed: true), fallbackGroup);
    } catch (e) {
      setState(() => _status = 'Erro ao baixar lista: $e');
    }
  }

  void _parseM3uContent(String raw, String fallbackGroup) {
    final lines = raw.replaceAll('\r', '').split('\n');
    final added = <ChannelItem>[];
    String? currName;
    String currLogo = '';
    String currGroup = fallbackGroup;
    final regLogo = RegExp(r'tvg-logo="([^"]+)"');
    final regGroup = RegExp(r'group-title="([^"]+)"');

    for (final rawLine in lines) {
      final ln = rawLine.trim();
      if (ln.isEmpty) continue;
      if (ln.startsWith('#EXTINF:')) {
        currLogo = regLogo.firstMatch(ln)?.group(1) ?? '';
        currGroup = regGroup.firstMatch(ln)?.group(1) ?? fallbackGroup;
        final commaIdx = ln.lastIndexOf(',');
        currName = commaIdx != -1 ? ln.substring(commaIdx + 1).trim() : 'Canal';
      } else if (!ln.startsWith('#') && ln.startsWith('http')) {
        added.add(ChannelItem(
          name: currName ?? 'Canal ${added.length + 1}',
          group: currGroup.isEmpty ? fallbackGroup : currGroup,
          logo: currLogo,
          url: ln,
        ));
        currName = null;
        currLogo = '';
      }
    }

    setState(() {
      _allChannels = [...added, ..._allChannels];
      _status = '${added.length} canais importados!';
    });
    _saveChannels();
  }

  // ==========================================================================
  // AUTOPLAY & CONTINUIDADE DE SÉRIES
  // ==========================================================================
  void _handleMediaStatusUpdate(String state, String? idleReason, double currentTime, double duration) {
    if (!mounted) return;

    // Se o episódio terminou e temos uma série em reprodução
    if (state == 'IDLE' && idleReason == 'FINISHED') {
      if (_autoPlayNextSeries && _currentPlayback != null && _currentPlayback!.isSeries) {
        final nextEp = _currentPlayback!.findNextEpisode();
        if (nextEp != null) {
          _triggerAutoPlayCountdown(nextEp);
        } else {
          setState(() {
            _status = 'Você assistiu ao último episódio disponível da série!';
          });
        }
      }
    }
  }

  void _triggerAutoPlayCountdown(Map<String, dynamic> nextEp) {
    _autoPlayCountdownTimer?.cancel();
    setState(() {
      _autoPlaySecondsLeft = 5;
    });

    final sNum = (nextEp['season'] as num?)?.toInt() ?? 1;
    final epNum = (nextEp['episode'] as num?)?.toInt() ?? 1;
    final epName = (nextEp['name'] ?? nextEp['title'] ?? 'Episódio $epNum').toString();

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF141722),
        duration: const Duration(seconds: 6),
        content: StatefulBuilder(
          builder: (ctx, setSnackState) {
            return Row(
              children: [
                const Icon(Icons.skip_next, color: Color(0xFFE50914), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Próximo Episódio: T${sNum}E$epNum',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Text(
                        'Reproduzindo em $_autoPlaySecondsLeft s: $epName',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _autoPlayCountdownTimer?.cancel();
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    setState(() => _status = 'Autoplay cancelado.');
                  },
                  child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
                  onPressed: () {
                    _autoPlayCountdownTimer?.cancel();
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    _playNextEpisode(nextEp);
                  },
                  child: const Text('Tocar Agora'),
                ),
              ],
            );
          },
        ),
      ),
    );

    _autoPlayCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_autoPlaySecondsLeft <= 1) {
        timer.cancel();
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _playNextEpisode(nextEp);
      } else {
        setState(() {
          _autoPlaySecondsLeft--;
        });
      }
    });
  }

  Future<void> _skipToNextEpisode() async {
    if (_currentPlayback == null || !_currentPlayback!.isSeries) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhuma série ativa para avançar episódio.')),
      );
      return;
    }

    final nextEp = _currentPlayback!.findNextEpisode();
    if (nextEp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Este é o último episódio disponível.')),
      );
      return;
    }

    _autoPlayCountdownTimer?.cancel();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _playNextEpisode(nextEp);
  }

  Future<void> _playNextEpisode(Map<String, dynamic> nextEp) async {
    final cur = _currentPlayback;
    if (cur == null || cur.seriesId == null) return;

    final seriesId = cur.seriesId!;
    final seriesTitle = cur.seriesTitle ?? 'Série';
    final sNum = (nextEp['season'] as num?)?.toInt() ?? 1;
    final epNum = (nextEp['episode'] as num?)?.toInt() ?? 1;
    final epName = (nextEp['name'] ?? nextEp['title'] ?? 'Episódio $epNum').toString();
    final epId = (nextEp['id'] ?? '$seriesId:$sNum:$epNum').toString();
    final fullTitle = '$seriesTitle - T${sNum}E$epNum: $epName';

    setState(() => _status = 'Buscando fontes para $fullTitle...');

    // Busca streams nos addons ativos
    final streams = <Map<String, dynamic>>[];
    for (final a in _stremioAddons.where((addon) => addon.enabled)) {
      try {
        final u = '${a.baseUrl}/stream/series/${Uri.encodeComponent(epId)}.json';
        final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final list = jsonDecode(r.body)['streams'] as List? ?? [];
          for (final s in list) {
            final directUrl = s['url']?.toString();
            final infoHash = s['infoHash']?.toString();
            final fileIdx = s['fileIdx'] ?? 0;
            final desc = '${s['name'] ?? ''} ${s['title'] ?? ''}'.trim();
            final upper = desc.toUpperCase();
            final isPtBr = upper.contains('DUBLADO') ||
                upper.contains('DUAL') ||
                upper.contains('PT-BR') ||
                upper.contains('PORTUGUES') ||
                upper.contains('🇧🇷') ||
                upper.contains('🇵🇹');

            String? playable = directUrl;
            if ((playable == null || playable.isEmpty) && infoHash != null) {
              playable = 'http://${_cast.localLanIp}:11470/$infoHash/$fileIdx';
            }
            if (playable != null && playable.isNotEmpty) {
              streams.add({
                'addon': a.name,
                'title': desc,
                'url': playable,
                'isPtBr': isPtBr,
              });
            }
          }
        }
      } catch (_) {}
    }

    if (streams.isEmpty) {
      setState(() => _status = 'Nenhuma fonte encontrada para o próximo episódio.');
      return;
    }

    // Ordena priorizando dublado PT-BR
    streams.sort((a, b) => (b['isPtBr'] ? 1 : 0).compareTo(a['isPtBr'] ? 1 : 0));
    final chosenStream = streams.first;

    // Busca legenda PT-BR
    String? hostedVtt;
    try {
      final subUrl = 'https://opensubtitles-v3.strem.io/subtitles/series/${Uri.encodeComponent(epId)}.json';
      final sr = await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds: 8));
      if (sr.statusCode == 200) {
        final rawSubs = jsonDecode(sr.body)['subtitles'] as List? ?? [];
        for (final sub in rawSubs) {
          final lang = (sub['lang'] ?? '').toString().toLowerCase();
          final u = (sub['url'] ?? '').toString();
          if (u.isNotEmpty && (lang.contains('pob') || lang.contains('pt') || lang.contains('bra'))) {
            if (!_cast.isConnected) await _cast.connect(_ipCtrl.text);
            hostedVtt = await _subServer.hostSubtitleFromUrl(u, _cast.localLanIp);
            break;
          }
        }
      }
    } catch (_) {}

    await _cast.loadMedia(
      _ipCtrl.text,
      chosenStream['url'].toString(),
      fullTitle,
      poster: cur.poster,
      vttSubtitleUrl: hostedVtt,
    );

    setState(() {
      _currentPlayback = ActivePlaybackContext(
        type: 'series',
        title: fullTitle,
        poster: cur.poster,
        streamUrl: chosenStream['url'].toString(),
        seriesId: seriesId,
        seriesTitle: seriesTitle,
        season: sNum,
        episode: epNum,
        allEpisodes: cur.allEpisodes,
        vttSubtitleUrl: hostedVtt,
      );
    });
  }

  // ==========================================================================
  // SELEÇÃO DE MÍDIA, TEMPORADAS, EPISÓDIOS E FONTES
  // ==========================================================================
  Future<void> _openMediaItem(String type, String id, String title, String poster) async {
    if (type == 'series') {
      await _showSeriesSeasonEpisodePicker(id, title, poster);
    } else {
      await _showStreamsAndSubtitlesPicker(type, id, title, poster);
    }
  }

  Future<void> _showSeriesSeasonEpisodePicker(String seriesId, String seriesTitle, String poster) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141722),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (ctx, scrollCtrl) {
            return FutureBuilder<Map<String, dynamic>>(
              future: () async {
                final bySeason = <int, List<Map<String, dynamic>>>{};
                final allEps = <Map<String, dynamic>>[];
                final u = 'https://v3-cinemeta.strem.io/meta/series/${Uri.encodeComponent(seriesId)}.json';
                final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 10));
                if (r.statusCode == 200) {
                  final videos = jsonDecode(r.body)['meta']?['videos'] as List? ?? [];
                  for (final v in videos) {
                    final sNum = (v['season'] as num?)?.toInt() ?? 1;
                    if (sNum == 0) continue;
                    final map = Map<String, dynamic>.from(v);
                    bySeason.putIfAbsent(sNum, () => []).add(map);
                    allEps.add(map);
                  }
                }
                for (final k in bySeason.keys) {
                  bySeason[k]!.sort((a, b) => ((a['episode'] as num?) ?? 0).compareTo((b['episode'] as num?) ?? 0));
                }
                return {'bySeason': bySeason, 'allEpisodes': allEps};
              }(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)));
                }
                final seasonsMap = snap.data!['bySeason'] as Map<int, List<Map<String, dynamic>>>;
                final allEpisodes = snap.data!['allEpisodes'] as List<Map<String, dynamic>>;
                final seasonNumbers = seasonsMap.keys.toList()..sort();
                if (seasonNumbers.isEmpty) {
                  return const Center(child: Text('Nenhum episódio encontrado para esta série.'));
                }
                int selectedSeason = seasonNumbers.first;

                return StatefulBuilder(
                  builder: (ctx, setModalState) {
                    final episodes = seasonsMap[selectedSeason] ?? [];
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 60,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(4),
                                  image: poster.isNotEmpty ? DecorationImage(image: NetworkImage(poster), fit: BoxFit.cover) : null,
                                  color: Colors.grey[900],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      seriesTitle,
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${episodes.length} episódios • Autoplay ativado',
                                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                                    ),
                                  ],
                                ),
                              ),
                              DropdownButton<int>(
                                value: selectedSeason,
                                dropdownColor: const Color(0xFF0A0C10),
                                underline: const SizedBox(),
                                items: seasonNumbers
                                    .map((s) => DropdownMenuItem(value: s, child: Text('Temporada $s', style: const TextStyle(fontWeight: FontWeight.bold))))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) setModalState(() => selectedSeason = val);
                                },
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          Expanded(
                            child: ListView.builder(
                              controller: scrollCtrl,
                              itemCount: episodes.length,
                              itemBuilder: (ctx, i) {
                                final ep = episodes[i];
                                final epNum = ep['episode'] ?? (i + 1);
                                final epName = (ep['name'] ?? ep['title'] ?? 'Episódio $epNum').toString();
                                final epId = (ep['id'] ?? '$seriesId:$selectedSeason:$epNum').toString();
                                final overview = ep['overview']?.toString() ?? '';
                                final thumb = ep['thumbnail']?.toString() ?? '';

                                return Card(
                                  color: const Color(0xFF0F1118),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    leading: thumb.isNotEmpty
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: Image.network(thumb, width: 70, height: 45, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie)),
                                          )
                                        : Container(
                                            width: 45,
                                            height: 45,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(color: const Color(0xFFE50914), borderRadius: BorderRadius.circular(6)),
                                            child: Text('E$epNum', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                          ),
                                    title: Text('T${selectedSeason}E$epNum • $epName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                    subtitle: overview.isNotEmpty
                                        ? Text(overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white60))
                                        : null,
                                    trailing: const Icon(Icons.play_circle_fill, color: Color(0xFFE50914), size: 30),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _showStreamsAndSubtitlesPicker(
                                        'series',
                                        epId,
                                        '$seriesTitle - T${selectedSeason}E$epNum: $epName',
                                        poster,
                                        seriesContext: {
                                          'seriesId': seriesId,
                                          'seriesTitle': seriesTitle,
                                          'season': selectedSeason,
                                          'episode': epNum,
                                          'allEpisodes': allEpisodes,
                                        },
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showStreamsAndSubtitlesPicker(
    String type,
    String videoId,
    String title,
    String poster, {
    Map<String, dynamic>? seriesContext,
  }) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141722),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (ctx, scrollCtrl) {
            return FutureBuilder<Map<String, dynamic>>(
              future: () async {
                final streams = <Map<String, dynamic>>[];
                final subtitles = <Map<String, String>>[];

                // Busca streams nos addons ativos
                for (final a in _stremioAddons.where((addon) => addon.enabled)) {
                  try {
                    final u = '${a.baseUrl}/stream/$type/${Uri.encodeComponent(videoId)}.json';
                    final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
                    if (r.statusCode == 200) {
                      final list = jsonDecode(r.body)['streams'] as List? ?? [];
                      for (final s in list) {
                        final directUrl = s['url']?.toString();
                        final infoHash = s['infoHash']?.toString();
                        final fileIdx = s['fileIdx'] ?? 0;
                        final desc = '${s['name'] ?? ''} ${s['title'] ?? ''}'.trim();
                        final upper = desc.toUpperCase();
                        final isPtBr = upper.contains('DUBLADO') ||
                            upper.contains('DUAL') ||
                            upper.contains('PT-BR') ||
                            upper.contains('PORTUGUES') ||
                            upper.contains('🇧🇷') ||
                            upper.contains('🇵🇹');

                        String? playable = directUrl;
                        if ((playable == null || playable.isEmpty) && infoHash != null) {
                          playable = 'http://${_cast.localLanIp}:11470/$infoHash/$fileIdx';
                        }
                        if (playable != null && playable.isNotEmpty) {
                          streams.add({
                            'addon': a.name,
                            'title': desc,
                            'url': playable,
                            'isPtBr': isPtBr,
                          });
                        }
                      }
                    }
                  } catch (_) {}
                }

                streams.sort((a, b) => (b['isPtBr'] ? 1 : 0).compareTo(a['isPtBr'] ? 1 : 0));

                // Busca legendas
                try {
                  final subUrl = 'https://opensubtitles-v3.strem.io/subtitles/$type/${Uri.encodeComponent(videoId)}.json';
                  final sr = await http.get(Uri.parse(subUrl)).timeout(const Duration(seconds: 8));
                  if (sr.statusCode == 200) {
                    final rawSubs = jsonDecode(sr.body)['subtitles'] as List? ?? [];
                    for (final sub in rawSubs) {
                      final lang = (sub['lang'] ?? '').toString().toLowerCase();
                      final u = (sub['url'] ?? '').toString();
                      if (u.isEmpty) continue;
                      String label = lang;
                      int priority = 3;
                      if (lang.contains('pob') || lang.contains('pt') || lang.contains('por') || lang.contains('bra')) {
                        label = '🇧🇷 Português ($lang)';
                        priority = 0;
                      } else if (lang.contains('eng')) {
                        label = '🇺🇸 Inglês ($lang)';
                        priority = 1;
                      } else if (lang.contains('spa') || lang.contains('es')) {
                        label = '🇪🇸 Espanhol ($lang)';
                        priority = 2;
                      }
                      subtitles.add({'label': label, 'url': u, 'priority': priority.toString()});
                    }
                    subtitles.sort((a, b) => a['priority']!.compareTo(b['priority']!));
                  }
                } catch (_) {}

                return {'streams': streams, 'subtitles': subtitles};
              }(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)));
                }
                final allStreams = snap.data!['streams'] as List<Map<String, dynamic>>;
                final allSubs = snap.data!['subtitles'] as List<Map<String, String>>;
                String selectedSubUrl = allSubs.isNotEmpty && allSubs.first['priority'] == '0' ? allSubs.first['url']! : '';

                return StatefulBuilder(
                  builder: (ctx, setModalState) {
                    final filteredStreams = allStreams.where((s) {
                      if (_audioFilter == 'Dublado') return s['isPtBr'] == true;
                      if (_audioFilter == 'Original') return s['isPtBr'] == false;
                      return true;
                    }).toList();

                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), maxLines: 2),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _audioFilter,
                                  decoration: const InputDecoration(labelText: 'Filtro de Áudio', isDense: true),
                                  items: const [
                                    DropdownMenuItem(value: 'Todos', child: Text('🎧 Todos os Áudios')),
                                    DropdownMenuItem(value: 'Dublado', child: Text('🇧🇷 Dublado / Dual PT-BR')),
                                    DropdownMenuItem(value: 'Original', child: Text('🇺🇸 Áudio Original')),
                                  ],
                                  onChanged: (v) => setModalState(() => _audioFilter = v ?? 'Todos'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: selectedSubUrl,
                                  decoration: const InputDecoration(labelText: 'Legenda PT-BR', isDense: true),
                                  items: [
                                    const DropdownMenuItem(value: '', child: Text('Sem Legenda')),
                                    ...allSubs.take(25).map((s) => DropdownMenuItem(
                                          value: s['url']!,
                                          child: Text(s['label']!, overflow: TextOverflow.ellipsis),
                                        )),
                                  ],
                                  onChanged: (v) => setModalState(() => selectedSubUrl = v ?? ''),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          Expanded(
                            child: filteredStreams.isEmpty
                                ? const Center(
                                    child: Text('Nenhuma fonte disponível com este filtro. Mude para "Todos os Áudios".'),
                                  )
                                : ListView.builder(
                                    controller: scrollCtrl,
                                    itemCount: filteredStreams.length,
                                    itemBuilder: (ctx, i) {
                                      final st = filteredStreams[i];
                                      final isPt = st['isPtBr'] == true;
                                      return Card(
                                        color: const Color(0xFF0F1118),
                                        margin: const EdgeInsets.only(bottom: 8),
                                        child: ListTile(
                                          title: Row(
                                            children: [
                                              if (isPt)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  margin: const EdgeInsets.only(right: 8),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF10B981),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text('🇧🇷 DUBLADO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                                ),
                                              Expanded(child: Text(st['addon'].toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                                            ],
                                          ),
                                          subtitle: Text(st['title'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
                                          trailing: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
                                            icon: const Icon(Icons.cast, size: 18),
                                            label: const Text('Assistir'),
                                            onPressed: () async {
                                              Navigator.pop(ctx);
                                              String? hostedVtt;
                                              if (selectedSubUrl.isNotEmpty) {
                                                setState(() => _status = 'Convertendo legenda para WebVTT...');
                                                try {
                                                  if (!_cast.isConnected) await _cast.connect(_ipCtrl.text);
                                                  hostedVtt = await _subServer.hostSubtitleFromUrl(selectedSubUrl, _cast.localLanIp);
                                                } catch (_) {}
                                              }
                                              await _cast.loadMedia(
                                                _ipCtrl.text,
                                                st['url'].toString(),
                                                title,
                                                poster: poster,
                                                vttSubtitleUrl: hostedVtt,
                                              );

                                              setState(() {
                                                _currentPlayback = ActivePlaybackContext(
                                                  type: type,
                                                  title: title,
                                                  poster: poster,
                                                  streamUrl: st['url'].toString(),
                                                  seriesId: seriesContext?['seriesId'],
                                                  seriesTitle: seriesContext?['seriesTitle'],
                                                  season: seriesContext?['season'],
                                                  episode: seriesContext?['episode'],
                                                  allEpisodes: (seriesContext?['allEpisodes'] as List<Map<String, dynamic>>?) ?? [],
                                                  vttSubtitleUrl: hostedVtt,
                                                );
                                              });
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ==========================================================================
  // CONSTRUÇÃO VISUAL (UI NETFLIX)
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            // Logo estilo Netflix
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE50914),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'STREAMIO',
                style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5, fontSize: 13, color: Colors.white),
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'CAST',
              style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 2, fontSize: 14, color: Colors.white70),
            ),
            const Spacer(),
            // Botão Acesso iPhone / Celular
            InkWell(
              onTap: _showIphoneAccessDialog,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF141722),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE50914).withOpacity(0.6)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.phone_iphone, size: 16, color: Color(0xFFE50914)),
                    SizedBox(width: 4),
                    Text(
                      '📱 iPhone / Web',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            // Chip de Conexão Chromecast
            InkWell(
              onTap: _showChromecastConnectDialog,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF141722),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _cast.isConnected ? const Color(0xFF10B981) : Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cast,
                      size: 16,
                      color: _cast.isConnected ? const Color(0xFF10B981) : Colors.white60,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _cast.isConnected ? _ipCtrl.text : 'Conectar TV',
                      style: TextStyle(
                        fontSize: 12,
                        color: _cast.isConnected ? const Color(0xFF10B981) : Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _navTabButton(0, 'Início', Icons.home_filled),
                  _navTabButton(1, 'Séries', Icons.tv),
                  _navTabButton(2, 'Filmes', Icons.movie),
                  _navTabButton(3, 'TV Ao Vivo (${_allChannels.length})', Icons.live_tv),
                  _navTabButton(4, 'Gerenciador', Icons.tune),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Conteúdo da aba selecionada
          Positioned.fill(
            bottom: _currentPlayback != null ? 76 : 0,
            child: IndexedStack(
              index: _currentNavIndex,
              children: [
                _buildNetflixHomeDashboard(),
                _buildCatalogView('series'),
                _buildCatalogView('movie'),
                _buildLiveChannelsView(),
                _buildManagerView(),
              ],
            ),
          ),

          // Mini-Player Flutuante na TV
          if (_currentPlayback != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              child: _buildMiniPlayer(),
            ),
        ],
      ),
    );
  }

  Widget _navTabButton(int index, String label, IconData icon) {
    final isSelected = _currentNavIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.white60),
        label: Text(label),
        selected: isSelected,
        selectedColor: const Color(0xFFE50914),
        backgroundColor: const Color(0xFF141722),
        labelStyle: TextStyle(
          color: isSelected ? Colors.white : Colors.white70,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 13,
        ),
        onSelected: (_) {
          setState(() {
            _currentNavIndex = index;
            if (index == 1) {
              _stremioType = 'series';
              _fetchCatalogType();
            } else if (index == 2) {
              _stremioType = 'movie';
              _fetchCatalogType();
            }
          });
        },
      ),
    );
  }

  // ==========================================================================
  // ABA 0: INÍCIO (DASHBOARD COMPLETO NETFLIX)
  // ==========================================================================
  Widget _buildNetflixHomeDashboard() {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // 1. Hero Billboard em Destaque
        if (_heroFeatured != null) _buildHeroBillboard(_heroFeatured!),

        const SizedBox(height: 16),

        // 2. Trilho: 🔥 Séries em Alta
        _buildContentSwimlane(
          title: '🔥 Séries Populares no Brasil',
          items: _popularSeries,
          type: 'series',
        ),

        const SizedBox(height: 20),

        // 3. Trilho: 🎬 Filmes em Destaque
        _buildContentSwimlane(
          title: '🎬 Filmes Mais Assistidos',
          items: _popularMovies,
          type: 'movie',
        ),

        const SizedBox(height: 20),

        // 4. Trilho: 📡 TV Ao Vivo Brasil (Top Canais)
        _buildLiveTvSwimlane(),

        const SizedBox(height: 30),
      ],
    );
  }

  Widget _buildHeroBillboard(Map<String, dynamic> item) {
    final title = (item['name'] ?? 'Destaque').toString();
    final poster = (item['poster'] ?? '').toString();
    final background = (item['background'] ?? poster).toString();
    final desc = (item['description'] ?? 'Assista na sua TV com áudio dublado e legendas completas no Chromecast.').toString();
    final id = (item['id'] ?? '').toString();
    final type = (item['type'] ?? 'series').toString();

    return Container(
      height: 340,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF141722),
        image: background.isNotEmpty ? DecorationImage(image: NetworkImage(background), fit: BoxFit.cover, alignment: Alignment.topCenter) : null,
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              const Color(0xFF0A0C10).withOpacity(0.4),
              const Color(0xFF0A0C10).withOpacity(0.9),
              const Color(0xFF0A0C10),
            ],
            stops: const [0.0, 0.4, 0.8, 1.0],
          ),
        ),
        padding: const EdgeInsets.all(20),
        alignment: Alignment.bottomLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFE50914), borderRadius: BorderRadius.circular(3)),
                  child: const Text('TOP 10 HOJE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3)),
                  child: const Text('HD 1080p', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF10B981), borderRadius: BorderRadius.circular(3)),
                  child: const Text('🇧🇷 DUBLADO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              desc,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                  icon: const Icon(Icons.play_arrow, color: Colors.black),
                  label: const Text('Assistir Agora', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () => _openMediaItem(type, id, title, poster),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white12,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Ver Detalhes / Episódios'),
                  onPressed: () => _openMediaItem(type, id, title, poster),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentSwimlane({required String title, required List<dynamic> items, required String type}) {
    if (items.isEmpty) return const SizedBox();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
        ),
        SizedBox(
          height: 190,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.take(15).length,
            itemBuilder: (ctx, i) {
              final m = items[i];
              final name = (m['name'] ?? 'Título').toString();
              final poster = (m['poster'] ?? '').toString();
              final id = (m['id'] ?? '').toString();

              return Container(
                width: 115,
                margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openMediaItem(type, id, name, poster),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              poster.isNotEmpty
                                  ? Image.network(poster, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 36))
                                  : const Icon(Icons.movie, size: 36),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                                  child: const Text('HD', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLiveTvSwimlane() {
    if (_allChannels.isEmpty) return const SizedBox();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('📡 Canais Ao Vivo em Destaque', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              TextButton(
                onPressed: () => setState(() => _currentNavIndex = 3),
                child: const Text('Ver Todos', style: TextStyle(color: Color(0xFFE50914))),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 120,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _allChannels.take(10).length,
            itemBuilder: (ctx, i) {
              final ch = _allChannels[i];
              final health = _healthMap[ch.url];

              return Container(
                width: 170,
                margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                child: Card(
                  color: const Color(0xFF141722),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _cast.loadMedia(_ipCtrl.text, ch.url, ch.name, poster: ch.logo),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(color: const Color(0xFF10B981), borderRadius: BorderRadius.circular(3)),
                                child: const Text('AO VIVO', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                              ),
                              const Spacer(),
                              _buildHealthBadge(health),
                            ],
                          ),
                          const Spacer(),
                          Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          Text(ch.group, style: const TextStyle(fontSize: 11, color: Colors.white60)),
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
    );
  }

  // ==========================================================================
  // ABA 1 & 2: CATÁLOGOS SÉRIES / FILMES
  // ==========================================================================
  Widget _buildCatalogView(String type) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: type == 'series' ? 'Buscar séries...' : 'Buscar filmes...',
              prefixIcon: const Icon(Icons.search, color: Colors.white60),
              isDense: true,
              filled: true,
              fillColor: const Color(0xFF141722),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => _fetchCatalogType(search: v),
          ),
        ),
        Expanded(
          child: _stremioMetas.isEmpty
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)))
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: 0.65,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _stremioMetas.length,
                  itemBuilder: (ctx, i) {
                    final m = _stremioMetas[i];
                    final name = (m['name'] ?? 'Título').toString();
                    final poster = (m['poster'] ?? '').toString();
                    final id = (m['id'] ?? '').toString();
                    final itemType = (m['type'] ?? type).toString();

                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _openMediaItem(itemType, id, name, poster),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: poster.isNotEmpty
                                  ? Image.network(poster, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 48))
                                  : const Icon(Icons.movie, size: 48),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ==========================================================================
  // ABA 3: CANAIS AO VIVO COM VERIFICADOR DE SAÚDE E GERENCIAMENTO
  // ==========================================================================
  Widget _buildLiveChannelsView() {
    final groups = ['Todos', ...{for (final c in _allChannels) c.group}];
    final filtered = _allChannels.where((c) {
      final matchGroup = _selectedGroup == 'Todos' || c.group == _selectedGroup;
      final matchSearch = _channelSearchQuery.isEmpty || c.name.toLowerCase().contains(_channelSearchQuery.toLowerCase());
      final isOnline = _healthMap[c.url]?.status == StreamHealthStatus.online;
      final matchOnline = !_filterOnlyOnlineChannels || isOnline;
      return matchGroup && matchSearch && matchOnline;
    }).toList();

    final onlineTotal = _healthMap.values.where((h) => h.status == StreamHealthStatus.online).length;
    final offlineTotal = _healthMap.values.where((h) => h.status == StreamHealthStatus.offline).length;

    return Column(
      children: [
        // Barra Superior de Controles e Health Check
        Container(
          color: const Color(0xFF141722),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Filtrar canal...',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF0A0C10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                      ),
                      onChanged: (v) => setState(() => _channelSearchQuery = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: groups.contains(_selectedGroup) ? _selectedGroup : 'Todos',
                    dropdownColor: const Color(0xFF141722),
                    items: groups
                        .take(50)
                        .map((g) => DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedGroup = v ?? 'Todos'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Botão Testar Canais
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isTestingChannels ? Colors.grey[800] : const Color(0xFF10B981),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: _isTestingChannels
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.speed, size: 16),
                    label: Text(
                      _isTestingChannels ? 'Testando $_testProgress/$_testTotal...' : 'Testar Canais',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _isTestingChannels ? () => setState(() => _isTestingChannels = false) : () => _startBatchChannelCheck(filtered),
                  ),
                  const SizedBox(width: 8),
                  // Filtro Apenas Online
                  FilterChip(
                    label: Text('Apenas Online ($onlineTotal)', style: const TextStyle(fontSize: 11)),
                    selected: _filterOnlyOnlineChannels,
                    selectedColor: const Color(0xFF10B981).withOpacity(0.3),
                    onSelected: (v) => setState(() => _filterOnlyOnlineChannels = v),
                  ),
                  const Spacer(),
                  // Limpar Offline
                  if (offlineTotal > 0)
                    IconButton(
                      icon: const Icon(Icons.cleaning_services, color: Color(0xFFE50914), size: 20),
                      tooltip: 'Remover $offlineTotal canais offline',
                      onPressed: _removeOfflineChannels,
                    ),
                  // Menu de Gerenciar
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) {
                      if (v == 'restore') _restoreDefaultChannels();
                      if (v == 'clear') _clearAllChannels();
                    },
                    itemBuilder: (ctx) => const [
                      PopupMenuItem(value: 'restore', child: Text('Restaurar Padrões Brasil')),
                      PopupMenuItem(value: 'clear', child: Text('Limpar Todos os Canais')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),

        // Lista de Canais
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('Nenhum canal encontrado com os filtros selecionados.'))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final ch = filtered[idx];
                    final health = _healthMap[ch.url];

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: ListTile(
                        leading: ch.logo.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(ch.logo, width: 44, height: 44, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.tv)),
                              )
                            : const Icon(Icons.tv, color: Color(0xFFE50914)),
                        title: Text(ch.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: Text(ch.group, style: const TextStyle(fontSize: 12, color: Colors.white60)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildHealthBadge(health),
                            const SizedBox(width: 8),
                            // Testar individual
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 18),
                              tooltip: 'Verificar sinal deste canal',
                              onPressed: () async {
                                setState(() => _healthMap[ch.url] = const StreamHealth(status: StreamHealthStatus.checking));
                                final res = await _testStream(ch.url);
                                setState(() => _healthMap[ch.url] = res);
                              },
                            ),
                            // Excluir Canal
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white54),
                              tooltip: 'Excluir canal',
                              onPressed: () => _deleteSingleChannel(ch),
                            ),
                            // Tocar na TV
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              ),
                              child: const Text('TV', style: TextStyle(fontWeight: FontWeight.bold)),
                              onPressed: () {
                                _cast.loadMedia(_ipCtrl.text, ch.url, ch.name, poster: ch.logo);
                                setState(() {
                                  _currentPlayback = ActivePlaybackContext(
                                    type: 'channel',
                                    title: ch.name,
                                    poster: ch.logo,
                                    streamUrl: ch.url,
                                  );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHealthBadge(StreamHealth? health) {
    if (health == null || health.status == StreamHealthStatus.unknown) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
        child: const Text('⚪ Não testado', style: TextStyle(fontSize: 10, color: Colors.white70)),
      );
    }
    if (health.status == StreamHealthStatus.checking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.blue.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
        child: const Text('🔄 Testando...', style: TextStyle(fontSize: 10, color: Colors.blueAccent)),
      );
    }
    if (health.status == StreamHealthStatus.online) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFF10B981).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
        child: Text('🟢 ${health.latencyMs ?? 0}ms', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: const Color(0xFFE50914).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
      child: Text('🔴 ${health.error ?? "Offline"}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFE50914))),
    );
  }

  // ==========================================================================
  // ABA 4: GERENCIADOR (ADD-ONS STREMIO, M3U, IP E AUTOPLAY)
  // ==========================================================================
  Widget _buildManagerView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Card de Acesso do iPhone
        Card(
          color: const Color(0xFF1A1D2B),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.phone_iphone, size: 40, color: Color(0xFFE50914)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Acesso pelo iPhone / Celular (Safari)',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'http://$_localLanIp:${_webServer?.port ?? 8080}',
                        style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Abra no Safari do iPhone para navegar e controlar na TV.',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
                  onPressed: _showIphoneAccessDialog,
                  child: const Text('Ver QR Code'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // 1. Configurações de Reprodução & Autoplay de Séries
        const Text('1. Reprodução & Continuidade de Séries', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Autoplay de Séries (Pular para Próximo Ep)', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Ao terminar o episódio, reproduz o próximo automaticamente com contagem regressiva.'),
                value: _autoPlayNextSeries,
                activeColor: const Color(0xFFE50914),
                onChanged: (v) {
                  setState(() => _autoPlayNextSeries = v);
                  _saveChannels();
                },
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text('IP do Chromecast'),
                subtitle: Text(_ipCtrl.text),
                trailing: ElevatedButton(
                  onPressed: _showChromecastConnectDialog,
                  child: const Text('Alterar / Conectar'),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // 2. Extensões Stremio Instaladas (com opção de Remoção)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('2. Extensões do Stremio Instaladas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            TextButton.icon(
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Restaurar Padrão'),
              onPressed: () {
                _loadAddons();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Extensões padrão restauradas.')));
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._stremioAddons.asMap().entries.map((entry) {
          final idx = entry.key;
          final addon = entry.value;
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: Icon(Icons.extension, color: addon.enabled ? const Color(0xFFE50914) : Colors.grey),
              title: Text(addon.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(addon.baseUrl, style: const TextStyle(fontSize: 11, color: Colors.white54), overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: addon.enabled,
                    activeColor: const Color(0xFFE50914),
                    onChanged: (v) {
                      setState(() => addon.enabled = v);
                      _saveAddons();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Color(0xFFE50914)),
                    tooltip: 'Remover extensão',
                    onPressed: () => _removeAddon(idx),
                  ),
                ],
              ),
            ),
          );
        }),

        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addonUrlCtrl,
                decoration: const InputDecoration(labelText: 'Instalar URL da Extensão (manifest.json)', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
              onPressed: () => _installStremioAddon(_addonUrlCtrl.text),
              child: const Text('Instalar'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            ActionChip(label: const Text('🎬 BestCine'), onPressed: () => _installStremioAddon('https://bestcine.dpdns.org/manifest.json')),
            ActionChip(label: const Text('⚡ Torrentio'), onPressed: () => _installStremioAddon('https://torrentio.strem.fun/language=portuguese|sort=qualitysize/manifest.json')),
            ActionChip(label: const Text('💬 OpenSubtitles v3'), onPressed: () => _installStremioAddon('https://opensubtitles-v3.strem.io/manifest.json')),
            ActionChip(label: const Text('🍙 Anime Kitsu'), onPressed: () => _installStremioAddon('https://anime-kitsu.strem.fun/manifest.json')),
          ],
        ),

        const SizedBox(height: 24),

        // 3. Importação de Listas M3U8
        const Text('3. Importar Nova Lista M3U8', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _m3uUrlCtrl,
                decoration: const InputDecoration(labelText: 'Colar URL .m3u / .m3u8', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _importM3uFromUrl(_m3uUrlCtrl.text, 'Importada'),
              child: const Text('Importar'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            ActionChip(label: const Text('🇧🇷 IPTV-org Brasil'), onPressed: () => _importM3uFromUrl('https://iptv-org.github.io/iptv/countries/br.m3u', 'Brasil Aberta')),
            ActionChip(label: const Text('🇧🇷 Free-TV Brasil'), onPressed: () => _importM3uFromUrl('https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_brazil.m3u8', 'Free-TV')),
            ActionChip(label: const Text('📺 Pluto TV BR'), onPressed: () => _importM3uFromUrl('https://github.com/iprtl/m3u/raw/live/Pluto.m3u', 'Pluto TV')),
          ],
        ),
      ],
    );
  }

  // ==========================================================================
  // MINI-PLAYER FLUTUANTE (NETFLIX BOTTOM BAR)
  // ==========================================================================
  Widget _buildMiniPlayer() {
    final cur = _currentPlayback;
    if (cur == null) return const SizedBox();

    final isPlaying = _cast.playerState == 'PLAYING';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141722).withOpacity(0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE50914).withOpacity(0.6)),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Row(
        children: [
          // Pôster
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: cur.poster.isNotEmpty
                ? Image.network(cur.poster, width: 44, height: 56, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie))
                : Container(width: 44, height: 56, color: Colors.grey[900], child: const Icon(Icons.tv)),
          ),
          const SizedBox(width: 12),
          // Título e Transmissão
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cur.title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Transmitindo na TV • ${_ipCtrl.text}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF10B981)),
                ),
              ],
            ),
          ),
          // Botão -10s
          IconButton(
            icon: const Icon(Icons.replay_10, size: 22),
            onPressed: () => _cast.sendMediaCmd('SEEK'),
          ),
          // Play / Pause
          IconButton(
            icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: const Color(0xFFE50914), size: 34),
            onPressed: () {
              if (isPlaying) {
                _cast.sendMediaCmd('PAUSE');
              } else {
                _cast.sendMediaCmd('PLAY');
              }
            },
          ),
          // Botão +30s
          IconButton(
            icon: const Icon(Icons.forward_30, size: 22),
            onPressed: () => _cast.sendMediaCmd('SEEK'),
          ),
          // BOTÃO PRÓXIMO EPISÓDIO (SÉRIES)
          if (cur.isSeries)
            IconButton(
              icon: const Icon(Icons.skip_next, color: Color(0xFFE50914), size: 28),
              tooltip: 'Pular para o Próximo Episódio',
              onPressed: _skipToNextEpisode,
            ),
          // Parar
          IconButton(
            icon: const Icon(Icons.stop, size: 20),
            onPressed: () {
              _cast.sendMediaCmd('STOP');
              setState(() => _currentPlayback = null);
            },
          ),
        ],
      ),
    );
  }

  void _showIphoneAccessDialog() {
    final port = _webServer?.port ?? 8080;
    final webUrl = 'http://$_localLanIp:$port';
    final qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${Uri.encodeComponent(webUrl)}';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Row(
          children: [
            Icon(Icons.phone_iphone, color: Color(0xFFE50914)),
            SizedBox(width: 8),
            Text('Acesso pelo iPhone / Celular', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Aponte a câmera do iPhone para conectar instantaneamente:',
              style: TextStyle(fontSize: 13, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: Image.network(
                qrUrl,
                width: 180,
                height: 180,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.qr_code, size: 120, color: Colors.black),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Ou abra o Safari e digite o endereço:', style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 4),
            SelectableText(
              webUrl,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0C10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.tips_and_updates, color: Colors.amber, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No Safari, toque no botão Compartilhar e selecione "Adicionar à Tela de Início" para virar um app nativo!',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }

  void _showChromecastConnectDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141722),
        title: const Text('Conectar ao Chromecast', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ipCtrl,
              decoration: const InputDecoration(labelText: 'Endereço IP (ex: 192.168.101.7)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Volume TV:'),
                Expanded(
                  child: Slider(
                    value: _volume,
                    activeColor: const Color(0xFFE50914),
                    onChanged: (v) {
                      setState(() => _volume = v);
                      _cast.setVolume(v);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE50914)),
            onPressed: () {
              Navigator.pop(ctx);
              _saveChannels();
              _cast.connect(_ipCtrl.text);
            },
            child: const Text('Conectar Agora'),
          ),
        ],
      ),
    );
  }
}
