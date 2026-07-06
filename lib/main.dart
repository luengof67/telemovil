import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:file_picker/file_picker.dart';

// ─────────────────────────────────────────────────────────────────────────
//  TeleMovil — v1 (reproductor video_player / ExoPlayer)
//  Importa una lista IPTV (URL Xtream/M3U), la guarda en local y reproduce
//  con ExoPlayer (HLS, MP4, DASH...) con User-Agent configurable.
// ─────────────────────────────────────────────────────────────────────────

// Paleta CLARA (acento rojo)
const kBg = Color(0xFFF4F5F7);      // fondo general (gris muy claro)
const kSurface = Color(0xFFFFFFFF); // barras y hojas (blanco)
const kCard = Color(0xFFFFFFFF);    // tarjetas (blanco)
const kBorder = Color(0xFFE3E6EC);  // bordes suaves
const kAccent = Color(0xFFE63946);  // rojo
const kMuted = Color(0xFF6B7280);   // texto secundario (gris)
const kText = Color(0xFF1A1A22);    // texto principal (casi negro)

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // En TV (Fire TV / Android TV) forzamos que SIEMPRE se vea el recuadro de
  // foco al navegar con el mando (D-pad).
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  runApp(const TeleMovilApp());
}

// ───────────────────────────── Modelo ─────────────────────────────────────
class Channel {
  final String name;
  final String url;
  final String cat;
  final String logo;

  Channel({
    required this.name,
    required this.url,
    required this.cat,
    this.logo = '',
  });

  Map<String, dynamic> toJson() => {'n': name, 'u': url, 'c': cat, 'l': logo};

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        name: (j['n'] ?? '') as String,
        url: (j['u'] ?? '') as String,
        cat: (j['c'] ?? 'General') as String,
        logo: (j['l'] ?? '') as String,
      );
}

// ─────────────────────────── Modelo: Playlist ─────────────────────────────
class Playlist {
  final String id;
  String name;
  String url;
  String ua;
  List<Channel> channels;
  Playlist({
    required this.id,
    required this.name,
    required this.url,
    required this.ua,
    this.channels = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'ua': ua,
        'ch': channels.map((c) => c.toJson()).toList(),
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? 'Lista') as String,
        url: (j['url'] ?? '') as String,
        ua: (j['ua'] ?? Store.defaultUa) as String,
        channels: (((j['ch'] as List?) ?? const [])
            .map((e) => Channel.fromJson(e as Map<String, dynamic>))
            .toList()),
      );
}

// ─────────────────────────── Almacenamiento ───────────────────────────────
class Store {
  static const defaultUa = 'VLC/3.0.20 LibVLC/3.0.20';
  static const _kPlaylists = 'tm_playlists';
  static const _kActive = 'tm_active';
  static const _kFavs = 'tm_favs';
  static const _kOldChannels = 'tm_channels';
  static const _kOldUrl = 'tm_url';
  static const _kOldUa = 'tm_ua';

  static Future<List<Playlist>> loadPlaylists() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPlaylists);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        return list
            .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    // Migracion de la lista unica anterior (si existia)
    final oldCh = p.getString(_kOldChannels);
    if (oldCh != null && oldCh.isNotEmpty) {
      try {
        final chs = (jsonDecode(oldCh) as List)
            .map((e) => Channel.fromJson(e as Map<String, dynamic>))
            .toList();
        if (chs.isNotEmpty) {
          final pl = Playlist(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: 'Mi lista',
            url: p.getString(_kOldUrl) ?? '',
            ua: p.getString(_kOldUa) ?? defaultUa,
            channels: chs,
          );
          await savePlaylists([pl]);
          await saveActiveId(pl.id);
          return [pl];
        }
      } catch (_) {}
    }
    return [];
  }

  static Future<void> savePlaylists(List<Playlist> lists) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kPlaylists, jsonEncode(lists.map((e) => e.toJson()).toList()));
  }

  static Future<String?> loadActiveId() async =>
      (await SharedPreferences.getInstance()).getString(_kActive);

  static Future<void> saveActiveId(String id) async =>
      (await SharedPreferences.getInstance()).setString(_kActive, id);

  static Future<Set<String>> loadFavs() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kFavs) ?? <String>[]).toSet();
  }

  static Future<void> saveFavs(Set<String> favs) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kFavs, favs.toList());
  }
}

// ──────────────────────────── Parser M3U ──────────────────────────────────
List<Channel> parseM3U(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final result = <Channel>[];
  for (int i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXTINF')) continue;
    final info = lines[i];
    String url = '';
    for (int j = i + 1; j < lines.length && j < i + 4; j++) {
      if (!lines[j].startsWith('#')) {
        url = lines[j];
        i = j;
        break;
      }
    }
    if (url.isEmpty || !url.startsWith('http')) continue;
    final name = _afterComma(info);
    final group = _attr(info, 'group-title');
    final logo = _attr(info, 'tvg-logo');
    result.add(Channel(
      name: name.isEmpty ? 'Canal' : name,
      url: url,
      cat: group.isEmpty ? 'General' : group,
      logo: logo,
    ));
  }
  return result;
}

String _afterComma(String s) {
  final idx = s.lastIndexOf(',');
  return idx >= 0 ? s.substring(idx + 1).trim() : '';
}

String _attr(String s, String key) {
  final m = RegExp('$key="([^"]*)"', caseSensitive: false).firstMatch(s);
  return m != null ? (m.group(1) ?? '') : '';
}

// GET con reintentos: el panel redirige a un backend distinto cada vez,
// asi que reintentar suele acabar dando con un servidor vivo (como hace IBO).
Future<http.Response> _getRetry(Uri uri, Map<String, String> headers,
    {int tries = 6}) async {
  Object? last;
  for (int i = 0; i < tries; i++) {
    try {
      final r = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
      return r;
    } catch (e) {
      last = e;
      await Future.delayed(const Duration(milliseconds: 700));
    }
  }
  throw last ?? 'fallo de conexion';
}

// ─────────────────────────── EPG (guia) ───────────────────────────────────
class EpgNow {
  final String now;
  final String next;
  const EpgNow(this.now, this.next);
  bool get hasData => now.isNotEmpty || next.isNotEmpty;
}

// Extrae base/usuario/clave/stream_id de una URL de stream Xtream
// (formatos http://host:port/[live/]USER/PASS/ID.ext)
class _XtreamRef {
  final String base, user, pass, streamId;
  _XtreamRef(this.base, this.user, this.pass, this.streamId);
}

