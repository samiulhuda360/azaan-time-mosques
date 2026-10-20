// Builds assets/mosques.json: every mosque and Muslim prayer room in New
// Zealand from OpenStreetMap, merged with the iqamah timetables kept in
// data/timetables.json.
//
// Run from the project folder:   dart run tool/build_mosques.dart
// Or, with data already downloaded (e.g. by curl):
//                                dart run tool/build_mosques.dart osm.json
//
// Mosque data © OpenStreetMap contributors, available under the Open
// Database Licence (https://www.openstreetmap.org/copyright).

import 'dart:convert';
import 'dart:io';

const _servers = [
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

// Mainland New Zealand and nearby islands.
const _query = '''
[out:json][timeout:120];
nwr["amenity"="place_of_worship"]["religion"="muslim"](-47.5,166.0,-34.0,179.0);
out center tags;
''';

Future<Map<String, dynamic>> _fetch() async {
  for (final server in _servers) {
    try {
      final client = HttpClient()
        ..userAgent = 'AzaanTime/1.0 (mosque directory build)'
        ..connectionTimeout = const Duration(seconds: 20);
      final req = await client.postUrl(Uri.parse(server));
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      req.write('data=${Uri.encodeQueryComponent(_query)}');
      final res = await req.close().timeout(const Duration(minutes: 3));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join();
      client.close();
      stdout.writeln('Fetched from $server');
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('$server failed: $e');
    }
  }
  throw StateError('No OpenStreetMap server could be reached.');
}

String? _address(Map tags) {
  final street = [tags['addr:housenumber'], tags['addr:street']].whereType<String>().join(' ');
  final parts = [
    if (street.isNotEmpty) street,
    tags['addr:suburb'],
    tags['addr:city'],
  ].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  return parts.isEmpty ? null : parts.join(', ');
}

Future<void> main(List<String> args) async {
  final osm = args.isNotEmpty
      ? jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>
      : await _fetch();
  final timetables = File('data/timetables.json').existsSync()
      ? jsonDecode(File('data/timetables.json').readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};

  final mosques = <Map<String, dynamic>>[];
  for (final e in (osm['elements'] as List).cast<Map<String, dynamic>>()) {
    final tags = (e['tags'] as Map?) ?? {};
    final name = (tags['name:en'] ?? tags['name']) as String?;
    if (name == null || name.trim().isEmpty) continue; // unnamed rooms aren't findable
    final lat = (e['lat'] ?? e['center']?['lat']) as num?;
    final lng = (e['lon'] ?? e['center']?['lon']) as num?;
    if (lat == null || lng == null) continue;
    final id = '${e['type']}/${e['id']}';
    mosques.add({
      'id': id,
      'name': name.trim(),
      'lat': double.parse(lat.toStringAsFixed(6)),
      'lng': double.parse(lng.toStringAsFixed(6)),
      if (_address(tags) != null) 'address': _address(tags),
      if ((tags['website'] ?? tags['contact:website']) != null)
        'website': tags['website'] ?? tags['contact:website'],
      if (timetables[id] != null) 'timetable': timetables[id],
    });
  }
  mosques.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  final missing = timetables.keys.where((k) => !mosques.any((m) => m['id'] == k));
  for (final k in missing) {
    stderr.writeln('Warning: timetable for $k has no matching mosque on OpenStreetMap.');
  }

  // A sudden drop usually means a broken download or map vandalism, not
  // mosques closing; refuse to publish it rather than wipe mosques from phones.
  final previous = File('assets/mosques.json');
  if (previous.existsSync()) {
    final old = (jsonDecode(previous.readAsStringSync()) as Map)['mosques'] as List;
    if (mosques.length < old.length * 0.8) {
      stderr.writeln('Only ${mosques.length} mosques now, against ${old.length} before. Not updating.');
      exit(1);
    }
    // Unchanged data keeps its old date, so phones don't download it again.
    if (jsonEncode(old) == jsonEncode(mosques)) {
      stdout.writeln('No changes (${mosques.length} mosques).');
      return;
    }
  }

  final out = {
    'generated': DateTime.now().toUtc().toIso8601String(),
    'attribution': '© OpenStreetMap contributors (ODbL)',
    'mosques': mosques,
  };
  File('assets/mosques.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  stdout.writeln('Wrote ${mosques.length} mosques '
      '(${mosques.where((m) => m['timetable'] != null).length} with timetables) to assets/mosques.json');
}
