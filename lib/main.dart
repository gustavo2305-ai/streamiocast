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
      title: 'Central Chromecast 2015 v2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7C3AED),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF151E32),
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
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen((HttpRequest req) {
      req.response.headers.add('Access-Control-Allow-Origin', '*');
      req.response.headers.add('Access-Control-Allow-Methods', 'GET, OPTIONS');
      req.response.headers.add('Access-Control-Allow-Headers', '*');
      req.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
      req.response.write(_currentVtt);
      req.response.close();
    });
  }

  String srtToWebVtt(String raw) {
    var txt = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceFirst('\uFEFF', '');
    if (txt.trimLeft().startsWith('WEBVTT')) return txt;
    // Converte timestamps SRT (00:01:20,500) para WebVTT (00:01:20.500)
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
// MOTOR CASTV2 (PORTA 8009) COM SUPORTE A LEGENDAS E FAIXAS DE ÁUDIO
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

  final void Function(String) onStatus;
  final VoidCallback onTracksChanged;

  CastV2Client({required this.onStatus, required this.onTracksChanged});

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
    onStatus('Conectando a $ip:$port...');
    _socket = await SecureSocket.connect(
      ip.trim(),
      port,
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 8),
    );

    _socket!.listen(
      _onData,
      onError: (e) => onStatus('Erro no socket: $e'),
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
    onStatus('Conectado ao Chromecast ($ip)!');
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
          'backgroundColor': '#00000080',
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
    onStatus('Idioma / Legenda atualizado na TV!');
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
  }
}

