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
      title: 'Central Chromecast 2015',
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
// MOTOR NATIVO CASTV2 (TLS PORTA 8009) — RODA NO ANDROID E NO WINDOWS
// ============================================================================
class CastV2Client {
  SecureSocket? _socket;
  String? _transportId;
  int? _mediaSessionId;
  int _reqId = 1;
  final List<int> _buffer = [];
  final void Function(String) onStatus;

  CastV2Client({required this.onStatus});

  bool get isConnected => _socket != null;

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
      0x08, 0x00, // protocol_version = 0 (CASTV2_1_0)
      ..._encodeStringField(2, sourceId),
      ..._encodeStringField(3, destId),
      ..._encodeStringField(4, namespace),
      0x28, 0x00, // payload_type = 0 (STRING)
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

    // 1. Conecta ao receiver-0 e lança o Default Media Receiver (CC1AD845)
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
    // Extrai strings UTF-8 do pacote Protobuf (namespace e payload JSON)
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
          _mediaSessionId = stList[0]['mediaSessionId'] as int?;
        }
      }
    } catch (_) {}
  }

  Future<void> loadMedia(String ip, String url, String title, {String poster = ''}) async {
    if (_socket == null) {
      await connect(ip);
    }
    // Garante que o Default Media Receiver (CC1AD845) está aberto e com transportId
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
    _sendProto('sender-0', target, 'urn:x-cast:com.google.cast.media', {
      'type': 'LOAD',
      'requestId': _reqId++,
      'autoplay': true,
      'currentTime': 0,
      'media': {
        'contentId': url,
        'contentType': isHls ? 'application/x-mpegURL' : 'video/mp4',
        'streamType': isHls ? 'LIVE' : 'BUFFERED',
        'metadata': {
          'metadataType': 0,
          'title': title,
          if (poster.isNotEmpty) 'images': [{'url': poster}],
        },
      },
    });
    onStatus('Tocando na TV: $title');
  }

  void sendMediaCmd(String type) {
    if (_socket == null || _transportId == null) return;
    _sendProto('sender-0', _transportId!, 'urn:x-cast:com.google.cast.media', {
      'type': type,
      'mediaSessionId': _mediaSessionId ?? 1,
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
// MODELOS E INTERFACE PRINCIPAL (ROLAGEM VIRTUAL 60 FPS + STREMIO + M3U8)
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
  String _status = 'Pronto! Conecte ao Chromecast ou escolha um canal.';
  double _volume = 0.8;

  List<ChannelItem> _allChannels = [
    ChannelItem(
      name: 'Red Bull TV (Ao Vivo HLS)',
      group: 'Esportes',
      logo: 'https://images.pluto.tv/channels/5ad9b648e738977e2c312131/colorLogoPNG.png',
      url: 'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8',
    ),
    ChannelItem(
      name: 'Big Buck Bunny (1080p MP4)',
      group: 'Teste',
      logo: 'https://image.tmdb.org/t/p/w600_and_h900_bestv2/uVEFQvFMMsg4e6yb03xOfVsDz4o.jpg',
      url: 'http://distribution.bbb3d.renderfarming.net/video/mp4/bbb_sunflower_1080p_30fps_normal.mp4',
    ),
  ];

  String _selectedGroup = 'Todos';
  String _searchQuery = '';
  List<Map<String, dynamic>> _stremioAddons = [
    {'name': 'Cinemeta', 'baseUrl': 'https://v3-cinemeta.strem.io'},
    {'name': 'Torrentio', 'baseUrl': 'https://torrentio.strem.fun'},
  ];
  List<dynamic> _stremioMetas = [];
  String _stremioType = 'movie';

  @override
  void initState() {
    super.initState();
    _cast = CastV2Client(onStatus: (msg) {
      if (mounted) setState(() => _status = msg);
    });
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
    // Salva até 5.000 canais localmente no aparelho
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

  Future<void> _showStremioStreams(String type, String id, String title, String poster) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151E32),
      builder: (ctx) {
        return FutureBuilder<List<Map<String, String>>>(
          future: () async {
            final found = <Map<String, String>>[];
            for (final a in _stremioAddons) {
              try {
                final u = '${a['baseUrl']}/stream/$type/${Uri.encodeComponent(id)}.json';
                final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 7));
                if (r.statusCode == 200) {
                  final list = jsonDecode(r.body)['streams'] as List? ?? [];
                  for (final s in list) {
                    if (s['url'] != null) {
                      found.add({
                        'addon': a['name'].toString(),
                        'title': (s['title'] ?? s['name'] ?? 'Stream HTTP').toString(),
                        'url': s['url'].toString(),
                      });
                    }
                  }
                }
              } catch (_) {}
            }
            return found;
          }(),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final streams = snap.data!;
            if (streams.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Nenhum stream HTTP direto encontrado para $title ($id). Use um add-on HTTP ou a aba de Canais M3U8.'),
              );
            }
            return ListView.builder(
              itemCount: streams.length,
              itemBuilder: (ctx, i) {
                final st = streams[i];
                return ListTile(
                  title: Text(st['addon']!),
                  subtitle: Text(st['title']!),
                  trailing: ElevatedButton.icon(
                    icon: const Icon(Icons.cast),
                    label: const Text('Tocar na TV'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _cast.loadMedia(_ipCtrl.text, st['url']!, title, poster: poster);
                    },
                  ),
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

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF050811),
          title: Text('Chromecast 2015 • ${_allChannels.length} Canais'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.live_tv), text: 'Canais M3U8'),
              Tab(icon: Icon(Icons.movie), text: 'Catálogo Stremio'),
              Tab(icon: Icon(Icons.settings_remote), text: 'Controle & Listas'),
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
                  // ABA 1: CANAIS M3U8 COM ROLAGEM VIRTUAL (60 FPS PARA MILHARES DE CANAIS)
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
                                  labelText: 'Buscar canal (ex: Globo, Cultura, SporTV)...',
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

                  // ABA 2: CATÁLOGO STREMIO
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            DropdownButton<String>(
                              value: _stremioType,
                              items: const [
                                DropdownMenuItem(value: 'movie', child: Text('Filmes')),
                                DropdownMenuItem(value: 'series', child: Text('Séries')),
                              ],
                              onChanged: (v) {
                                setState(() => _stremioType = v ?? 'movie');
                                _fetchStremioCatalog();
                              },
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                decoration: const InputDecoration(hintText: 'Buscar no Stremio...', isDense: true),
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
                            return InkWell(
                              onTap: () => _showStremioStreams(_stremioType, id, name, poster),
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

                  // ABA 3: CONTROLE REMOTO & IMPORTAÇÃO DE LISTAS DO BRASIL E ADD-ONS
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text('1. Conexão & Controle Remoto da TV', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                      const Divider(height: 30),
                      const Text('2. Carregar Canais do Brasil em 1 Toque', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://iptv-org.github.io/iptv/countries/br.m3u', 'Brasil Aberta'),
                            child: const Text('🇧🇷 Carregar IPTV-org Brasil'),
                          ),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_brazil.m3u8', 'Free-TV Brasil'),
                            child: const Text('🇧🇷 Carregar Free-TV Brasil'),
                          ),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl('https://github.com/iprtl/m3u/raw/live/Pluto.m3u', 'Pluto TV'),
                            child: const Text('📺 Carregar Pluto TV Brasil'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _m3uUrlCtrl,
                              decoration: const InputDecoration(labelText: 'Ou cole qualquer URL .m3u / .m3u8 aqui'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => _importM3uFromUrl(_m3uUrlCtrl.text, 'Lista Importada'),
                            child: const Text('Importar M3U8'),
                          ),
                        ],
                      ),
                      const Divider(height: 30),
                      const Text('3. Instalar Extensão Stremio (manifest.json)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