_XtreamRef? _parseXtreamUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length < 3) return null;
  var last = segs.last;
  final dot = last.lastIndexOf('.');
  final id = dot > 0 ? last.substring(0, dot) : last;
  if (int.tryParse(id) == null) return null; // el stream_id es numerico
  final pass = segs[segs.length - 2];
  final user = segs[segs.length - 3];
  final base = '${u.scheme}://${u.authority}';
  return _XtreamRef(base, user, pass, id);
}

// Pide "ahora + siguiente" de un canal por get_short_epg (titulos en base64)
Future<EpgNow?> fetchShortEpg(String streamUrl, String ua) async {
  final r = _parseXtreamUrl(streamUrl);
  if (r == null) return null;
  final epgUri = Uri.parse(
      '${r.base}/player_api.php?username=${r.user}&password=${r.pass}'
      '&action=get_short_epg&stream_id=${r.streamId}&limit=2');
  try {
    final resp = await http
        .get(epgUri, headers: {'User-Agent': ua})
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    final listings = (data is Map) ? data['epg_listings'] : null;
    if (listings is! List || listings.isEmpty) return null;
    String titleAt(int i) {
      if (i >= listings.length) return '';
      final t = listings[i]['title'];
      if (t == null) return '';
      try {
        return utf8.decode(base64.decode(t.toString())).trim();
      } catch (_) {
        return t.toString();
      }
    }

    return EpgNow(titleAt(0), titleAt(1));
  } catch (_) {
    return null;
  }
}

// ─────────────── Descarga de canales (Xtream API o M3U) ───────────────────
// Si la URL es de tipo Xtream (get.php?username=...&password=...), usa la API
// player_api.php (mas fiable: evita la redireccion de get.php a puertos caidos).
// Si no, descarga el M3U normal.
Future<List<Channel>> fetchChannels(String url, String ua) async {
  final uri = Uri.parse(url);
  final headers = {'User-Agent': ua};
  final isXtream = uri.path.toLowerCase().contains('get.php') &&
      uri.queryParameters['username'] != null &&
      uri.queryParameters['password'] != null;

  // Probamos en este orden de URLs: la original y, si es https, tambien http
  // (muchos paneles Xtream redirigen mal por https y responden bien por http).
  final candidates = <Uri>[uri];
  if (uri.scheme == 'https') {
    candidates.add(uri.replace(scheme: 'http'));
  }

  Object? firstErr;
  for (final u in candidates) {
    if (isXtream) {
      // 1) Via Xtream API (player_api.php) con reintentos
      try {
        final chs = await _fetchXtreamApi(u, ua);
        if (chs.isNotEmpty) return chs;
      } catch (e) {
        firstErr ??= e;
      }
    }
    // 2) Descarga M3U directa (get.php) con reintentos (la via de IBO)
    try {
      final resp = await _getRetry(u, headers);
      if (resp.statusCode == 200) {
        final chs = parseM3U(resp.body);
        if (chs.isNotEmpty) return chs;
      } else {
        firstErr ??= 'HTTP ${resp.statusCode}';
      }
    } catch (e) {
      firstErr ??= e;
    }
  }
  throw firstErr ?? 'No se pudo descargar la lista';
}

Future<List<Channel>> _fetchXtreamApi(Uri getUri, String ua) async {
  final user = getUri.queryParameters['username']!;
  final pass = getUri.queryParameters['password']!;
  final portPart = getUri.hasPort ? ':${getUri.port}' : '';
  final base = '${getUri.scheme}://${getUri.host}$portPart';
  final output = getUri.queryParameters['output'] ?? 'ts';
  final headers = {'User-Agent': ua};

  // Categorias (id -> nombre)
  final cats = <String, String>{};
  try {
    final cr = await _getRetry(
      Uri.parse(
          '$base/player_api.php?username=$user&password=$pass&action=get_live_categories'),
      headers,
    );
    if (cr.statusCode == 200) {
      final list = jsonDecode(cr.body);
      if (list is List) {
        for (final c in list) {
          cats['${c['category_id']}'] = '${c['category_name'] ?? ''}';
        }
      }
    }
  } catch (_) {}

  // Canales en vivo
  final sr = await _getRetry(
    Uri.parse(
        '$base/player_api.php?username=$user&password=$pass&action=get_live_streams'),
    headers,
  );
  if (sr.statusCode != 200) {
    throw 'HTTP ${sr.statusCode}';
  }
  final data = jsonDecode(sr.body);
  if (data is! List) {
    throw 'respuesta no valida';
  }
  final channels = <Channel>[];
  for (final st in data) {
    final id = '${st['stream_id']}';
    if (id.isEmpty || id == 'null') continue;
    final name = '${st['name'] ?? 'Canal'}';
    final catId = '${st['category_id'] ?? ''}';
    final logo = '${st['stream_icon'] ?? ''}';
    channels.add(Channel(
      name: name,
      url: '$base/live/$user/$pass/$id.$output',
      cat: cats[catId] ?? 'General',
      logo: logo,
    ));
  }
  return channels;
}

// ─────────────────────────────── App ──────────────────────────────────────
// ─────────────────────────── VOD (Peliculas) ──────────────────────────────
// Devuelve las peliculas como Channel (logo = caratula, url = stream de la peli).
Future<List<Channel>> fetchVod(String playlistUrl, String ua) async {
  final u0 = Uri.tryParse(playlistUrl);
  if (u0 == null) return [];
  final user = u0.queryParameters['username'];
  final pass = u0.queryParameters['password'];
  if (user == null || pass == null) return []; // solo Xtream

  final bases = <String>['${u0.scheme}://${u0.authority}'];
  if (u0.scheme == 'https') bases.add('http://${u0.authority}');
  final headers = {'User-Agent': ua};

  for (final base in bases) {
    try {
      // Categorias
      final cats = <String, String>{};
      try {
        final cr = await _getRetry(
          Uri.parse('$base/player_api.php?username=$user&password=$pass'
              '&action=get_vod_categories'),
          headers,
          tries: 3,
        );
        if (cr.statusCode == 200) {
          final list = jsonDecode(cr.body);
          if (list is List) {
            for (final c in list) {
              cats['${c['category_id']}'] = '${c['category_name'] ?? ''}';
            }
          }
        }
      } catch (_) {}

      // Peliculas
      final sr = await _getRetry(
        Uri.parse('$base/player_api.php?username=$user&password=$pass'
            '&action=get_vod_streams'),
        headers,
      );
      if (sr.statusCode != 200) continue;
      final data = jsonDecode(sr.body);
      if (data is! List) continue;

      final movies = <Channel>[];
      for (final m in data) {
        final id = '${m['stream_id']}';
        if (id.isEmpty || id == 'null') continue;
        final ext = '${m['container_extension'] ?? 'mp4'}';
        movies.add(Channel(
          name: '${m['name'] ?? 'Pelicula'}',
          url: '$base/movie/$user/$pass/$id.$ext',
          cat: cats['${m['category_id']}'] ?? 'General',
          logo: '${m['stream_icon'] ?? ''}',
        ));
      }
      if (movies.isNotEmpty) return movies;
    } catch (_) {
      // probamos la siguiente base
    }
  }
  return [];
}