// ============================================================================
// MODELOS E INTERFACE PRINCIPAL
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
  String _status = 'Pronto! Conecte ao Chromecast ou escolha um título.';
  double _volume = 0.8;

  List<ChannelItem> _allChannels = [
    // CANAIS ABERTOS & NOTÍCIAS
    ChannelItem(
      name: 'CNN Brasil (1080p)',
      group: 'Notícias',
      logo: 'https://upload.wikimedia.org/wikipedia/commons/6/66/CNN_Brasil_logo.svg',
      url: 'https://d25usgadhphvwi.cloudfront.net/hls/main.m3u8',
    ),
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

    // FILMES & SÉRIES 24H (DUBLADO PT-BR)
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
      name: 'Runtime TV & Filmes HD',
      group: 'Filmes',
      logo: 'https://image.tmdb.org/t/p/w600_and_h900_bestv2/uVEFQvFMMsg4e6yb03xOfVsDz4o.jpg',
      url: 'https://stream.ads.ottera.tv/playlist.m3u8?network_id=2153',
    ),
    ChannelItem(
      name: 'Runtime CinEspanto (Terror)',
      group: 'Filmes',
      logo: 'https://image.tmdb.org/t/p/w600_and_h900_bestv2/uVEFQvFMMsg4e6yb03xOfVsDz4o.jpg',
      url: 'https://stream.ads.ottera.tv/playlist.m3u8?network_id=4865',
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

    // DESENHOS, ANIMES, ESPORTES & ENTRETENIMENTO
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

  String _selectedGroup = 'Todos';
  String _searchQuery = '';
  String _audioFilter = 'Todos'; // 'Todos', 'Dublado', 'Original'

  List<Map<String, dynamic>> _stremioAddons = [
    {'name': 'BestCine (Dublado PT-BR)', 'baseUrl': 'https://bestcine.dpdns.org'},
    {'name': 'Torrentio (Prioridade Dublado PT-BR)', 'baseUrl': 'https://torrentio.strem.fun/language=portuguese|sort=qualitysize'},
    {'name': 'Cinemeta (Filmes & Séries)', 'baseUrl': 'https://v3-cinemeta.strem.io'},
    {'name': 'OpenSubtitles v3 (Legendas PT-BR)', 'baseUrl': 'https://opensubtitles-v3.strem.io'},
    {'name': 'Anime Kitsu', 'baseUrl': 'https://anime-kitsu.strem.fun'},
  ];
  List<dynamic> _stremioMetas = [];
  String _stremioType = 'movie';

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
    );
    _subServer.ensureStarted();
    _loadSavedData();
    _fetchStremioCatalog();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('cast_ip');
    if (savedIp != null && savedIp.isNotEmpty) _ipCtrl.text = savedIp;
    final savedCh = prefs.getString('channels_json');
    if (savedCh != null) {
      try {
        final list = jsonDecode(savedCh) as List;
        setState(() {
          _allChannels = list.map((e) => ChannelItem.fromJson(e)).toList();
        });
      } catch (_) {}
    }
  }

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cast_ip', _ipCtrl.text.trim());
    final subset = _allChannels.take(5000).map((e) => e.toJson()).toList();
    await prefs.setString('channels_json', jsonEncode(subset));
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
    final lines = raw.split(RegExp(r'\r?\n'));
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
      _status = '${added.length} canais importados com sucesso!';
    });
    _saveChannels();
  }

  Future<void> _fetchStremioCatalog({String search = ''}) async {
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

  Future<void> _installStremioAddon(String rawUrl) async {
    var u = rawUrl.trim().replaceAll('stremio://', 'https://');
    if (u.endsWith('/configure')) u = '${u.substring(0, u.length - 10)}/manifest.json';
    if (!u.endsWith('/manifest.json')) u = '$u/manifest.json';
    try {
      final res = await http.get(Uri.parse(u));
      final manifest = jsonDecode(res.body);
      final baseUrl = u.substring(0, u.length - '/manifest.json'.length);
      setState(() {
        _stremioAddons.add({'name': manifest['name'] ?? 'Add-on', 'baseUrl': baseUrl});
        _status = 'Add-on ${manifest['name']} instalado!';
      });
      _addonUrlCtrl.clear();
    } catch (e) {
      setState(() => _status = 'Erro no add-on: $e');
    }
  }

  // ==========================================================================
  // PASSO 1: SE FOR SÉRIE, ABRE SELETOR DE TEMPORADA E EPISÓDIO
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
      backgroundColor: const Color(0xFF151E32),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (ctx, scrollCtrl) {
            return FutureBuilder<Map<int, List<Map<String, dynamic>>>>(
              future: () async {
                final bySeason = <int, List<Map<String, dynamic>>>{};
                final u = 'https://v3-cinemeta.strem.io/meta/series/${Uri.encodeComponent(seriesId)}.json';
                final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 10));
                if (r.statusCode == 200) {
                  final videos = jsonDecode(r.body)['meta']?['videos'] as List? ?? [];
                  for (final v in videos) {
                    final sNum = (v['season'] as num?)?.toInt() ?? 1;
                    if (sNum == 0) continue; // Ignora especiais (season 0) por padrão
                    bySeason.putIfAbsent(sNum, () => []).add(Map<String, dynamic>.from(v));
                  }
                }
                for (final k in bySeason.keys) {
                  bySeason[k]!.sort((a, b) => ((a['episode'] as num?) ?? 0).compareTo((b['episode'] as num?) ?? 0));
                }
                return bySeason;
              }(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final seasonsMap = snap.data!;
                final seasonNumbers = seasonsMap.keys.toList()..sort();
                if (seasonNumbers.isEmpty) {
                  return const Center(child: Text('Nenhum episódio encontrado para esta série.'));
                }
                int selectedSeason = seasonNumbers.first;

                return StatefulBuilder(
                  builder: (ctx, setModalState) {
                    final episodes = seasonsMap[selectedSeason] ?? [];
                    return Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  seriesTitle,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              DropdownButton<int>(
                                value: selectedSeason,
                                dropdownColor: const Color(0xFF090D16),
                                items: seasonNumbers
                                    .map((s) => DropdownMenuItem(value: s, child: Text('Temporada $s')))
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) setModalState(() => selectedSeason = val);
                                },
                              ),
                            ],
                          ),
                          const Divider(),
                          Expanded(
                            child: ListView.builder(
                              controller: scrollCtrl,
                              itemCount: episodes.length,
                              itemBuilder: (ctx, i) {
                                final ep = episodes[i];
                                final epNum = ep['episode'] ?? (i + 1);
                                final epName = (ep['name'] ?? ep['title'] ?? 'Episódio $epNum').toString();
                                final epId = (ep['id'] ?? '$seriesId:$selectedSeason:$epNum').toString();
                                return Card(
                                  color: const Color(0xFF090D16),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: const Color(0xFF7C3AED),
                                      child: Text('E$epNum', style: const TextStyle(fontSize: 12)),
                                    ),
                                    title: Text('T${selectedSeason}E$epNum - $epName', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: ep['overview'] != null
                                        ? Text(ep['overview'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis)
                                        : null,
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      _showStreamsAndSubtitlesPicker(
                                        'series',
                                        epId,
                                        '$seriesTitle - T${selectedSeason}E$epNum',
                                        poster,
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

  // ==========================================================================
  // PASSO 2: SELETOR DE IDIOMA (DUBLADO/ORIGINAL), LEGENDA PT-BR E FONTES
  // ==========================================================================
  Future<void> _showStreamsAndSubtitlesPicker(String type, String videoId, String title, String poster) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151E32),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (ctx, scrollCtrl) {
            return FutureBuilder<Map<String, dynamic>>(
              future: () async {
                final streams = <Map<String, dynamic>>[];
                final subtitles = <Map<String, String>>[];

                // 1. Busca streams em todos os add-ons instalados
                for (final a in _stremioAddons) {
                  try {
                    final u = '${a['baseUrl']}/stream/$type/${Uri.encodeComponent(videoId)}.json';
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
                        bool isTorrent = false;
                        if ((playable == null || playable.isEmpty) && infoHash != null) {
                          // Usa o Stremio Server se estiver aberto na rede local (:11470)
                          playable = 'http://${_cast.localLanIp}:11470/$infoHash/$fileIdx';
                          isTorrent = true;
                        }
                        if (playable != null && playable.isNotEmpty) {
                          streams.add({
                            'addon': a['name'].toString(),
                            'title': desc,
                            'url': playable,
                            'isPtBr': isPtBr,
                            'isTorrent': isTorrent,
                          });
                        }
                      }
                    }
                  } catch (_) {}
                }

                // Ordena colocando streams Dublados / Dual PT-BR no topo
                streams.sort((a, b) => (b['isPtBr'] ? 1 : 0).compareTo(a['isPtBr'] ? 1 : 0));

                // 2. Busca legendas no OpenSubtitles v3
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
                  return const Center(child: CircularProgressIndicator());
                }
                final allStreams = snap.data!['streams'] as List<Map<String, dynamic>>;
                final allSubs = snap.data!['subtitles'] as List<Map<String, String>>;
                String selectedSubUrl = allSubs.isNotEmpty && allSubs.first['priority'] == '0'
                    ? allSubs.first['url']!
                    : '';

                return StatefulBuilder(
                  builder: (ctx, setModalState) {
                    final filteredStreams = allStreams.where((s) {
                      if (_audioFilter == 'Dublado') return s['isPtBr'] == true;
                      if (_audioFilter == 'Original') return s['isPtBr'] == false;
                      return true;
                    }).toList();

                    return Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 10),
                          // SELETOR DE LEGENDA E FILTRO DE ÁUDIO
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
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: selectedSubUrl,
                                  decoration: const InputDecoration(labelText: 'Legenda (OpenSubtitles)', isDense: true),
                                  items: [
                                    const DropdownMenuItem(value: '', child: Text('Sem Legenda')),
                                    ...allSubs.take(30).map((s) => DropdownMenuItem(
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
                                    child: Text('Nenhuma fonte encontrada com este filtro de idioma. Mude para "Todos os Áudios".'),
                                  )
                                : ListView.builder(
                                    controller: scrollCtrl,
                                    itemCount: filteredStreams.length,
                                    itemBuilder: (ctx, i) {
                                      final st = filteredStreams[i];
                                      final isPt = st['isPtBr'] == true;
                                      return Card(
                                        color: const Color(0xFF090D16),
                                        child: ListTile(
                                          title: Row(
                                            children: [
                                              if (isPt)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  margin: const EdgeInsets.only(right: 6),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF059669),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text('🇧🇷 PT-BR / DUAL', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                                ),
                                              Expanded(child: Text(st['addon'].toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                                            ],
                                          ),
                                          subtitle: Text(st['title'].toString()),
                                          trailing: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
                                            icon: const Icon(Icons.cast),
                                            label: const Text('TV'),
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

  @override
  Widget build(BuildContext context) {
    final groups = ['Todos', ...{for (final c in _allChannels) c.group}];
    final filtered = _allChannels.where((c) {
      final matchGroup = _selectedGroup == 'Todos' || c.group == _selectedGroup;
      final matchSearch = _searchQuery.isEmpty || c.name.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchGroup && matchSearch;
    }).toList();

    final audioTracks = _cast.availableTracks.where((t) => t.type == 'AUDIO').toList();
    final textTracks = _cast.availableTracks.where((t) => t.type == 'TEXT').toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF050811),
          title: Text('Chromecast 2015 • ${_allChannels.length} Canais'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.live_tv), text: 'Canais M3U8'),
              Tab(icon: Icon(Icons.movie), text: 'Filmes & Séries'),
              Tab(icon: Icon(Icons.subtitles), text: 'Controle & Idioma'),
            ],
          ),
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: const Color(0xFF1E1B4B),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_status, style: const TextStyle(color: Color(0xFFC4B5FD), fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // ABA 1: CANAIS M3U8
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: groups.contains(_selectedGroup) ? _selectedGroup : 'Todos',
                                decoration: const InputDecoration(labelText: 'Categoria', isDense: true),
                                items: groups.take(100).map((g) => DropdownMenuItem(value: g, child: Text(g, overflow: TextOverflow.ellipsis))).toList(),
                                onChanged: (v) => setState(() => _selectedGroup = v ?? 'Todos'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _searchCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Buscar canal...',
                                  prefixIcon: Icon(Icons.search),
                                  isDense: true,
                                ),
                                onChanged: (v) => setState(() => _searchQuery = v),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, idx) {
                            final ch = filtered[idx];
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              child: ListTile(
                                leading: const Icon(Icons.tv, color: Color(0xFFA78BFA)),
                                title: Text(ch.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text(ch.group),
                                trailing: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669)),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('TV'),
                                  onPressed: () => _cast.loadMedia(_ipCtrl.text, ch.url, ch.name, poster: ch.logo),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                  // ABA 2: FILMES & SÉRIES (COM ESCOLHA DE TEMPORADA, EPISÓDIO, ÁUDIO E LEGENDA)
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            DropdownButton<String>(
                              value: _stremioType,
                              items: const [
                                DropdownMenuItem(value: 'movie', child: Text('🎬 Filmes')),
                                DropdownMenuItem(value: 'series', child: Text('📺 Séries (Temporadas)')),
                              ],
                              onChanged: (v) {
                                setState(() => _stremioType = v ?? 'movie');
                                _fetchStremioCatalog();
                              },
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                decoration: const InputDecoration(hintText: 'Buscar filme ou série...', isDense: true),
                                onSubmitted: (v) => _fetchStremioCatalog(search: v),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.all(10),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 170,
                            childAspectRatio: 0.65,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: _stremioMetas.length,
                          itemBuilder: (ctx, i) {
                            final m = _stremioMetas[i];
                            final name = (m['name'] ?? 'Título').toString();
                            final poster = (m['poster'] ?? '').toString();
                            final id = (m['id'] ?? '').toString();
                            final itemType = (m['type'] ?? _stremioType).toString();
                            return InkWell(
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
                                      padding: const EdgeInsets.all(6),
                                      child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                  // ABA 3: CONTROLE REMOTO + TROCA DE ÁUDIO/LEGENDA AO VIVO NA TV
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text('1. Conexão & Controle da TV', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _ipCtrl,
                              decoration: const InputDecoration(labelText: 'IP do Chromecast (Porta 8009)'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                              _saveChannels();
                              _cast.connect(_ipCtrl.text);
                            },
                            child: const Text('Conectar'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(onPressed: () => _cast.sendMediaCmd('PLAY'), icon: const Icon(Icons.play_arrow), label: const Text('Play')),
                          ElevatedButton.icon(onPressed: () => _cast.sendMediaCmd('PAUSE'), icon: const Icon(Icons.pause), label: const Text('Pause')),
                          ElevatedButton.icon(onPressed: () => _cast.sendMediaCmd('STOP'), icon: const Icon(Icons.stop), label: const Text('Stop')),
                        ],
                      ),
                      Row(
                        children: [
                          const Text('Volume TV:'),
                          Expanded(
                            child: Slider(
                              value: _volume,
                              onChanged: (v) {
                                setState(() => _volume = v);
                                _cast.setVolume(v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                      const Text('2. Trocar Faixa de Áudio / Legenda do Vídeo Atual na TV', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (audioTracks.isEmpty && textTracks.isEmpty)
                        const Text('Inicie um vídeo com múltiplas faixas ou legenda para alternar o idioma aqui em tempo real.', style: TextStyle(color: Colors.grey))
                      else ...[
                        if (audioTracks.isNotEmpty) ...[
                          const Text('Faixas de Áudio Disponíveis no Vídeo:', style: TextStyle(fontWeight: FontWeight.w600)),
                          Wrap(
                            spacing: 8,
                            children: audioTracks
                                .map((t) => ChoiceChip(
                                      label: Text('🎧 ${t.name} (${t.language})'),
                                      selected: _cast.activeTrackIds.contains(t.trackId),
                                      onSelected: (_) {
                                        final others = _cast.activeTrackIds.where((id) => !audioTracks.any((a) => a.trackId == id)).toList();
                                        _cast.setActiveTracks([...others, t.trackId]);
                                      },
                                    ))
                                .toList(),
                          ),
                        ],
                        if (textTracks.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const Text('Legendas Carregadas na TV:', style: TextStyle(fontWeight: FontWeight.w600)),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('Desativar Legenda'),
                                selected: !_cast.activeTrackIds.any((id) => textTracks.any((t) => t.trackId == id)),
                                onSelected: (_) {
                                  final onlyAudio = _cast.activeTrackIds.where((id) => !textTracks.any((t) => t.trackId == id)).toList();
                                  _cast.setActiveTracks(onlyAudio);
                                },
                              ),
                              ...textTracks.map((t) => ChoiceChip(
                                    label: Text('💬 ${t.name}'),
                                    selected: _cast.activeTrackIds.contains(t.trackId),
                                    onSelected: (_) {
                                      final onlyAudio = _cast.activeTrackIds.where((id) => !textTracks.any((tx) => tx.trackId == id)).toList();
                                      _cast.setActiveTracks([...onlyAudio, t.trackId]);
                                    },
                                  )),
                            ],
                          ),
                        ],
                      ],
                      const Divider(height: 28),
                      const Text('3. Carregar Listas de Canais do Brasil (.M3U8)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://iptv-org.github.io/iptv/countries/br.m3u', 'Brasil Aberta'),
                            child: const Text('🇧🇷 IPTV-org Brasil'),
                          ),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_brazil.m3u8', 'Free-TV Brasil'),
                            child: const Text('🇧🇷 Free-TV Brasil'),
                          ),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://github.com/iprtl/m3u/raw/live/Pluto.m3u', 'Pluto TV'),
                            child: const Text('📺 Pluto TV Brasil'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _m3uUrlCtrl,
                              decoration: const InputDecoration(labelText: 'Colar URL .m3u / .m3u8'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl(_m3uUrlCtrl.text, 'Lista Importada'),
                            child: const Text('Importar'),
                          ),
                        ],
                      ),
                      const Divider(height: 28),
                      const Text('4. Adicionar Extensão Stremio (manifest.json)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _addonUrlCtrl,
                              decoration: const InputDecoration(labelText: 'https://.../manifest.json'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => _installStremioAddon(_addonUrlCtrl.text),
                            child: const Text('Instalar'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text('Add-ons Recomendados (1 Toque para Ativar):', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          ActionChip(
                            label: const Text('🎬 BestCine (PT-BR)'),
                            onPressed: () => _installStremioAddon('https://bestcine.dpdns.org/manifest.json'),
                          ),
                          ActionChip(
                            label: const Text('⚡ Torrentio (Dublado)'),
                            onPressed: () => _installStremioAddon('https://torrentio.strem.fun/language=portuguese|sort=qualitysize/manifest.json'),
                          ),
                          ActionChip(
                            label: const Text('💬 OpenSubtitles v3'),
                            onPressed: () => _installStremioAddon('https://opensubtitles-v3.strem.io/manifest.json'),
                          ),
                          ActionChip(
                            label: const Text('🍿 TMDB Metadata BR'),
                            onPressed: () => _installStremioAddon('https://94c8cb9f702d-tmdb-addon.baby-beamup.club/manifest.json'),
                          ),
                          ActionChip(
                            label: const Text('🍙 Anime Kitsu'),
                            onPressed: () => _installStremioAddon('https://anime-kitsu.strem.fun/manifest.json'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