// ─────────────────────────── Series ───────────────────────────────────────
class SeriesItem {
  final String seriesId;
  final String name;
  final String poster;
  final String cat;
  final String plot;
  SeriesItem({
    required this.seriesId,
    required this.name,
    this.poster = '',
    this.cat = 'General',
    this.plot = '',
  });
}

class Episode {
  final String id;
  final String title;
  final String ext;
  Episode({required this.id, required this.title, this.ext = 'mp4'});
}

class Season {
  final String name;
  final List<Episode> episodes;
  Season(this.name, this.episodes);
}

// Datos base de la lista activa para construir llamadas Xtream (con http/https)
class XtreamConn {
  final String base, user, pass;
  XtreamConn(this.base, this.user, this.pass);
}

List<String> _xtreamBases(Uri u0) {
  final bases = <String>['${u0.scheme}://${u0.authority}'];
  if (u0.scheme == 'https') bases.add('http://${u0.authority}');
  return bases;
}

// Lista de series (get_series) -> SeriesItem
Future<List<SeriesItem>> fetchSeries(String playlistUrl, String ua) async {
  final u0 = Uri.tryParse(playlistUrl);
  if (u0 == null) return [];
  final user = u0.queryParameters['username'];
  final pass = u0.queryParameters['password'];
  if (user == null || pass == null) return [];
  final headers = {'User-Agent': ua};

  for (final base in _xtreamBases(u0)) {
    try {
      final cats = <String, String>{};
      try {
        final cr = await _getRetry(
          Uri.parse('$base/player_api.php?username=$user&password=$pass'
              '&action=get_series_categories'),
          headers,
          tries: 3,
        );
        if (cr.statusCode == 200) {
          final list = jsonDecode(cr.body);
          if (list is List) {
            for (final c in list) {
              cats['${c['category_id']}'] = '${c['category_name'] ?? ''}';
            }
          }
        }
      } catch (_) {}

      final sr = await _getRetry(
        Uri.parse('$base/player_api.php?username=$user&password=$pass'
            '&action=get_series'),
        headers,
      );
      if (sr.statusCode != 200) continue;
      final data = jsonDecode(sr.body);
      if (data is! List) continue;

      final out = <SeriesItem>[];
      for (final m in data) {
        final id = '${m['series_id']}';
        if (id.isEmpty || id == 'null') continue;
        out.add(SeriesItem(
          seriesId: id,
          name: '${m['name'] ?? 'Serie'}',
          poster: '${m['cover'] ?? ''}',
          cat: cats['${m['category_id']}'] ?? 'General',
          plot: '${m['plot'] ?? ''}',
        ));
      }
      if (out.isNotEmpty) return out;
    } catch (_) {}
  }
  return [];
}

// Detalle de una serie (get_series_info) -> temporadas con episodios + sinopsis/caratula
class SeriesInfo {
  final List<Season> seasons;
  final String poster;
  final String plot;
  SeriesInfo(this.seasons, this.poster, this.plot);
}

Future<SeriesInfo?> fetchSeriesInfo(
    String playlistUrl, String seriesId, String ua) async {
  final u0 = Uri.tryParse(playlistUrl);
  if (u0 == null) return null;
  final user = u0.queryParameters['username'];
  final pass = u0.queryParameters['password'];
  if (user == null || pass == null) return null;
  final headers = {'User-Agent': ua};

  for (final base in _xtreamBases(u0)) {
    try {
      final r = await _getRetry(
        Uri.parse('$base/player_api.php?username=$user&password=$pass'
            '&action=get_series_info&series_id=$seriesId'),
        headers,
      );
      if (r.statusCode != 200) continue;
      final data = jsonDecode(r.body);
      if (data is! Map) continue;

      // info general
      String poster = '';
      String plot = '';
      final info = data['info'];
      if (info is Map) {
        poster = '${info['cover'] ?? info['cover_big'] ?? ''}';
        plot = '${info['plot'] ?? ''}';
      }

      // episodios: { "1": [ {id, title, container_extension, ...}, ... ], "2": [...] }
      final eps = data['episodes'];
      final seasons = <Season>[];
      if (eps is Map) {
        final keys = eps.keys.toList()
          ..sort((a, b) =>
              (int.tryParse('$a') ?? 0).compareTo(int.tryParse('$b') ?? 0));
        for (final k in keys) {
          final list = eps[k];
          if (list is! List) continue;
          final episodes = <Episode>[];
          for (final e in list) {
            if (e is! Map) continue;
            final id = '${e['id']}';
            if (id.isEmpty || id == 'null') continue;
            final ext = '${e['container_extension'] ?? 'mp4'}';
            final title = '${e['title'] ?? 'Episodio ${e['episode_num'] ?? ''}'}';
            episodes.add(Episode(id: id, title: title, ext: ext));
          }
          if (episodes.isNotEmpty) {
            seasons.add(Season('Temporada $k', episodes));
          }
        }
      }
      if (seasons.isNotEmpty) {
        return SeriesInfo(seasons, poster, plot);
      }
    } catch (_) {}
  }
  return null;
}

// Construye un Channel reproducible para un episodio
Channel episodeToChannel(
    String playlistUrl, Episode ep, String seriesName, String epTitle) {
  final u0 = Uri.parse(playlistUrl);
  final user = u0.queryParameters['username'];
  final pass = u0.queryParameters['password'];
  // Preferimos http si el original es https (suele responder mejor)
  final scheme = u0.scheme == 'https' ? 'http' : u0.scheme;
  final base = '$scheme://${u0.authority}';
  return Channel(
    name: epTitle.isEmpty ? seriesName : '$seriesName - $epTitle',
    url: '$base/series/$user/$pass/${ep.id}.${ep.ext}',
    cat: 'Series',
  );
}

// Envoltorio "enfocable" para mando/TV: muestra un recuadro cuando tiene el
// foco (D-pad) y ejecuta onTap al pulsar OK/Enter o al tocar la pantalla.
class Focusable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius? borderRadius;
  final bool autofocus;
  const Focusable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius,
    this.autofocus = false,
  });

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(10);
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: _focused ? kAccent : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: kAccent.withOpacity(0.45),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class TeleMovilApp extends StatelessWidget {
  const TeleMovilApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TeleMovil',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: kBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kAccent,
          brightness: Brightness.light,
        ),
        focusColor: kAccent.withOpacity(0.25),
        textTheme: Typography.blackMountainView.apply(
          bodyColor: kText,
          displayColor: kText,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kSurface,
          foregroundColor: kText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────── Pantalla principal ───────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const String favFilter = '\u2605';
  late final TabController _tabs;
  List<Playlist> _playlists = [];
  Playlist? _active;
  Set<String> _favs = {};
  final Map<String, EpgNow> _epg = {};
  final Set<String> _epgTried = {};
  String _cat = 'Todos';
  String _query = '';
  bool _loading = true;

  // Peliculas (VOD)
  List<Channel>? _movies;
  bool _moviesLoading = false;
  String? _moviesErr;
  String _movieCat = 'Todos';
  String _movieQuery = '';

  // Series
  List<SeriesItem>? _series;
  bool _seriesLoading = false;
  String? _seriesErr;
  String _seriesCat = 'Todos';
  String _seriesQuery = '';

  String get _ua => _active?.ua ?? Store.defaultUa;
  List<Channel> get _channels => _active?.channels ?? const [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // ── Peliculas ──
  void _resetVod() {
    _movies = null;
    _moviesErr = null;
    _moviesLoading = false;
    _movieCat = 'Todos';
    _movieQuery = '';
    _series = null;
    _seriesErr = null;
    _seriesLoading = false;
    _seriesCat = 'Todos';
    _seriesQuery = '';
  }

  Future<void> _loadMovies() async {
    if (_moviesLoading || _active == null) return;
    setState(() {
      _moviesLoading = true;
      _moviesErr = null;
    });
    try {
      final movies = await fetchVod(_active!.url, _ua);
      if (!mounted) return;
      setState(() {
        _movies = movies;
        _moviesLoading = false;
        if (movies.isEmpty) _moviesErr = 'Esta lista no tiene peliculas.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _moviesLoading = false;
        _moviesErr = 'No se pudieron cargar las peliculas.';
      });
    }
  }

  List<String> get _movieCategories {
    final set = <String>{};
    for (final m in (_movies ?? const <Channel>[])) {
      set.add(m.cat);
    }
    final list = set.toList()..sort();
    return ['Todos', ...list];
  }

  List<Channel> get _moviesFiltered {
    final q = _movieQuery.toLowerCase();
    return (_movies ?? const <Channel>[]).where((m) {
      final okCat = _movieCat == 'Todos' || m.cat == _movieCat;
      final okQ = q.isEmpty || m.name.toLowerCase().contains(q);
      return okCat && okQ;
    }).toList();
  }

  Future<void> _loadSeries() async {
    if (_seriesLoading || _active == null) return;
    setState(() {
      _seriesLoading = true;
      _seriesErr = null;
    });
    try {
      final series = await fetchSeries(_active!.url, _ua);
      if (!mounted) return;
      setState(() {
        _series = series;
        _seriesLoading = false;
        if (series.isEmpty) _seriesErr = 'Esta lista no tiene series.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _seriesLoading = false;
        _seriesErr = 'No se pudieron cargar las series.';
      });
    }
  }

  List<String> get _seriesCategories {
    final set = <String>{};
    for (final s in (_series ?? const <SeriesItem>[])) {
      set.add(s.cat);
    }
    final list = set.toList()..sort();
    return ['Todos', ...list];
  }

  List<SeriesItem> get _seriesFiltered {
    final q = _seriesQuery.toLowerCase();
    return (_series ?? const <SeriesItem>[]).where((s) {
      final okCat = _seriesCat == 'Todos' || s.cat == _seriesCat;
      final okQ = q.isEmpty || s.name.toLowerCase().contains(q);
      return okCat && okQ;
    }).toList();
  }

  Future<void> _load() async {
    final pls = await Store.loadPlaylists();
    final favs = await Store.loadFavs();
    final activeId = await Store.loadActiveId();
    Playlist? active;
    if (pls.isNotEmpty) {
      active = pls.firstWhere((p) => p.id == activeId, orElse: () => pls.first);
    }
    if (!mounted) return;
    setState(() {
      _playlists = pls;
      _active = active;
      _favs = favs;
      _loading = false;
      _cat = 'Todos';
      _query = '';
      _resetVod();
    });
  }

  bool _isFav(Channel c) => _favs.contains(c.url);

  void _toggleFav(Channel c) {
    setState(() {
      if (_favs.contains(c.url)) {
        _favs.remove(c.url);
      } else {
        _favs.add(c.url);
      }
    });
    Store.saveFavs(_favs);
  }

  void _ensureEpg(Channel c) {
    if (_epgTried.contains(c.url)) return;
    _epgTried.add(c.url);
    fetchShortEpg(c.url, _ua).then((epg) {
      if (!mounted || epg == null || !epg.hasData) return;
      setState(() => _epg[c.url] = epg);
    });
  }

  List<String> get _categories {
    final set = <String>{};
    for (final c in _channels) {
      set.add(c.cat);
    }
    final list = set.toList()..sort();
    return ['Todos', favFilter, ...list];
  }

  List<Channel> get _filtered {
    final q = _query.toLowerCase();
    return _channels.where((c) {
      final okCat = _cat == 'Todos' ||
          (_cat == favFilter ? _favs.contains(c.url) : c.cat == _cat);
      final okQ = q.isEmpty ||
          c.name.toLowerCase().contains(q) ||
          c.cat.toLowerCase().contains(q);
      return okCat && okQ;
    }).toList();
  }

  void _play(List<Channel> list, int index, {bool isVod = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
            channels: list, index: index, ua: _ua, isVod: isVod),
      ),
    );
  }

  Future<void> _openPlaylists() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.live_tv, color: kAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _active?.name ?? 'TeleMovil',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_play),
            tooltip: 'Mis listas',
            onPressed: _openPlaylists,
          ),
        ],
        bottom: (_loading || _playlists.isEmpty)
            ? null
            : TabBar(
                controller: _tabs,
                indicatorColor: kAccent,
                indicatorWeight: 3,
                labelColor: kAccent,
                unselectedLabelColor: kMuted,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                tabs: const [
                  Tab(text: 'TV en vivo'),
                  Tab(text: 'Peliculas'),
                  Tab(text: 'Series'),
                ],
              ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
              ? _emptyState()
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _liveTab(),
                    _moviesTab(),
                    _seriesTab(),
                  ],
                ),
    );
  }

  Widget _liveTab() {
    final filtered = _filtered;
    return Column(
      children: [
        _searchBar(),
        _categoryChips(),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('Sin resultados',
                      style: TextStyle(color: kMuted)),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _channelTile(filtered, i),
                ),
        ),
      ],
    );
  }

  Widget _seriesTab() {
    if (_series == null && !_seriesLoading && _seriesErr == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSeries());
    }
    if (_seriesLoading) {
      return const Center(child: CircularProgressIndicator(color: kAccent));
    }
    if (_seriesErr != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_filter_outlined,
                  size: 48, color: kMuted),
              const SizedBox(height: 12),
              Text(_seriesErr!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kMuted)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() {
                    _series = null;
                    _seriesErr = null;
                  });
                  _loadSeries();
                },
                child: const Text('Reintentar',
                    style: TextStyle(color: kAccent)),
              ),
            ],
          ),
        ),
      );
    }
    final series = _seriesFiltered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _seriesQuery = v),
            decoration: InputDecoration(
              hintText: 'Buscar series...',
              prefixIcon: const Icon(Icons.search, color: kMuted),
              filled: true,
              fillColor: kCard,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: _seriesCategories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final c = _seriesCategories[i];
              final active = c == _seriesCat;
              return Focusable(
                onTap: () => setState(() => _seriesCat = c),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: active ? kAccent : kCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? kAccent : kBorder),
                  ),
                  child: Text(c,
                      style: TextStyle(
                        color: active ? Colors.white : kMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      )),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: series.isEmpty
              ? const Center(
                  child: Text('Sin resultados',
                      style: TextStyle(color: kMuted)))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.62,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: series.length,
                  itemBuilder: (_, i) => _seriesCard(series[i]),
                ),
        ),
      ],
    );
  }

  Widget _seriesCard(SeriesItem s) {
    return Focusable(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SeriesDetailScreen(
              playlistUrl: _active!.url,
              ua: _ua,
              series: s,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: s.poster.isNotEmpty
                  ? Image.network(
                      s.poster,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (_, __, ___) => _posterFallback(),
                    )
                  : _posterFallback(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _moviesTab() {
    // Carga perezosa la primera vez que se entra
    if (_movies == null && !_moviesLoading && _moviesErr == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMovies());
    }
    if (_moviesLoading) {
      return const Center(child: CircularProgressIndicator(color: kAccent));
    }
    if (_moviesErr != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, size: 48, color: kMuted),
              const SizedBox(height: 12),
              Text(_moviesErr!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kMuted)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(_resetVod);
                  _loadMovies();
                },
                child: const Text('Reintentar',
                    style: TextStyle(color: kAccent)),
              ),
            ],
          ),
        ),
      );
    }
    final movies = _moviesFiltered;
    return Column(
      children: [
        // Buscador
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _movieQuery = v),
            decoration: InputDecoration(
              hintText: 'Buscar peliculas...',
              prefixIcon: const Icon(Icons.search, color: kMuted),
              filled: true,
              fillColor: kCard,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
            ),
          ),
        ),
        // Categorias
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: _movieCategories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final c = _movieCategories[i];
              final active = c == _movieCat;
              return Focusable(
                onTap: () => setState(() => _movieCat = c),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: active ? kAccent : kCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? kAccent : kBorder),
                  ),
                  child: Text(c,
                      style: TextStyle(
                        color: active ? Colors.white : kMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      )),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: movies.isEmpty
              ? const Center(
                  child: Text('Sin resultados',
                      style: TextStyle(color: kMuted)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.62,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: movies.length,
                  itemBuilder: (_, i) => _movieCard(movies, i),
                ),
        ),
      ],
    );
  }

  Widget _movieCard(List<Channel> list, int index) {
    final m = list[index];
    return Focusable(
      onTap: () => _play(list, index, isVod: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: m.logo.isNotEmpty
                  ? Image.network(
                      m.logo,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (_, __, ___) => _posterFallback(),
                    )
                  : _posterFallback(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            m.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _posterFallback() {
    return Container(
      color: kCard,
      child: const Center(
        child: Icon(Icons.movie, color: kMuted, size: 32),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.playlist_add, size: 64, color: kMuted),
            const SizedBox(height: 16),
            const Text(
              'No tienes listas',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Anade tu primera lista IPTV para empezar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kAccent),
              icon: const Icon(Icons.add),
              label: const Text('Mis listas'),
              onPressed: _openPlaylists,
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'Buscar canales...',
          prefixIcon: const Icon(Icons.search, color: kMuted),
          filled: true,
          fillColor: kCard,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBorder),
          ),
        ),
      ),
    );
  }

  Widget _categoryChips() {
    final cats = _categories;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: cats.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = cats[i];
          final active = c == _cat;
          final isFavChip = c == favFilter;
          return Focusable(
            onTap: () => setState(() => _cat = c),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: active ? kAccent : kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: active ? kAccent : kBorder),
              ),
              child: isFavChip
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star,
                            size: 16,
                            color: active ? Colors.white : Colors.amber),
                        const SizedBox(width: 4),
                        Text('Favoritos',
                            style: TextStyle(
                              color: active ? Colors.white : kMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            )),
                      ],
                    )
                  : Text(
                      c,
                      style: TextStyle(
                        color: active ? Colors.white : kMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _channelTile(List<Channel> list, int index) {
    final c = list[index];
    _ensureEpg(c);
    final epg = _epg[c.url];
    return Container(
      margin: EdgeInsets.fromLTRB(12, index == 0 ? 4 : 5, 12, 5),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _play(list, index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child: c.logo.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            c.logo,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _logoFallback(),
                          ),
                        )
                      : _logoFallback(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      if (epg != null && epg.now.isNotEmpty)
                        Text('\u25CF ${epg.now}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: kAccent, fontSize: 12))
                      else
                        Text(c.cat,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: kMuted, fontSize: 12)),
                      if (epg != null && epg.next.isNotEmpty)
                        Text('Luego: ${epg.next}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: kMuted, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _isFav(c) ? Icons.star : Icons.star_border,
                    color: _isFav(c) ? Colors.amber : kMuted,
                  ),
                  onPressed: () => _toggleFav(c),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _logoFallback() {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: const Icon(Icons.tv, color: kMuted),
    );
  }
}

// ─────────────────────────── Pantalla "Mis listas" ────────────────────────
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  List<Playlist> _lists = [];
  String? _activeId;
  bool _loading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pls = await Store.loadPlaylists();
    final active = await Store.loadActiveId();
    if (!mounted) return;
    setState(() {
      _lists = pls;
      _activeId = active;
      _loading = false;
    });
  }

  Future<void> _activate(Playlist p) async {
    await Store.saveActiveId(p.id);
    _changed = true;
    setState(() => _activeId = p.id);
  }

  Future<void> _delete(Playlist p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Borrar lista'),
        content: Text('Borrar "${p.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Borrar', style: TextStyle(color: kAccent))),
        ],
      ),
    );
    if (ok != true) return;
    _lists.removeWhere((e) => e.id == p.id);
    if (_activeId == p.id) {
      _activeId = _lists.isNotEmpty ? _lists.first.id : null;
      if (_activeId != null) await Store.saveActiveId(_activeId!);
    }
    await Store.savePlaylists(_lists);
    _changed = true;
    setState(() {});
  }

  Future<void> _add() async {
    final pl = await Navigator.push<Playlist>(
      context,
      MaterialPageRoute(builder: (_) => const ImportScreen()),
    );
    if (pl == null) return;
    _lists.add(pl);
    await Store.savePlaylists(_lists);
    await Store.saveActiveId(pl.id);
    _changed = true;
    await _load();
  }

  Future<void> _edit(Playlist p) async {
    final updated = await Navigator.push<Playlist>(
      context,
      MaterialPageRoute(builder: (_) => ImportScreen(existing: p)),
    );
    if (updated == null) return;
    final i = _lists.indexWhere((e) => e.id == updated.id);
    if (i >= 0) {
      _lists[i] = updated;
    } else {
      _lists.add(updated);
    }
    await Store.savePlaylists(_lists);
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mis listas'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: kAccent,
          icon: const Icon(Icons.add),
          label: const Text('Anadir lista'),
          onPressed: _add,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _lists.isEmpty
                ? const Center(
                    child: Text('No tienes listas. Toca "Anadir lista".',
                        style: TextStyle(color: kMuted)),
                  )
                : ListView.builder(
                    itemCount: _lists.length,
                    itemBuilder: (_, i) {
                      final p = _lists[i];
                      final active = p.id == _activeId;
                      return ListTile(
                        onTap: () => _activate(p),
                        leading: Icon(
                          active
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          color: active ? kAccent : kMuted,
                        ),
                        title: Text(p.name),
                        subtitle: Text('${p.channels.length} canales',
                            style:
                                const TextStyle(color: kMuted, fontSize: 12)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined,
                                  color: kMuted),
                              tooltip: 'Editar',
                              onPressed: () => _edit(p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: kMuted),
                              tooltip: 'Borrar',
                              onPressed: () => _delete(p),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

// ─────────────────────────── Pantalla importar ────────────────────────────
class ImportScreen extends StatefulWidget {
  final Playlist? existing; // si viene, estamos editando
  const ImportScreen({super.key, this.existing});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _nameC = TextEditingController();
  final _urlC = TextEditingController();
  final _uaC = TextEditingController(text: Store.defaultUa);
  final _nameFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _uaFocus = FocusNode();
  bool _busy = false;
  String _status = '';

  // User-Agents habituales para autocompletar
  static const List<String> _commonUas = [
    'VLC/3.0.20 LibVLC/3.0.20',
    'IBOPlayer/1.4',
    'okhttp/4.9.3',
    'Dalvik/2.1.0 (Linux; U; Android 14)',
    'TiviMate/4.7.0',
    'Lavf/58.76.100',
    'IPTVSmartersPlayer',
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  ];

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameC.text = e.name;
      _urlC.text = e.url;
      _uaC.text = e.ua;
    }
  }

  @override
  void dispose() {
    _nameC.dispose();
    _urlC.dispose();
    _uaC.dispose();
    _nameFocus.dispose();
    _urlFocus.dispose();
    _uaFocus.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final name = _nameC.text.trim();
    final url = _urlC.text.trim();
    final ua = _uaC.text.trim().isEmpty ? Store.defaultUa : _uaC.text.trim();
    if (name.isEmpty) {
      setState(() => _status = 'Ponle un nombre a la lista.');
      return;
    }
    if (url.isEmpty || !url.startsWith('http')) {
      setState(() => _status = 'Introduce una URL valida (http/https).');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Descargando lista...';
    });
    try {
      final chs = await fetchChannels(url, ua);
      if (chs.isEmpty) throw 'vacia';
      final pl = Playlist(
        id: widget.existing?.id ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        url: url,
        ua: ua,
        channels: chs,
      );
      if (!mounted) return;
      Navigator.pop(context, pl);
    } catch (e) {
      final msg = e.toString().contains('vacia')
          ? 'La URL no devuelve una lista valida.'
          : 'No se pudo descargar.\n${e.toString()}';
      setState(() {
        _status = msg;
        _busy = false;
      });
    }
  }

  // Importa los canales desde un archivo .m3u del dispositivo (offline)
  Future<void> _importFromFile() async {
    final name = _nameC.text.trim();
    final ua = _uaC.text.trim().isEmpty ? Store.defaultUa : _uaC.text.trim();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any, // algunos moviles no filtran bien por extension
      );
      if (result == null || result.files.single.path == null) return;
      final path = result.files.single.path!;
      setState(() {
        _busy = true;
        _status = 'Leyendo archivo...';
      });
      final content = await File(path).readAsString();
      final chs = parseM3U(content);
      if (chs.isEmpty) {
        setState(() {
          _busy = false;
          _status = 'El archivo no contiene canales validos (.m3u).';
        });
        return;
      }
      final finalName = name.isEmpty
          ? path.split(Platform.pathSeparator).last.split('.').first
          : name;
      final pl = Playlist(
        id: widget.existing?.id ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        name: finalName.isEmpty ? 'Mi lista' : finalName,
        url: '', // lista desde archivo: sin URL (offline)
        ua: ua,
        channels: chs,
      );
      if (!mounted) return;
      Navigator.pop(context, pl);
    } catch (e) {
      setState(() {
        _busy = false;
        _status = 'No se pudo leer el archivo.\n${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_editing ? 'Editar lista' : 'Anadir lista')),
      body: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Nombre de la lista',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameC,
              focusNode: _nameFocus,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _urlFocus.requestFocus(),
              decoration: _dec('Mi proveedor'),
            ),
            const SizedBox(height: 16),
            const Text('URL de la lista (Xtream get.php o .m3u)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _urlC,
              focusNode: _urlFocus,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _uaFocus.requestFocus(),
              minLines: 1,
              maxLines: 3,
              decoration: _dec('https://servidor/get.php?username=...'),
            ),
            const SizedBox(height: 12),
            Row(
              children: const [
                Expanded(child: Divider(color: kBorder)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('o', style: TextStyle(color: kMuted)),
                ),
                Expanded(child: Divider(color: kBorder)),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: kAccent,
                side: const BorderSide(color: kAccent),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.upload_file),
              label: const Text('Elegir archivo .m3u'),
              onPressed: _busy ? null : _importFromFile,
            ),
            const SizedBox(height: 16),
            const Text('User-Agent',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              'Algunos proveedores exigen uno concreto. Por defecto VLC.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _uaC,
              focusNode: _uaFocus,
              textInputAction: TextInputAction.done,
              decoration: _dec(Store.defaultUa),
            ),
            const SizedBox(height: 8),
            // Sugerencias de User-Agent como botones enfocables (mando)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _commonUas.map((u) {
                return Focusable(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() {
                    _uaC.text = u;
                    _uaC.selection = TextSelection.collapsed(
                        offset: _uaC.text.length);
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: kBorder),
                    ),
                    child: Text(
                      _uaLabel(u),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _busy ? null : _import,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(_editing ? 'Guardar cambios' : 'Importar lista'),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(_status, style: const TextStyle(color: kMuted)),
            ],
          ],
        ),
      ),
    );
  }

  // Etiqueta corta para el boton de User-Agent
  String _uaLabel(String ua) {
    final slash = ua.indexOf('/');
    final base = slash > 0 ? ua.substring(0, slash) : ua;
    return base.length > 18 ? '${base.substring(0, 18)}...' : base;
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: kCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kBorder),
        ),
      );
}

// ──────────────────────────── Reproductor (video_player) ──────────────────
// ─────────────────────── Detalle de serie ─────────────────────────────────
class SeriesDetailScreen extends StatefulWidget {
  final String playlistUrl;
  final String ua;
  final SeriesItem series;
  const SeriesDetailScreen({
    super.key,
    required this.playlistUrl,
    required this.ua,
    required this.series,
  });

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  bool _loading = true;
  String? _error;
  SeriesInfo? _info;
  int _season = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info =
          await fetchSeriesInfo(widget.playlistUrl, widget.series.seriesId, widget.ua);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
        if (info == null) _error = 'No se pudo cargar esta serie.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo cargar esta serie.';
      });
    }
  }

  void _playEpisode(Season season, int index) {
    final channels = season.episodes
        .map((e) => episodeToChannel(
            widget.playlistUrl, e, widget.series.name, e.title))
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          channels: channels,
          index: index,
          ua: widget.ua,
          isVod: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final poster =
        (info != null && info.poster.isNotEmpty) ? info.poster : widget.series.poster;
    final plot = (info != null && info.plot.isNotEmpty) ? info.plot : widget.series.plot;
    return Scaffold(
      appBar: AppBar(title: Text(widget.series.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: kMuted, size: 48),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: kMuted)),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Reintentar',
                              style: TextStyle(color: kAccent)),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    // Cabecera: caratula + sinopsis
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 110,
                            height: 160,
                            child: poster.isNotEmpty
                                ? Image.network(poster,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        Container(color: kCard,
                                            child: const Icon(Icons.movie,
                                                color: kMuted)))
                                : Container(
                                    color: kCard,
                                    child: const Icon(Icons.movie,
                                        color: kMuted)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.series.name,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              if (plot.isNotEmpty)
                                Text(plot,
                                    maxLines: 7,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: kMuted, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Selector de temporada
                    if (info != null && info.seasons.isNotEmpty)
                      _seasonSelector(info),
                    const SizedBox(height: 8),
                    // Episodios de la temporada elegida
                    if (info != null && info.seasons.isNotEmpty)
                      ..._episodeList(info.seasons[_season]),
                  ],
                ),
    );
  }

  Widget _seasonSelector(SeriesInfo info) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: info.seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final active = i == _season;
          return Focusable(
            onTap: () => setState(() => _season = i),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: active ? kAccent : kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: active ? kAccent : kBorder),
              ),
              child: Text(info.seasons[i].name,
                  style: TextStyle(
                    color: active ? Colors.white : kMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  )),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _episodeList(Season season) {
    return List.generate(season.episodes.length, (i) {
      final e = season.episodes[i];
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: kAccent,
            child: Text('${i + 1}',
                style: const TextStyle(color: Colors.white)),
          ),
          title: Text(e.title,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.play_circle_fill, color: kAccent),
          onTap: () => _playEpisode(season, i),
        ),
      );
    });
  }
}

enum FitMode { contain, cover, fill }

class PlayerScreen extends StatefulWidget {
  final List<Channel> channels;
  final int index;
  final String ua;
  final bool isVod;

  const PlayerScreen({
    super.key,
    required this.channels,
    required this.index,
    required this.ua,
    this.isVod = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _showControls = true;
  int _idx = 0;
  FitMode _fit = FitMode.contain;
  double _volume = 1.0;
  bool _muted = false;
  double _brightness = 0.5;
  int _retries = 0;
  EpgNow? _epg;
  static const int _maxRetries = 5;

  Channel get _channel => widget.channels[_idx];

  @override
  void initState() {
    super.initState();
    _idx = widget.index;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initBrightness();
    _open();
  }

  Future<void> _initBrightness() async {
    try {
      final b = await ScreenBrightness.instance.application;
      if (mounted) setState(() => _brightness = b);
    } catch (_) {}
  }

  void _setBrightness(double v) {
    setState(() => _brightness = v);
    ScreenBrightness.instance.setApplicationScreenBrightness(v).catchError((_) {});
  }

  Future<void> _open() async {
    // Cierra el anterior
    final old = _controller;
    _controller = null;
    old?.removeListener(_listener);
    await old?.dispose();

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(_channel.url),
        httpHeaders: {'User-Agent': widget.ua},
      );
      _controller = c;
      c.addListener(_listener);
      await c.initialize();
      await c.setVolume(_muted ? 0.0 : _volume);
      await c.play();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _retries = 0;
      });
      _loadEpg();
    } catch (e) {
      if (!mounted) return;
      _onPlaybackError(e.toString());
    }
  }

  void _listener() {
    final v = _controller?.value;
    if (v != null && v.hasError && mounted && _error == null) {
      _onPlaybackError(v.errorDescription ?? 'Error de reproduccion');
    }
  }

  // Reconexion automatica: si el directo se corta, reintenta solo.
  void _onPlaybackError(String msg) {
    if (_retries < _maxRetries) {
      _retries++;
      setState(() {
        _loading = true;
        _error = null;
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _open();
      });
    } else {
      setState(() {
        _error = msg;
        _loading = false;
      });
    }
  }

  void _changeChannel(int delta) {
    final n = widget.channels.length;
    if (n <= 1) return;
    setState(() {
      _idx = (_idx + delta) % n;
      if (_idx < 0) _idx += n;
      _retries = 0;
      _epg = null;
    });
    _open();
  }

  // Avanza/retrocede en peliculas y series (VOD)
  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    var target = pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    c.seekTo(target);
    setState(() => _showControls = true);
  }

  // Manejo del mando (D-pad) en el reproductor
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    // OK / Select / Enter: mostrar u ocultar controles
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      setState(() => _showControls = !_showControls);
      return KeyEventResult.handled;
    }
    // Arriba / abajo: cambiar de canal (en TV en vivo)
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.channelUp) {
      _changeChannel(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.channelDown) {
      _changeChannel(1);
      return KeyEventResult.handled;
    }
    // Izquierda / derecha: en VOD avanzar/retroceder; en vivo cambiar canal
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (widget.isVod) {
        _seekBy(-10);
      } else {
        _changeChannel(-1);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (widget.isVod) {
        _seekBy(10);
      } else {
        _changeChannel(1);
      }
      return KeyEventResult.handled;
    }
    // Play/Pausa
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.space) {
      final c = _controller;
      if (c != null && c.value.isInitialized) {
        setState(() {
          c.value.isPlaying ? c.pause() : c.play();
          _showControls = true;
        });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _cycleFit() {
    setState(() {
      _fit = FitMode.values[(_fit.index + 1) % FitMode.values.length];
    });
  }

  String get _fitLabel {
    switch (_fit) {
      case FitMode.contain:
        return 'Ajustar';
      case FitMode.cover:
        return 'Llenar';
      case FitMode.fill:
        return 'Estirar';
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_listener);
    _controller?.dispose();
    ScreenBrightness.instance.resetApplicationScreenBrightness().catchError((_) {});
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0.0 : _volume);
  }

  void _setVolume(double v) {
    setState(() {
      _volume = v;
      _muted = v == 0.0;
    });
    _controller?.setVolume(v);
  }

  void _loadEpg() {
    final url = _channel.url;
    fetchShortEpg(url, widget.ua).then((epg) {
      if (!mounted || url != _channel.url) return;
      setState(() => _epg = epg);
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showControls = !_showControls),
          child: Stack(
            children: [
              Positioned.fill(child: _content()),

            // Barra superior: cerrar + nombre + aspecto
            if (_showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    color: Colors.black45,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                              if (_epg != null && _epg!.now.isNotEmpty)
                                Text(
                                  '\u25CF ${_epg!.now}'
                                  '${_epg!.next.isNotEmpty ? '   \u2192 ${_epg!.next}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _cycleFit,
                          icon: const Icon(Icons.aspect_ratio,
                              color: Colors.white, size: 20),
                          label: Text(_fitLabel,
                              style: const TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Brillo (izquierda, vertical)
            if (_showControls && _error == null)
              Positioned(
                left: 10,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _vSlider(
                    icon: _brightness < 0.4
                        ? Icons.brightness_low
                        : (_brightness < 0.75
                            ? Icons.brightness_medium
                            : Icons.brightness_high),
                    value: _brightness,
                    onChanged: _setBrightness,
                  ),
                ),
              ),

            // Volumen (derecha, vertical)
            if (_showControls && _error == null)
              Positioned(
                right: 10,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _vSlider(
                    icon: (_muted || _volume == 0.0)
                        ? Icons.volume_off
                        : (_volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up),
                    value: _muted ? 0.0 : _volume,
                    onChanged: _setVolume,
                    onIconTap: _toggleMute,
                  ),
                ),
              ),

            // Barra de tiempo (seek) solo en VOD/peliculas
            if (_showControls &&
                _error == null &&
                widget.isVod &&
                (_controller?.value.isInitialized ?? false))
              Positioned(
                bottom: 76,
                left: 16,
                right: 16,
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _controller!,
                  builder: (_, v, __) {
                    final dur = v.duration.inMilliseconds.toDouble();
                    final pos = v.position.inMilliseconds
                        .toDouble()
                        .clamp(0, dur <= 0 ? 1 : dur);
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Text(_fmt(v.position),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                          Expanded(
                            child: Slider(
                              value: dur <= 0 ? 0.0 : pos.toDouble(),
                              max: dur <= 0 ? 1.0 : dur,
                              activeColor: kAccent,
                              inactiveColor: Colors.white24,
                              onChanged: (val) {
                                _controller?.seekTo(
                                    Duration(milliseconds: val.round()));
                              },
                            ),
                          ),
                          Text(_fmt(v.duration),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ],
                      ),
                    );
                  },
                ),
              ),

            // Controles inferiores: (anterior) / play-pausa / (siguiente)
            if (_showControls && _error == null)
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!widget.isVod) ...[
                      _circleBtn(Icons.skip_previous,
                          () => _changeChannel(-1), 24),
                      const SizedBox(width: 24),
                    ],
                    _circleBtn(
                      (_controller?.value.isPlaying ?? false)
                          ? Icons.pause
                          : Icons.play_arrow,
                      _togglePlay,
                      32,
                    ),
                    if (!widget.isVod) ...[
                      const SizedBox(width: 24),
                      _circleBtn(
                          Icons.skip_next, () => _changeChannel(1), 24),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  // Slider vertical reutilizable (brillo / volumen) con icono arriba
  Widget _vSlider({
    required IconData icon,
    required double value,
    required ValueChanged<double> onChanged,
    VoidCallback? onIconTap,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onIconTap,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          SizedBox(
            height: 150,
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value.clamp(0.0, 1.0),
                  activeColor: kAccent,
                  inactiveColor: Colors.white24,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap, double size) {    return CircleAvatar(
      radius: size == 32 ? 28 : 24,
      backgroundColor: size == 32 ? kAccent : Colors.black54,
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: size),
        onPressed: onTap,
      ),
    );
  }

  String _fmt(Duration d) {
    if (d.inMilliseconds <= 0) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Widget _content() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kAccent),
            if (_retries > 0) ...[
              const SizedBox(height: 12),
              Text('Reconectando... ($_retries/$_maxRetries)',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: kAccent, size: 48),
              const SizedBox(height: 12),
              const Text(
                'No se pudo reproducir este canal',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: kAccent),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: () {
                  _retries = 0;
                  _open();
                },
              ),
            ],
          ),
        ),
      );
    }
    final c = _controller!;
    final ar = c.value.aspectRatio;
    final video = SizedBox(
      width: c.value.size.width,
      height: c.value.size.height,
      child: VideoPlayer(c),
    );
    switch (_fit) {
      case FitMode.contain:
        return Center(
          child: AspectRatio(
            aspectRatio: ar <= 0 ? 16 / 9 : ar,
            child: VideoPlayer(c),
          ),
        );
      case FitMode.cover:
        return FittedBox(fit: BoxFit.cover, child: video);
      case FitMode.fill:
        return SizedBox.expand(
          child: FittedBox(fit: BoxFit.fill, child: video),
        );
    }
  }
}
