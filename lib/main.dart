// سلطة بار — نظام إدارة الطلبات (نسخة أندرويد / APK)
// الدخول الافتراضي: admin / 1234
// الحزم: image_picker, url_launcher, path_provider, share_plus, file_picker
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as imglib;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud_config.dart';

part 'p_extra.dart';
part 'p_online.dart';

/// رقم البناء (يُحقن من GitHub Actions)
const int kBuild = int.fromEnvironment('BUILD', defaultValue: 0);

// ====================================================================
//  أدوات عامة
// ====================================================================

double _d(dynamic v) => (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0;

String unitName(String u) => switch (u) {
      'g100' => 'جرام (كل 100g)',
      'ml100' => 'ملي (كل 100ml)',
      'piece' => 'قطعة',
      _ => 'وحدة',
    };

String unitShort(String u) => switch (u) { 'g100' => 'جرام', 'ml100' => 'ملي', 'piece' => 'قطعة', _ => '' };
double unitFactor(String u) => (u == 'g100' || u == 'ml100') ? 0.01 : 1;

String statusLabel(String s) => switch (s) {
      'new' => 'جديد',
      'prep' => 'قيد التحضير',
      'delivery' => 'خرج للتوصيل',
      'done' => 'مكتمل',
      'cancel' => 'ملغي',
      _ => s,
    };

String paymentLabel(String m) => switch (m) {
      'cod' => 'عند الاستلام',
      'partial' => 'دفعة مقدمة + الباقي عند الاستلام',
      'credit' => 'آجل (على حساب العميل)',
      _ => 'مدفوع بالكامل (شامل التوصيل)',
    };

// ====================================================================
//  أدوات الهاتف: تخزين، صور، واتساب، مشاركة
// ====================================================================

File? _dataFile;
Directory? _imgDir;
Future<void> _writeChain = Future.value();

/// يقرأ البيانات المحفوظة من ذاكرة التطبيق (يُستدعى مرة واحدة عند التشغيل)
Future<String?> loadPersisted() async {
  try {
    final d = await getApplicationDocumentsDirectory();
    _dataFile = File('${d.path}/salad_bar_data.json');
    _imgDir = Directory('${d.path}/img');
    if (!await _imgDir!.exists()) await _imgDir!.create(recursive: true);
    final tmp = File('${_dataFile!.path}.tmp');
    if (!await _dataFile!.exists() && await tmp.exists()) {
      await tmp.rename(_dataFile!.path);
    }
    if (await _dataFile!.exists()) return await _dataFile!.readAsString();
  } catch (_) {}
  return null;
}

/// كتابة آمنة (ملف مؤقت ثم استبدال) ومتسلسلة
void _persist(String s) {
  final f = _dataFile;
  if (f == null) return;
  _writeChain = _writeChain.then((_) async {
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(s, flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  });
}

final ImagePicker _picker = ImagePicker();

Future<String> saveImageBytes(Uint8List b, {String ext = 'jpg'}) async {
  var dir = _imgDir;
  if (dir == null) {
    final d = await getApplicationDocumentsDirectory();
    dir = Directory('${d.path}/img');
    _imgDir = dir;
  }
  if (!await dir.exists()) await dir.create(recursive: true);
  final f = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(b, flush: true);
  return f.path;
}

Future<String?> saveDataUrl(String dataUrl) async {
  try {
    final i = dataUrl.indexOf(',');
    final head = dataUrl.substring(0, i);
    final bytes = base64Decode(dataUrl.substring(i + 1));
    return await saveImageBytes(Uint8List.fromList(bytes), ext: head.contains('png') ? 'png' : 'jpg');
  } catch (_) {
    return null;
  }
}

/// يحوّل مسار ملف صورة إلى data URL (للنسخ الاحتياطي والإرسال)
Future<String?> fileToDataUrl(String path) async {
  try {
    if (path.startsWith('data:') || path.startsWith('http')) return path;
    final f = File(path);
    if (!await f.exists()) return null;
    final b = await f.readAsBytes();
    return 'data:${path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg'};base64,${base64Encode(b)}';
  } catch (_) {
    return null;
  }
}

/// اختيار صورة (معرض أو كاميرا) وتصغيرها وإرجاعها data URL
Future<String?> pickImageAsDataUrl({int maxSide = 600, bool camera = false, int quality = 85}) async {
  try {
    final x = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: maxSide.toDouble(),
      maxHeight: maxSide.toDouble(),
      imageQuality: quality,
    );
    if (x == null) return null;
    final b = await x.readAsBytes();
    final isPng = x.path.toLowerCase().endsWith('.png');
    return 'data:${isPng ? 'image/png' : 'image/jpeg'};base64,${base64Encode(b)}';
  } catch (_) {
    return null;
  }
}

/// اختيار صورة وحفظها كملف داخل التطبيق وإرجاع مساره
Future<String?> pickImageData({int maxSide = 600, bool png = false, bool camera = false}) async {
  final d = await pickImageAsDataUrl(maxSide: maxSide, camera: camera);
  return d == null ? null : await saveDataUrl(d);
}

Future<String?> pickTextFile() async {
  try {
    final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    if (r == null || r.files.isEmpty) return null;
    final f = r.files.first;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return null;
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Future<void> shareBytesFile(Uint8List bytes, String name, String mime, {String? text}) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles([XFile(f.path, mimeType: mime)], text: text);
}

String waNumber(String p) {
  var d = p.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('0') && d.length >= 9) {
    d = '967${d.substring(1)}';
  } else if (d.length == 9 && d.startsWith('7')) {
    d = '967$d';
  }
  return d.length < 8 ? '' : d;
}

/// يفتح واتساب برسالة جاهزة (وينسخ النص احتياطياً)
Future<void> sendWa(BuildContext c, String phone, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  final n = waNumber(phone);
  if (n.isEmpty) {
    if (c.mounted) toast(c, 'رقم الهاتف غير صالح — تم نسخ الرسالة فقط');
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse('https://wa.me/$n?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (c.mounted) toast(c, ok ? 'جاري فتح واتساب…' : 'تعذّر فتح واتساب — تم نسخ الرسالة، الصقها يدوياً');
}

Future<void> callPhone(BuildContext c, String phone) async {
  if (phone.trim().isEmpty) return toast(c, 'لا يوجد رقم هاتف');
  try {
    await launchUrl(Uri(scheme: 'tel', path: phone.trim()));
  } catch (_) {
    if (c.mounted) toast(c, 'تعذّر الاتصال');
  }
}

void copyText(BuildContext c, String text, String msg) {
  Clipboard.setData(ClipboardData(text: text));
  toast(c, msg);
}

// ---- الصور ----
// ---- الموقع الجغرافي ----
typedef LatLng = ({double lat, double lng});

String mapLink(double lat, double lng) => 'https://www.google.com/maps?q=$lat,$lng';

String _normDigits(String t) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final sb = StringBuffer();
  for (final ch in t.runes) {
    final c = String.fromCharCode(ch);
    final i = ar.indexOf(c);
    sb.write(i >= 0 ? '$i' : (c == '٫' ? '.' : c));
  }
  return sb.toString();
}

/// يستخرج الإحداثيات من رابط خرائط جوجل أو من نص بصيغة "15.35, 44.20"
LatLng? parseLatLng(String text) {
  var t = _normDigits(text.trim());
  try {
    t = Uri.decodeFull(t);
  } catch (_) {}
  final pats = [
    RegExp(r'@(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)'),
    RegExp(r'[?&](?:q|ll|query|destination|center|daddr)=(-?\d{1,2}\.\d+)[,\s]+(-?\d{1,3}\.\d+)'),
    RegExp(r'!3d(-?\d{1,2}\.\d+)!4d(-?\d{1,3}\.\d+)'),
    RegExp(r'/place/(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)'),
    RegExp(r'^\s*(-?\d{1,2}\.\d+)\s*[,،;\s]\s*(-?\d{1,3}\.\d+)\s*$'),
  ];
  for (final r in pats) {
    final m = r.firstMatch(t);
    if (m == null) continue;
    final la = double.tryParse(m.group(1)!), ln = double.tryParse(m.group(2)!);
    if (la != null && ln != null && la.abs() <= 90 && ln.abs() <= 180) return (lat: la, lng: ln);
  }
  return null;
}

/// يحلّ الروابط المختصرة (maps.app.goo.gl وغيرها) بتتبّع التحويلات
Future<LatLng?> resolveLocation(String text) async {
  final direct = parseLatLng(text);
  if (direct != null) return direct;
  final um = RegExp(r'https?://[^\s]+').firstMatch(text);
  final first = um == null ? null : Uri.tryParse(um.group(0)!);
  if (first == null) return null;
  var url = first;
  final client = http.Client();
  try {
    for (var i = 0; i < 6; i++) {
      final p = parseLatLng(url.toString());
      if (p != null) return p;
      final req = http.Request('GET', url)..followRedirects = false;
      final res = await client.send(req).timeout(const Duration(seconds: 12));
      final loc = res.headers['location'];
      if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
        url = url.resolve(loc);
        continue;
      }
      final body = await res.stream.bytesToString();
      final m = RegExp(r'@(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)').firstMatch(body);
      if (m != null) return parseLatLng('@${m.group(1)},${m.group(2)}');
      break;
    }
  } catch (_) {
  } finally {
    client.close();
  }
  return null;
}

/// موقع الجهاز الحالي (null عند الرفض أو الفشل)
Future<LatLng?> getMyLocation(BuildContext c) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (c.mounted) toast(c, 'شغّل خدمة الموقع (GPS) في الهاتف');
      return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      if (c.mounted) toast(c, 'اسمح للتطبيق بالوصول للموقع من إعدادات الهاتف');
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
    return (lat: pos.latitude, lng: pos.longitude);
  } catch (_) {
    if (c.mounted) toast(c, 'تعذّر تحديد الموقع، حاول في مكان مفتوح');
    return null;
  }
}

/// يفتح خرائط جوجل للملاحة إلى الإحداثيات (أو يبحث بالعنوان)
Future<void> openNavigation(BuildContext c, {double? lat, double? lng, String address = ''}) async {
  final String url;
  if (lat != null && lng != null) {
    url = 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving';
  } else if (address.trim().isNotEmpty) {
    url = 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';
  } else {
    return toast(c, 'لا يوجد موقع أو عنوان');
  }
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && c.mounted) toast(c, 'تعذّر فتح الخرائط');
}

final Map<String, Uint8List> _imgCache = {};

Uint8List? _decodeImg(String path) {
  final hit = _imgCache[path];
  if (hit != null) return hit;
  try {
    final b = base64Decode(path.substring(path.indexOf(',') + 1));
    _imgCache[path] = b;
    return b;
  } catch (_) {
    return null;
  }
}

Widget imgWidget(String? path, {BoxFit fit = BoxFit.cover, required Widget fallback}) {
  if (path == null || path.isEmpty) return fallback;
  if (path.startsWith('data:')) {
    final bytes = _decodeImg(path);
    if (bytes == null) return fallback;
    return Image.memory(bytes,
        fit: fit, gaplessPlayback: true, width: double.infinity, height: double.infinity, errorBuilder: (_, __, ___) => fallback);
  }
  if (path.startsWith('http')) {
    return Image.network(path,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (c, child, p) => p == null ? child : fallback);
  }
  return Image.file(File(path),
      fit: fit,
      gaplessPlayback: true,
      width: double.infinity,
      height: double.infinity,
      cacheWidth: 700,
      errorBuilder: (_, __, ___) => fallback);
}


// ====================================================================
//  النماذج
// ====================================================================

String _newSalt() => base64Encode(List<int>.generate(12, (_) => Random.secure().nextInt(256)));

String hashPw(String pw, String salt) {
  List<int> d = utf8.encode('$salt:$pw');
  for (var i = 0; i < 5000; i++) {
    d = sha256.convert(d).bytes;
  }
  return base64Encode(d);
}

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse('$v');

class AppSettings {
  String username, storeName, storePhone, storeAddress, ownerName;
  String passHash, passSalt;
  bool mustChange;
  String? logoPath, ownerImage;
  double loyaltyEarn, loyaltyValue; // earn: كل كم ريال = نقطة (0 = معطّل) ، value: قيمة النقطة بالريال
  String menuUrl;
  bool onlineEnabled, onlineOpen;
  String menuKey, onlineNote;
  double onlineFee, minOrder;
  List<Map<String, dynamic>> payMethods;
  AppSettings({
    this.username = 'admin',
    this.passHash = '',
    this.passSalt = '',
    this.mustChange = true,
    this.storeName = 'سلطة بار',
    this.storePhone = '',
    this.storeAddress = '',
    this.ownerName = 'صاحب المتجر',
    this.logoPath,
    this.ownerImage,
    this.loyaltyEarn = 0,
    this.loyaltyValue = 50,
    this.menuUrl = '',
    this.onlineEnabled = false,
    this.onlineOpen = true,
    this.menuKey = '',
    this.onlineNote = '',
    this.onlineFee = 500,
    this.minOrder = 0,
    List<Map<String, dynamic>>? payMethods,
  }) : payMethods = payMethods ??
            [
              {'id': 'cod', 'title': 'الدفع عند الاستلام', 'kind': 'cod', 'info': '', 'needRef': false}
            ];
  void setPassword(String pw) {
    passSalt = _newSalt();
    passHash = hashPw(pw, passSalt);
  }

  bool checkPassword(String pw) => passHash.isNotEmpty && hashPw(pw, passSalt) == passHash;

  Map<String, dynamic> toJson() => {
        'username': username,
        'passHash': passHash,
        'passSalt': passSalt,
        'mustChange': mustChange,
        'storeName': storeName,
        'storePhone': storePhone,
        'storeAddress': storeAddress,
        'ownerName': ownerName,
        'logoPath': logoPath,
        'ownerImage': ownerImage,
        'loyaltyEarn': loyaltyEarn,
        'loyaltyValue': loyaltyValue,
        'menuUrl': menuUrl,
        'onlineEnabled': onlineEnabled,
        'onlineOpen': onlineOpen,
        'menuKey': menuKey,
        'onlineNote': onlineNote,
        'onlineFee': onlineFee,
        'minOrder': minOrder,
        'payMethods': payMethods,
      };
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final s = AppSettings(
      username: j['username'] ?? 'admin',
      storeName: j['storeName'] ?? 'سلطة بار',
      storePhone: j['storePhone'] ?? '',
      storeAddress: j['storeAddress'] ?? '',
      ownerName: j['ownerName'] ?? 'صاحب المتجر',
      logoPath: j['logoPath'],
      ownerImage: j['ownerImage'],
      loyaltyEarn: _d(j['loyaltyEarn']),
      loyaltyValue: j['loyaltyValue'] == null ? 50 : _d(j['loyaltyValue']),
      menuUrl: j['menuUrl'] ?? '',
      onlineEnabled: j['onlineEnabled'] ?? false,
      onlineOpen: j['onlineOpen'] ?? true,
      menuKey: j['menuKey'] ?? '',
      onlineNote: j['onlineNote'] ?? '',
      onlineFee: j['onlineFee'] == null ? 500 : _d(j['onlineFee']),
      minOrder: _d(j['minOrder']),
      payMethods: j['payMethods'] is List ? [for (final e in (j['payMethods'] as List)) Map<String, dynamic>.from(e as Map)] : null,
    );
    if ('${j['passHash'] ?? ''}'.isNotEmpty) {
      s.passHash = '${j['passHash']}';
      s.passSalt = '${j['passSalt'] ?? ''}';
      s.mustChange = j['mustChange'] ?? false;
    } else {
      // بيانات قديمة بكلمة مرور نصية: تُحوَّل إلى تجزئة
      final legacy = '${j['password'] ?? '1234'}';
      s.setPassword(legacy);
      s.mustChange = legacy == '1234';
    }
    return s;
  }
}

class Product {
  int id;
  String name, unit;
  double price, cost, stock, lowStock;
  bool active, track;
  String? imagePath;
  Product({
    required this.id,
    required this.name,
    required this.price,
    this.cost = 0,
    this.unit = 'piece',
    this.stock = 0,
    this.lowStock = 10,
    this.active = true,
    this.track = true,
    this.imagePath,
  });
  bool get isPiece => unit == 'piece';

  /// الحد الأقصى المتاح للبيع (غير محدود إن لم يُتتبع المخزون)
  double get maxQty => track ? stock : double.infinity;
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'price': price,
        'cost': cost,
        'unit': unit,
        'stock': stock,
        'lowStock': lowStock,
        'active': active,
        'track': track,
        'imagePath': imagePath,
      };
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'],
        name: j['name'],
        price: _d(j['price']),
        cost: _d(j['cost']),
        unit: j['unit'] ?? 'piece',
        stock: _d(j['stock']),
        lowStock: _d(j['lowStock']),
        active: j['active'] ?? true,
        // البيانات القديمة بمخزون وهمي 999 لا تُتتبَّع
        track: j['track'] ?? (_d(j['stock']) != 999),
        imagePath: j['imagePath'],
      );
}

class Customer {
  int id;
  String name, phone, address, notes;
  double? lat, lng; // موقع العميل على الخريطة
  Customer({required this.id, required this.name, required this.phone, required this.address, this.notes = '', this.lat, this.lng});
  bool get hasLoc => lat != null && lng != null;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'address': address, 'notes': notes, 'lat': lat, 'lng': lng};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'],
        name: j['name'],
        phone: j['phone'] ?? '',
        address: j['address'] ?? '',
        notes: j['notes'] ?? '',
        lat: j['lat'] is num ? (j['lat'] as num).toDouble() : null,
        lng: j['lng'] is num ? (j['lng'] as num).toDouble() : null,
      );
}

class Captain {
  int id;
  String name, phone;
  bool available;
  String? login, cloudUid; // حساب دخول الكابتن للتطبيق (سحابي)
  Captain({required this.id, required this.name, required this.phone, this.available = true, this.login, this.cloudUid});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'phone': phone, 'available': available, 'login': login, 'cloudUid': cloudUid};
  factory Captain.fromJson(Map<String, dynamic> j) => Captain(
        id: j['id'],
        name: j['name'],
        phone: j['phone'] ?? '',
        available: j['available'] ?? true,
        login: j['login'],
        cloudUid: j['cloudUid'],
      );
}

class OrderItem {
  int productId;
  String name, unit;
  double price, cost, qty;
  OrderItem({required this.productId, required this.name, required this.price, this.cost = 0, required this.unit, required this.qty});
  double get lineTotal => price * qty * unitFactor(unit);
  double get lineCost => cost * qty * unitFactor(unit);
  Map<String, dynamic> toJson() => {'productId': productId, 'name': name, 'price': price, 'cost': cost, 'unit': unit, 'qty': qty};
  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        productId: j['productId'],
        name: j['name'],
        price: _d(j['price']),
        cost: _d(j['cost']),
        unit: j['unit'] ?? 'piece',
        qty: _d(j['qty']),
      );
}

class Order {
  int id, customerId, captainId;
  DateTime date;
  List<OrderItem> items;
  double subtotal, delivery, discount, total;
  double goodsTotal, paidNow, goodsDue, captainCredit, pointsUsed;
  String notes, status, method, coupon, source;
  String? webKey;
  DateTime? startAt, doneAt;
  String? proof;
  double? proofLat, proofLng;
  Order({
    required this.id,
    required this.date,
    required this.customerId,
    required this.captainId,
    required this.items,
    required this.subtotal,
    required this.delivery,
    required this.discount,
    required this.total,
    required this.goodsTotal,
    required this.paidNow,
    required this.goodsDue,
    this.captainCredit = 0,
    this.pointsUsed = 0,
    this.notes = '',
    this.status = 'new',
    this.method = 'prepaid',
    this.coupon = '',
    this.source = 'app',
    this.startAt,
    this.doneAt,
    this.proof,
    this.proofLat,
    this.proofLng,
    this.webKey,
  });

  /// الكابتن لا يحصّل شيئاً من العميل (مدفوع بالكامل أو آجل)
  bool get isFree => method == 'prepaid' || method == 'credit';

  /// المبلغ المطلوب تحصيله من العميل عند الاستلام
  double get customerDue => isFree ? 0 : goodsDue + delivery;
  double get paidAmount => method == 'prepaid' ? total : (method == 'credit' ? 0 : paidNow);

  /// دَين على العميل للمحل (الطلب الآجل)
  double get debt => method == 'credit' ? total : 0;
  double get cogs => items.fold<double>(0, (a, i) => a + i.lineCost);

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'customerId': customerId,
        'captainId': captainId,
        'items': items.map((e) => e.toJson()).toList(),
        'subtotal': subtotal,
        'delivery': delivery,
        'discount': discount,
        'total': total,
        'goodsTotal': goodsTotal,
        'paidNow': paidNow,
        'goodsDue': goodsDue,
        'captainCredit': captainCredit,
        'pointsUsed': pointsUsed,
        'notes': notes,
        'status': status,
        'method': method,
        'coupon': coupon,
        'source': source,
        'webKey': webKey,
        'startAt': startAt?.toIso8601String(),
        'doneAt': doneAt?.toIso8601String(),
        'proof': proof,
        'proofLat': proofLat,
        'proofLng': proofLng,
      };
  factory Order.fromJson(Map<String, dynamic> j) => Order(
        id: j['id'],
        date: DateTime.parse(j['date']),
        customerId: j['customerId'],
        captainId: j['captainId'],
        items: (j['items'] as List).map((e) => OrderItem.fromJson(Map<String, dynamic>.from(e))).toList(),
        subtotal: _d(j['subtotal']),
        delivery: _d(j['delivery']),
        discount: _d(j['discount']),
        total: _d(j['total']),
        goodsTotal: _d(j['goodsTotal']),
        paidNow: _d(j['paidNow']),
        goodsDue: _d(j['goodsDue']),
        captainCredit: _d(j['captainCredit']),
        pointsUsed: _d(j['pointsUsed']),
        notes: j['notes'] ?? '',
        status: j['status'] ?? 'new',
        method: j['method'] ?? 'prepaid',
        coupon: j['coupon'] ?? '',
        source: j['source'] ?? 'app',
        webKey: j['webKey'],
        startAt: _dt(j['startAt']),
        doneAt: _dt(j['doneAt']),
        proof: j['proof'],
        proofLat: j['proofLat'] == null ? null : _d(j['proofLat']),
        proofLng: j['proofLng'] == null ? null : _d(j['proofLng']),
      );
}

class Settlement {
  int id, captainId;
  String type, note; // captain_paid | owner_paid
  double amount;
  DateTime date;
  Settlement({required this.id, required this.captainId, required this.type, required this.amount, this.note = '', required this.date});
  Map<String, dynamic> toJson() =>
      {'id': id, 'captainId': captainId, 'type': type, 'amount': amount, 'note': note, 'date': date.toIso8601String()};
  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
        id: j['id'],
        captainId: j['captainId'],
        type: j['type'],
        amount: _d(j['amount']),
        note: j['note'] ?? '',
        date: DateTime.parse(j['date']),
      );
}

/// مشتريات خارجية يكلّف بها المحل الكابتن (يسلّمه عهدة ثم تُسجَّل التكلفة الفعلية)
class Purchase {
  int id, captainId;
  String title, note, claimNote;
  double given, actual, claimed;
  bool closed, pending; // pending = أرسل الكابتن التكلفة وينتظر اعتماد المالك
  String? receipt;
  DateTime date;
  Purchase({
    required this.id,
    required this.captainId,
    required this.title,
    required this.given,
    this.actual = 0,
    this.claimed = 0,
    this.note = '',
    this.claimNote = '',
    this.closed = false,
    this.pending = false,
    this.receipt,
    required this.date,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'captainId': captainId,
        'title': title,
        'note': note,
        'claimNote': claimNote,
        'given': given,
        'actual': actual,
        'claimed': claimed,
        'closed': closed,
        'pending': pending,
        'receipt': receipt,
        'date': date.toIso8601String(),
      };
  factory Purchase.fromJson(Map<String, dynamic> j) => Purchase(
        id: j['id'],
        captainId: j['captainId'],
        title: j['title'] ?? '',
        note: j['note'] ?? '',
        claimNote: j['claimNote'] ?? '',
        given: _d(j['given']),
        actual: _d(j['actual']),
        claimed: _d(j['claimed']),
        closed: j['closed'] ?? false,
        pending: j['pending'] ?? false,
        receipt: j['receipt'],
        date: DateTime.parse(j['date']),
      );
}

class Expense {
  int id;
  String title, category, note;
  double amount;
  DateTime date;
  Expense({required this.id, required this.title, required this.category, required this.amount, this.note = '', required this.date});
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'category': category, 'amount': amount, 'note': note, 'date': date.toIso8601String()};
  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'],
        title: j['title'] ?? '',
        category: j['category'] ?? 'أخرى',
        amount: _d(j['amount']),
        note: j['note'] ?? '',
        date: DateTime.parse(j['date']),
      );
}

class CustomerPayment {
  int id, customerId;
  double amount;
  String note;
  DateTime date;
  CustomerPayment({required this.id, required this.customerId, required this.amount, this.note = '', required this.date});
  Map<String, dynamic> toJson() => {'id': id, 'customerId': customerId, 'amount': amount, 'note': note, 'date': date.toIso8601String()};
  factory CustomerPayment.fromJson(Map<String, dynamic> j) => CustomerPayment(
        id: j['id'],
        customerId: j['customerId'],
        amount: _d(j['amount']),
        note: j['note'] ?? '',
        date: DateTime.parse(j['date']),
      );
}

class StockMove {
  int id, productId;
  double delta, balance;
  String type, note;
  DateTime date;
  StockMove({required this.id, required this.productId, required this.delta, required this.balance, required this.type, this.note = '', required this.date});
  Map<String, dynamic> toJson() =>
      {'id': id, 'productId': productId, 'delta': delta, 'balance': balance, 'type': type, 'note': note, 'date': date.toIso8601String()};
  factory StockMove.fromJson(Map<String, dynamic> j) => StockMove(
        id: j['id'],
        productId: j['productId'],
        delta: _d(j['delta']),
        balance: _d(j['balance']),
        type: j['type'] ?? '',
        note: j['note'] ?? '',
        date: DateTime.parse(j['date']),
      );
}

class DayClose {
  int id;
  String day, note;
  double expected, actual;
  DateTime at;
  DayClose({required this.id, required this.day, required this.expected, required this.actual, this.note = '', required this.at});
  double get diff => actual - expected;
  Map<String, dynamic> toJson() =>
      {'id': id, 'day': day, 'expected': expected, 'actual': actual, 'note': note, 'at': at.toIso8601String()};
  factory DayClose.fromJson(Map<String, dynamic> j) => DayClose(
        id: j['id'],
        day: j['day'] ?? '',
        expected: _d(j['expected']),
        actual: _d(j['actual']),
        note: j['note'] ?? '',
        at: DateTime.parse(j['at']),
      );
}

class Coupon {
  int id;
  String code, type; // fixed | percent
  double value, minOrder;
  int maxUses;
  DateTime? expires;
  bool active;
  Coupon({required this.id, required this.code, this.type = 'fixed', required this.value, this.minOrder = 0, this.maxUses = 0, this.expires, this.active = true});
  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'type': type,
        'value': value,
        'minOrder': minOrder,
        'maxUses': maxUses,
        'expires': expires?.toIso8601String(),
        'active': active,
      };
  factory Coupon.fromJson(Map<String, dynamic> j) => Coupon(
        id: j['id'],
        code: j['code'] ?? '',
        type: j['type'] ?? 'fixed',
        value: _d(j['value']),
        minOrder: _d(j['minOrder']),
        maxUses: _d(j['maxUses']).toInt(),
        expires: _dt(j['expires']),
        active: j['active'] ?? true,
      );
}

class StaffUser {
  int id;
  String name, username, passHash, passSalt, role;
  StaffUser({required this.id, required this.name, required this.username, required this.passHash, required this.passSalt, this.role = 'cashier'});
  bool check(String pw) => hashPw(pw, passSalt) == passHash;
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'username': username, 'passHash': passHash, 'passSalt': passSalt, 'role': role};
  factory StaffUser.fromJson(Map<String, dynamic> j) => StaffUser(
        id: j['id'],
        name: j['name'] ?? '',
        username: j['username'] ?? '',
        passHash: j['passHash'] ?? '',
        passSalt: j['passSalt'] ?? '',
        role: j['role'] ?? 'cashier',
      );
}

class Balances {
  final double cashDue, creditDue;
  const Balances(this.cashDue, this.creditDue);

  /// موجب = للكابتن على المحل، سالب = على الكابتن للمحل
  double get net => creditDue - cashDue;
}

// ====================================================================
//  الألوان والثيم
// ====================================================================

class C {
  static const g = Color(0xFF1B4D3E);
  static const g2 = Color(0xFF2E8B57);
  static const dark = Color(0xFF14382C);
  static const gold = Color(0xFFD4AF37);
  static const bg = Color(0xFFF4F7F5);
  static const text = Color(0xFF24322C);
  static const muted = Color(0xFF728078);
  static const line = Color(0xFFDFE8E2);
  static const red = Color(0xFFDC3545);
  static const blue = Color(0xFF2563EB);
  static const purple = Color(0xFF7C3AED);
  static const orange = Color(0xFFEA8B19);
  static const wa = Color(0xFF25D366);

  static const brandGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFF0D2D24), g, Color(0xFF245D47)],
  );
  static const goldGradient = LinearGradient(
    colors: [Color(0xFFB68B24), Color(0xFFF7E9A8), gold, Color(0xFFF7E9A8), Color(0xFFB68B24)],
  );
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: C.g, primary: C.g, secondary: C.gold, surface: Colors.white),
    scaffoldBackgroundColor: C.bg,
  );
  final text = base.textTheme.apply(bodyColor: C.text, displayColor: C.text);
  return base.copyWith(
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: C.g,
      foregroundColor: Colors.white,
      elevation: 0,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.g2, width: 1.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.g2,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.g,
        side: const BorderSide(color: C.line),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: C.g.withOpacity(.12),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    ),
    snackBarTheme: const SnackBarThemeData(contentTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
  );
}

// ====================================================================
//  الحالة المشتركة
// ====================================================================

class StoreScope extends InheritedNotifier<AppStore> {
  const StoreScope({super.key, required AppStore super.notifier, required super.child});
}

extension StoreCtx on BuildContext {
  T watch<T extends AppStore>() => dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier! as T;
  T read<T extends AppStore>() => getInheritedWidgetOfExactType<StoreScope>()!.notifier! as T;
}

// ====================================================================
//  عناصر واجهة مشتركة
// ====================================================================

String _fmt(num v) {
  final r = (v * 100).round() / 100;
  final neg = r < 0;
  final parts = r.abs().toString().split('.');
  final ip = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final fr = parts.length > 1 && parts[1] != '0' ? '.${parts[1]}' : '';
  return '${neg ? '-' : ''}$ip$fr';
}

String _p2(int n) => n.toString().padLeft(2, '0');
String money(num v) => '${_fmt(v)} YER';
String qtyText(num v) => _fmt(v);
String dateText(DateTime d) => '${d.year}/${_p2(d.month)}/${_p2(d.day)}  ${_p2(d.hour)}:${_p2(d.minute)}';
String dayKey(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.g,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
}

Future<bool> confirmDialog(BuildContext c, String msg, {String yes = 'نعم، تأكيد'}) async {
  return await showDialog<bool>(
        context: c,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('تأكيد'),
          content: Text(msg),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(yes),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> showSheet(BuildContext c, Widget Function(BuildContext) builder) {
  return showModalBottomSheet(
    context: c,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, MediaQuery.of(ctx).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 44, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(9)))),
          builder(ctx),
        ]),
      ),
    ),
  );
}

Color statusColor(String s) => switch (s) {
      'new' => C.blue,
      'prep' => C.orange,
      'delivery' => C.purple,
      'done' => C.g2,
      _ => C.red,
    };

class Badge2 extends StatelessWidget {
  final String text;
  final Color color;
  final bool solid;
  const Badge2(this.text, this.color, {super.key, this.solid = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: solid ? Colors.white.withOpacity(.94) : color.withOpacity(.12), borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

/// بطاقة فاخرة مع شريط جانبي اختياري
class LuxCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? accent;
  final VoidCallback? onTap;
  const LuxCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.accent, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.line),
        boxShadow: [BoxShadow(color: C.g.withOpacity(.08), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: Material(
          color: Colors.transparent,
          child: Stack(children: [
            InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
            if (accent != null) Positioned(top: 0, bottom: 0, right: 0, width: 5, child: IgnorePointer(child: ColoredBox(color: accent!))),
          ]),
        ),
      ),
    );
  }
}

/// صندوق بشريط علوي ذهبي (يُستخدم في الفاتورة)
class TopBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final Gradient? gradient;
  final Color bg;
  final Color borderColor;
  const TopBox({
    super.key,
    required this.child,
    this.color = C.gold,
    this.padding = const EdgeInsets.all(12),
    this.gradient,
    this.bg = const Color(0xFFFBFDFB),
    this.borderColor = C.line,
  });
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: gradient == null ? bg : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(height: 3, color: color),
            Padding(padding: padding, child: child),
          ]),
        ),
      );
}

class StatTile extends StatelessWidget {
  final String t, v;
  final IconData i;
  final Color c;
  const StatTile(this.t, this.v, this.i, this.c, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.line),
          boxShadow: [BoxShadow(color: C.g.withOpacity(.07), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: Stack(fit: StackFit.expand, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(t, style: const TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: const TextStyle(color: C.g, fontSize: 20, fontWeight: FontWeight.w900))),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: c.withOpacity(.12), shape: BoxShape.circle),
                  child: Icon(i, color: c, size: 22),
                ),
              ]),
            ),
            Positioned(top: 0, bottom: 0, right: 0, width: 5, child: ColoredBox(color: c)),
          ]),
        ),
      );
}

class Empty extends StatelessWidget {
  final String text;
  final IconData icon;
  const Empty(this.text, {super.key, this.icon = Icons.inbox_outlined});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 52, color: C.muted.withOpacity(.5)),
            const SizedBox(height: 10),
            Text(text, style: const TextStyle(color: C.muted, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class ImgBox extends StatelessWidget {
  final String? path;
  final double size;
  final IconData fallback;
  final bool circle;
  const ImgBox(this.path, {super.key, this.size = 56, this.fallback = Icons.restaurant, this.circle = false});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(circle ? size : 14),
      child: SizedBox(
        width: size,
        height: size,
        child: imgWidget(path,
            fallback: Container(
              decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFEAF4ED), Color(0xFFF8F3DC)], begin: Alignment.topRight, end: Alignment.bottomLeft)),
              child: Icon(fallback, color: C.g, size: size * .5),
            )),
      ),
    );
  }
}

/// صورة شخصية بإطار ذهبي
class Avatar extends StatelessWidget {
  final String? path;
  final double size;
  final IconData fallback;
  const Avatar(this.path, {super.key, this.size = 56, this.fallback = Icons.person_rounded});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: C.goldGradient),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
          child: ImgBox(path, size: size, circle: true, fallback: fallback),
        ),
      );
}

class PageHead extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const PageHead(this.title, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 2),
        child: Row(children: [
          Container(width: 5, height: 24, decoration: BoxDecoration(gradient: C.goldGradient, borderRadius: BorderRadius.circular(9))),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g))),
          if (trailing != null) trailing!,
        ]),
      );
}

class LuxButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final List<Color> colors;
  final Color fg;
  const LuxButton(this.label, this.icon, this.onTap, {super.key, this.colors = const [C.g, C.g2], this.fg = Colors.white});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .5 : 1,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors, begin: Alignment.topRight, end: Alignment.bottomLeft),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: colors.first.withOpacity(.28), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, color: fg, size: 20),
                  const SizedBox(width: 8),
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 13))),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// حقل اختيار صورة (معرض / كاميرا / رابط) مع معاينة
class ImagePickField extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final IconData fallback;
  final bool circle;
  final double size;
  final bool png;
  final int maxSide;
  const ImagePickField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.fallback = Icons.image_outlined,
    this.circle = false,
    this.size = 84,
    this.png = false,
    this.maxSide = 600,
  });

  @override
  Widget build(BuildContext context) {
    Future<void> pick(bool cam) async {
      final d = await pickImageData(maxSide: maxSide, png: png, camera: cam);
      if (d != null) onChanged(d);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFFBFDFB), borderRadius: BorderRadius.circular(18), border: Border.all(color: C.line)),
      child: Row(children: [
        circle ? Avatar(value, size: size, fallback: fallback) : ImgBox(value, size: size, fallback: fallback),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w900, color: C.g)),
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 2, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                onPressed: () => pick(false),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('المعرض', style: TextStyle(fontSize: 12)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                onPressed: () => pick(true),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('الكاميرا', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: () => _url(context),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('رابط', style: TextStyle(fontSize: 12)),
              ),
              if (value != null && value!.isNotEmpty)
                TextButton.icon(
                  onPressed: () => onChanged(null),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: C.red),
                  label: const Text('حذف', style: TextStyle(fontSize: 12, color: C.red)),
                ),
            ]),
          ]),
        ),
      ]),
    );
  }

  void _url(BuildContext context) {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('رابط الصورة'),
        content: TextField(controller: c, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://...')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final v = c.text.trim();
              Navigator.pop(ctx);
              if (v.isNotEmpty) onChanged(v);
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    );
  }
}

Widget inp(String label, TextEditingController c,
    {TextInputType? type, bool obscure = false, int lines = 1, bool required = false, ValueChanged<String>? onChanged, String? hint}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: c,
      keyboardType: type,
      obscureText: obscure,
      maxLines: lines,
      onChanged: onChanged,
      validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'هذا الحقل مطلوب' : null : null,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

const numType = TextInputType.numberWithOptions(decimal: true);
double num2(String s) => double.tryParse(s.trim().replaceAll(',', '')) ?? 0;

// ====================================================================
//  الربط السحابي (Firebase عبر REST)
// ====================================================================

final GlobalKey<ScaffoldMessengerState> messengerKey = GlobalKey<ScaffoldMessengerState>();

void toastGlobal(String m) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.g,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
}

/// تنبيه صوتي واهتزاز عند وصول شيء مهم
void alertSound() {
  try {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
  } catch (_) {}
}

String cKey(int id) => 'c$id';
String oKey(int id) => 'o$id';
String pKey(int id) => 'p$id';
int _keyNum(String k) => int.tryParse(k.length > 1 ? k.substring(1) : '') ?? 0;
bool _ok(http.Response? r) => r != null && r.statusCode >= 200 && r.statusCode < 300;

Map<String, dynamic> _asMap(dynamic j) {
  if (j is Map) return Map<String, dynamic>.from(j);
  if (j is List) {
    return {for (var i = 0; i < j.length; i++) if (j[i] != null) '$i': j[i]};
  }
  return {};
}

List<Map<String, dynamic>> asMapList(dynamic v) {
  final Iterable it = v is List ? v : (v is Map ? v.values : const []);
  return [for (final e in it) if (e is Map) Map<String, dynamic>.from(e)];
}

String fbErr(String m) {
  final k = m.split(' ').first.trim();
  switch (k) {
    case 'EMAIL_EXISTS':
      return 'اسم الدخول أو البريد مستخدم مسبقاً';
    case 'INVALID_LOGIN_CREDENTIALS':
    case 'INVALID_PASSWORD':
    case 'EMAIL_NOT_FOUND':
      return 'اسم الدخول أو كلمة المرور غير صحيحة';
    case 'WEAK_PASSWORD':
      return 'كلمة المرور ضعيفة (6 أحرف على الأقل)';
    case 'INVALID_EMAIL':
      return 'البريد الإلكتروني غير صالح';
    case 'OPERATION_NOT_ALLOWED':
      return 'فعّل تسجيل الدخول بالبريد وكلمة المرور في Firebase (Authentication)';
    case 'TOO_MANY_ATTEMPTS_TRY_LATER':
      return 'محاولات كثيرة، حاول لاحقاً';
    case 'API_KEY_INVALID':
    case 'INVALID_API_KEY':
      return 'مفتاح Firebase غير صحيح في cloud_config.dart';
    default:
      return 'خطأ: $m';
  }
}

class CloudService extends ChangeNotifier {
  String? email, uid, role, captainKey, name, refreshToken;
  String? _token;
  DateTime _exp = DateTime(2000);
  File? _file;
  String? _ordersEtag;
  Map<String, dynamic>? _ordersCache;
  Map<String, dynamic>? updateInfo;

  bool get configured => !kFbApiKey.startsWith('PASTE') && !kFbDbUrl.startsWith('PASTE');
  bool get signedIn => uid != null && role != null;
  bool get isOwner => signedIn && role == 'owner';
  bool get isCaptain => signedIn && role == 'captain';
  int get captainId => _keyNum(captainKey ?? 'c0');
  String get _base => kFbDbUrl.replaceAll(RegExp(r'/+$'), '');

  Future<void> load() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      _file = File('${d.path}/cloud_session.json');
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        email = j['email'];
        uid = j['uid'];
        role = j['role'];
        captainKey = j['captainKey'];
        name = j['name'];
        refreshToken = j['refreshToken'];
        // جلسة قديمة بلا رمز تجديد: تُعتبر منتهية
        if (refreshToken == null) {
          uid = null;
          role = null;
        }
      }
    } catch (_) {}
  }

  Future<void> _store() async {
    try {
      final f = _file;
      if (f == null) return;
      if (uid == null || role == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(
            jsonEncode({'email': email, 'uid': uid, 'role': role, 'captainKey': captainKey, 'name': name, 'refreshToken': refreshToken}),
            flush: true);
      }
    } catch (_) {}
  }

  Future<void> logout() async {
    email = uid = role = captainKey = name = refreshToken = null;
    _token = null;
    _ordersEtag = null;
    _ordersCache = null;
    await _store();
    notifyListeners();
  }

  // ---- Auth ----
  Future<Map<String, dynamic>> _identity(String op, String em, String pw) async {
    final r = await http
        .post(Uri.parse('https://identitytoolkit.googleapis.com/v1/$op?key=$kFbApiKey'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': em, 'password': pw, 'returnSecureToken': true}))
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<String?> _signInRaw(String em, String pw, {bool create = false}) async {
    try {
      final j = await _identity(create ? 'accounts:signUp' : 'accounts:signInWithPassword', em, pw);
      if (j['error'] != null) return fbErr('${(j['error'] as Map)['message'] ?? ''}');
      _token = j['idToken'] as String;
      _exp = DateTime.now().add(Duration(seconds: int.tryParse('${j['expiresIn']}') ?? 3600));
      uid = j['localId'] as String;
      refreshToken = j['refreshToken'] as String?;
      email = em;
      return null;
    } catch (_) {
      return 'تعذّر الاتصال بالإنترنت';
    }
  }

  /// تجديد الجلسة برمز التجديد (لا نخزّن كلمة المرور على الجهاز)
  Future<bool> _refresh() async {
    final rt = refreshToken;
    if (rt == null) return false;
    try {
      final r = await http
          .post(Uri.parse('https://securetoken.googleapis.com/v1/token?key=$kFbApiKey'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'grant_type=refresh_token&refresh_token=$rt')
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body);
      if (j is Map && j['id_token'] != null) {
        _token = '${j['id_token']}';
        _exp = DateTime.now().add(Duration(seconds: int.tryParse('${j['expires_in']}') ?? 3600));
        if (j['refresh_token'] != null) refreshToken = '${j['refresh_token']}';
        await _store();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<String?> _tok() async {
    if (_token != null && DateTime.now().isBefore(_exp.subtract(const Duration(minutes: 2)))) return _token;
    if (await _refresh()) return _token;
    return null;
  }

  // ---- قاعدة البيانات ----
  Future<http.Response?> _req(String method, Uri uri, Object? body, Map<String, String> h) async {
    try {
      final Future<http.Response> f = switch (method) {
        'GET' => http.get(uri, headers: h),
        'PUT' => http.put(uri, headers: h, body: jsonEncode(body)),
        'POST' => http.post(uri, headers: h, body: jsonEncode(body)),
        'DELETE' => http.delete(uri, headers: h),
        _ => http.patch(uri, headers: h, body: jsonEncode(body)),
      };
      return await f.timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    }
  }

  Future<http.Response?> _db(String method, String path, {Object? body, Map<String, String>? q, Map<String, String>? hdr}) async {
    final t = await _tok();
    if (t == null) return null;
    final uri = Uri.parse('$_base/$path.json').replace(queryParameters: {'auth': t, ...?q});
    return _req(method, uri, body, <String, String>{'Content-Type': 'application/json', ...?hdr});
  }

  /// طلب عام بدون مصادقة (القائمة والتحديثات)
  Future<http.Response?> _pub(String method, String path, {Object? body}) async {
    if (!configured) return null;
    return _req(method, Uri.parse('$_base/$path.json'), body, {'Content-Type': 'application/json'});
  }

  Future<void> checkUpdate() async {
    final r = await _pub('GET', 'meta');
    if (_ok(r)) {
      final j = jsonDecode(r!.body);
      if (j is Map) {
        updateInfo = Map<String, dynamic>.from(j);
        notifyListeners();
      }
    }
  }

  // ---- تفعيل حساب المالك ----
  Future<String?> ownerActivate(String em, String pw, String ownerName) async {
    if (!configured) return 'أكمل إعدادات Firebase في ملف cloud_config.dart أولاً';
    var e = await _signInRaw(em, pw, create: true);
    if (e != null && e == fbErr('EMAIL_EXISTS')) e = await _signInRaw(em, pw);
    if (e != null) return e;
    final g = await _db('GET', 'users/$uid');
    if (g == null) return 'تعذّر الاتصال بقاعدة البيانات، تأكد من الرابط في cloud_config.dart';
    if (!_ok(g)) return 'رُفض الوصول: تأكد من نشر قواعد قاعدة البيانات (Rules)';
    final cur = jsonDecode(g.body);
    if (cur is Map && cur['role'] == 'owner') {
      // حساب مالك موجود
    } else if (cur == null) {
      final p = await _db('PUT', 'users/$uid', body: {'role': 'owner', 'name': ownerName});
      if (!_ok(p)) return 'يوجد مالك مسجّل بحساب آخر، أو القواعد غير منشورة';
    } else {
      return 'هذا الحساب مسجّل بدور آخر';
    }
    role = 'owner';
    captainKey = null;
    name = ownerName;
    await _store();
    notifyListeners();
    return null;
  }

  // ---- حسابات الكباتن (المالك) ----
  String captainEmail(String login) => '${login.trim().toLowerCase()}@saladbar.app';

  Future<(String?, String?)> createCaptainAccount(int cid, String cname, String login, String pw) async {
    if (!isOwner) return ('فعّل الربط السحابي من الإعدادات أولاً', null);
    final l = login.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(l)) return ('اسم الدخول: حروف إنجليزية وأرقام فقط (3 أحرف على الأقل)', null);
    if (pw.length < 6) return ('كلمة المرور 6 أحرف على الأقل', null);
    try {
      final j = await _identity('accounts:signUp', captainEmail(l), pw);
      if (j['error'] != null) return (fbErr('${(j['error'] as Map)['message'] ?? ''}'), null);
      final newUid = j['localId'] as String;
      final r = await _db('PUT', 'users/$newUid', body: {'role': 'captain', 'captainId': cKey(cid), 'name': cname, 'login': l});
      if (!_ok(r)) return ('تعذّر ربط الحساب بقاعدة البيانات', null);
      return (null, newUid);
    } catch (_) {
      return ('تعذّر الاتصال بالإنترنت', null);
    }
  }

  Future<bool> revokeCaptain(String captainUid) async => _ok(await _db('DELETE', 'users/$captainUid'));

  // ---- المالك: رفع الطلبات والحسابات ----
  Future<bool> putOrder(int cid, int oid, Map<String, dynamic> data) async =>
      _ok(await _db('PUT', 'captainOrders/${cKey(cid)}/${oKey(oid)}', body: data));

  Future<bool> deleteOrder(int cid, int oid) async => _ok(await _db('DELETE', 'captainOrders/${cKey(cid)}/${oKey(oid)}'));

  Future<bool> putStats(int cid, Map<String, dynamic> data) async => _ok(await _db('PUT', 'captainStats/${cKey(cid)}', body: data));

  Future<List<int>?> listOrderIds(int cid) async {
    final r = await _db('GET', 'captainOrders/${cKey(cid)}', q: {'shallow': 'true'});
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    if (j is Map) return [for (final k in j.keys) _keyNum('$k')];
    return [];
  }

  Future<List<Map<String, dynamic>>?> fetchInbox() async {
    final r = await _db('GET', 'inbox');
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    final out = <Map<String, dynamic>>[];
    if (j is Map) {
      j.forEach((ck, v) {
        if (v is Map) {
          v.forEach((ok2, d) {
            if (d is Map) {
              out.add({
                'cid': _keyNum('$ck'),
                'oid': _keyNum('$ok2'),
                'status': '${d['status']}',
                'name': '${d['name'] ?? ''}',
                'at': d['at'],
                'proof': d['proof'],
                'lat': d['lat'],
                'lng': d['lng'],
              });
            }
          });
        }
      });
    }
    return out;
  }

  Future<bool> deleteInbox(int cid, int oid) async => _ok(await _db('DELETE', 'inbox/${cKey(cid)}/${oKey(oid)}'));

  // ---- المشتريات الخارجية ----
  Future<bool> putPurchase(int cid, int pid, Map<String, dynamic> data) async =>
      _ok(await _db('PUT', 'captainPurchases/${cKey(cid)}/${pKey(pid)}', body: data));

  Future<bool> deletePurchase(int cid, int pid) async => _ok(await _db('DELETE', 'captainPurchases/${cKey(cid)}/${pKey(pid)}'));

  Future<List<Map<String, dynamic>>?> fetchPurchaseInbox() async {
    final r = await _db('GET', 'purchaseInbox');
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    final out = <Map<String, dynamic>>[];
    if (j is Map) {
      j.forEach((ck, v) {
        if (v is Map) {
          v.forEach((pk, d) {
            if (d is Map) {
              out.add({
                'cid': _keyNum('$ck'),
                'pid': _keyNum('$pk'),
                'actual': d['actual'],
                'note': '${d['note'] ?? ''}',
                'receipt': d['receipt'],
                'at': d['at'],
              });
            }
          });
        }
      });
    }
    return out;
  }

  Future<bool> deletePurchaseInbox(int cid, int pid) async => _ok(await _db('DELETE', 'purchaseInbox/${cKey(cid)}/${pKey(pid)}'));

  // ---- القائمة الإلكترونية ----
  Future<bool> publishMenu(Map<String, dynamic> menu) async => _ok(await _db('PUT', 'menu', body: menu));

  Future<bool> putMenuKey(String k) async => _ok(await _db('PUT', 'menuKey', body: k));

  Future<bool> putMenuImg(String id, String dataUrl) async => _ok(await _db('PUT', 'menuImg/$id', body: dataUrl));

  Future<List<Map<String, dynamic>>?> fetchPendingWeb() async {
    final r = await _db('GET', 'publicOrders', q: {'orderBy': '"status"', 'equalTo': '"pending"'});
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    final out = <Map<String, dynamic>>[];
    if (j is Map) {
      j.forEach((k, v) {
        if (v is Map) out.add({...Map<String, dynamic>.from(v), '_key': '$k'});
      });
    }
    return out;
  }

  Future<bool> setPublic(String key, Map<String, dynamic> patch) async => _ok(await _db('PATCH', 'publicOrders/$key', body: patch));

  Future<bool> putTrack(String key, Map<String, dynamic> data) async => _ok(await _db('PATCH', 'orderTrack/$key', body: data));

  /// حذف طلبات القائمة الإلكترونية الأقدم من تاريخ معيّن (مع صفحة التتبع)
  Future<void> cleanWebOld(DateTime before) async {
    final r = await _db('GET', 'publicOrders', q: {'orderBy': '"createdAt"', 'endAt': '"${before.toUtc().toIso8601String()}"', 'limitToFirst': '50'});
    if (!_ok(r)) return;
    final j = jsonDecode(r!.body);
    if (j is! Map) return;
    for (final k in j.keys) {
      await _db('DELETE', 'publicOrders/$k');
      await _db('DELETE', 'orderTrack/$k');
    }
  }

  Future<List<Map<String, dynamic>>?> fetchPublicOrders() async {
    final r = await _db('GET', 'publicOrders');
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    final out = <Map<String, dynamic>>[];
    if (j is Map) {
      j.forEach((k, v) {
        if (v is Map) out.add({...Map<String, dynamic>.from(v), '_key': '$k'});
      });
    }
    return out;
  }

  Future<bool> deletePublicOrder(String key) async => _ok(await _db('DELETE', 'publicOrders/$key'));

  // ---- النسخ الاحتياطي ----
  Future<bool> putBackup(String data) async =>
      _ok(await _db('PUT', 'backups/$uid', body: {'at': DateTime.now().toIso8601String(), 'size': data.length, 'data': data}));

  Future<Map<String, dynamic>?> getBackup() async {
    final r = await _db('GET', 'backups/$uid');
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
  }

  Future<String?> backupTime() async {
    final r = await _db('GET', 'backups/$uid/at');
    if (!_ok(r)) return null;
    final j = jsonDecode(r!.body);
    return j is String ? j : null;
  }

  // ---- الكابتن ----
  Future<String?> captainLogin(String login, String pw) async {
    if (!configured) return 'لم يُضبط Firebase في التطبيق، راجع صاحب المتجر';
    final e = await _signInRaw(captainEmail(login), pw);
    if (e != null) return e;
    final g = await _db('GET', 'users/$uid');
    if (!_ok(g)) {
      await logout();
      return 'تعذّر الاتصال بقاعدة البيانات';
    }
    final cur = jsonDecode(g!.body);
    if (cur is! Map || cur['role'] != 'captain') {
      await logout();
      return 'هذا الحساب غير مفعّل كابتن لدى صاحب المتجر';
    }
    role = 'captain';
    captainKey = '${cur['captainId']}';
    name = '${cur['name'] ?? ''}';
    await _store();
    notifyListeners();
    return null;
  }

  /// null = فشل الاتصال، {} = لا توجد طلبات
  Future<Map<String, dynamic>?> fetchMyOrders() async {
    if (captainKey == null) return null;
    final r = await _db('GET', 'captainOrders/$captainKey',
        hdr: {'X-Firebase-ETag': 'true', if (_ordersEtag != null) 'if-none-match': _ordersEtag!});
    if (r == null) return null;
    if (r.statusCode == 304) return _ordersCache ?? {};
    if (!_ok(r)) return null;
    _ordersEtag = r.headers['etag'];
    _ordersCache = _asMap(jsonDecode(r.body));
    return _ordersCache;
  }

  Future<Map<String, dynamic>?> fetchMyStats() async {
    if (captainKey == null) return null;
    final r = await _db('GET', 'captainStats/$captainKey');
    if (!_ok(r)) return null;
    return _asMap(jsonDecode(r!.body));
  }

  Future<Map<String, dynamic>?> fetchMyPurchases() async {
    if (captainKey == null) return null;
    final r = await _db('GET', 'captainPurchases/$captainKey');
    if (!_ok(r)) return null;
    return _asMap(jsonDecode(r!.body));
  }

  Future<bool> captainSetStatus(int oid, String status, {String? proof, double? lat, double? lng}) async {
    if (captainKey == null) return false;
    final inbox = await _db('PUT', 'inbox/$captainKey/${oKey(oid)}', body: {
      'status': status,
      'at': DateTime.now().toIso8601String(),
      'name': name ?? '',
      if (proof != null) 'proof': proof,
      if (lat != null && lng != null) ...{'lat': lat, 'lng': lng},
    });
    if (!_ok(inbox)) return false;
    await _db('PUT', 'captainOrders/$captainKey/${oKey(oid)}/status', body: status);
    _ordersEtag = null;
    return true;
  }

  Future<bool> captainSendLocation(int oid, String status, double lat, double lng) async {
    if (captainKey == null) return false;
    return _ok(await _db('PUT', 'inbox/$captainKey/${oKey(oid)}',
        body: {'status': status, 'at': DateTime.now().toIso8601String(), 'name': name ?? '', 'lat': lat, 'lng': lng}));
  }

  Future<bool> submitPurchase(int pid, double actual, String note, String? receipt) async {
    if (captainKey == null) return false;
    return _ok(await _db('PUT', 'purchaseInbox/$captainKey/${pKey(pid)}', body: {
      'actual': actual,
      'note': note,
      'at': DateTime.now().toIso8601String(),
      'name': name ?? '',
      if (receipt != null) 'receipt': receipt,
    }));
  }

  // ---- فحص الاتصال ----
  Future<List<String>> diagnose() async {
    final out = <String>[];
    if (!configured) return ['✗ لم تُضبط قيم Firebase في cloud_config.dart'];
    out.add('✓ إعدادات Firebase موجودة');
    if (!signedIn) {
      out.add('✗ غير مسجّل الدخول (فعّل الربط أولاً)');
      return out;
    }
    out.add('✓ مسجّل الدخول (${role == 'owner' ? 'مالك' : 'كابتن'})');
    final t = await _tok();
    out.add(t != null ? '✓ الجلسة صالحة' : '✗ تعذّر تجديد الجلسة، أعد الدخول');
    if (t == null) return out;
    final g = await _db('GET', 'users/$uid');
    out.add(_ok(g) ? '✓ قراءة بيانات المستخدم' : '✗ رُفضت القراءة أو لا يوجد اتصال — راجع القواعد والرابط');
    if (isOwner) {
      final i = await _db('GET', 'inbox');
      out.add(_ok(i) ? '✓ قراءة صندوق الكباتن' : '✗ تعذّرت قراءة صندوق الكباتن — حدّث القواعد');
      final pu = await _db('GET', 'publicOrders');
      out.add(_ok(pu) ? '✓ قراءة طلبات القائمة الإلكترونية' : '✗ تعذّرت قراءة طلبات القائمة — حدّث القواعد');
    }
    final m = await _pub('GET', 'meta');
    out.add(_ok(m) ? '✓ قراءة معلومات الإصدار' : '✗ تعذّرت قراءة /meta — حدّث القواعد');
    return out;
  }
}

final CloudService cloud = CloudService();

// ====================================================================
//  المخزن (Store)
// ====================================================================

T? _find<T>(List<T> l, bool Function(T) t) {
  for (final x in l) {
    if (t(x)) return x;
  }
  return null;
}

class AppStore extends ChangeNotifier {
  bool ready = false, loggedIn = false;
  AppSettings settings = AppSettings();
  List<Product> products = [];
  List<Customer> customers = [];
  List<Captain> captains = [];
  List<Order> orders = [];
  List<Settlement> settlements = [];
  List<Purchase> purchases = [];
  List<CustomerPayment> customerPayments = [];
  List<StockMove> stockMoves = [];
  List<DayClose> closes = [];
  List<Map<String, dynamic>> webOrders = [];
  final Set<String> _seenWeb = {};
  bool _webInit = false;
  Timer? _menuTimer;
  String _menuHash = '';
  String? _keySent;
  final Map<String, String> _imgSig = {};
  DateTime? menuPublishedAt;
  bool _captainsFixed = false;
  int _nP = 1, _nC = 1, _nCap = 1, _nO = 1;

  void init(String? raw) {
    var ok = false;
    if (raw != null) {
      try {
        _load(jsonDecode(raw) as Map<String, dynamic>);
        ok = true;
        _persist(jsonEncode(toJson()));
      } catch (_) {}
    }
    if (!ok) _seed();
    loggedIn = false;
    ready = true;
  }

  void _seed() {
    settings = AppSettings(storeAddress: 'مكرونة مخلوطة .. طعم يرضيك')..setPassword('1234');
    products = [];
    _nP = 1;
    void add(String n, double p) => products.add(Product(id: _nP++, name: n, price: p, stock: 0, lowStock: 10, track: false));
    for (final f in ['عادي', 'ليمون', 'سبايسي']) {
      add('سلطة البار - $f - كبير', 1500);
      add('سلطة البار - $f - وسط', 800);
      add('سلطة البار - $f - صغير', 500);
    }
    add('سلطة الذرة بالدريتوس - كبير', 1700);
    add('سلطة الذرة بالدريتوس - وسط', 1000);
    add('سلطة الذرة بالدريتوس - صغير', 700);
    for (final f in ['فراولة وبلوبيري', 'عنب+توت', 'خوخ', 'ليمون']) {
      add('موهيتو - $f', 600);
    }
    customers = [
      Customer(id: 1, name: 'عميل تجريبي', phone: '967700000000', address: 'صنعاء', notes: 'يفضل الاتصال قبل التوصيل'),
    ];
    captains = [
      Captain(id: 1, name: 'كابتن أسامة وهان', phone: '967783182367'),
    ];
    orders = [];
    settlements = [];
    purchases = [];
    customerPayments = [];
    stockMoves = [];
    closes = [];
    _captainsFixed = true;
    _nC = 2;
    _nCap = 2;
    _nO = 1;
  }

  void _load(Map<String, dynamic> j) {
    settings = AppSettings.fromJson(Map<String, dynamic>.from(j['settings'] ?? {}));
    products = (j['products'] as List).map((e) => Product.fromJson(Map<String, dynamic>.from(e))).toList();
    customers = (j['customers'] as List).map((e) => Customer.fromJson(Map<String, dynamic>.from(e))).toList();
    captains = (j['captains'] as List).map((e) => Captain.fromJson(Map<String, dynamic>.from(e))).toList();
    orders = (j['orders'] as List).map((e) => Order.fromJson(Map<String, dynamic>.from(e))).toList();
    settlements = ((j['settlements'] ?? []) as List).map((e) => Settlement.fromJson(Map<String, dynamic>.from(e))).toList();
    purchases = ((j['purchases'] ?? []) as List).map((e) => Purchase.fromJson(Map<String, dynamic>.from(e))).toList();
    customerPayments = ((j['customerPayments'] ?? []) as List).map((e) => CustomerPayment.fromJson(Map<String, dynamic>.from(e))).toList();
    stockMoves = ((j['stockMoves'] ?? []) as List).map((e) => StockMove.fromJson(Map<String, dynamic>.from(e))).toList();
    closes = ((j['closes'] ?? []) as List).map((e) => DayClose.fromJson(Map<String, dynamic>.from(e))).toList();
    _nP = (products.map((e) => e.id).fold(0, max)) + 1;
    _nC = (customers.map((e) => e.id).fold(0, max)) + 1;
    _nCap = (captains.map((e) => e.id).fold(0, max)) + 1;
    _nO = (orders.map((e) => e.id).fold(0, max)) + 1;
    _captainsFixed = j['captainsFixV1'] == true;
    if (!_captainsFixed) {
      _fixCaptains();
      _captainsFixed = true;
    }
  }

  /// مرة واحدة: حذف الكباتن الافتراضيين القدامى (إن لم يكن لهم حركة) وإضافة الكابتن أسامة وهان
  void _fixCaptains() {
    const oldPhones = {'967733333333', '967744444444'};
    captains.removeWhere((c) =>
        oldPhones.contains(c.phone) &&
        !orders.any((o) => o.captainId == c.id) &&
        !settlements.any((x) => x.captainId == c.id) &&
        !purchases.any((x) => x.captainId == c.id));
    if (!captains.any((c) => waNumber(c.phone) == '967783182367')) {
      captains.add(Captain(id: _nCap++, name: 'كابتن أسامة وهان', phone: '967783182367'));
    }
  }

  Map<String, dynamic> toJson() => {
        'settings': settings.toJson(),
        'products': products.map((e) => e.toJson()).toList(),
        'customers': customers.map((e) => e.toJson()).toList(),
        'captains': captains.map((e) => e.toJson()).toList(),
        'orders': orders.map((e) => e.toJson()).toList(),
        'settlements': settlements.map((e) => e.toJson()).toList(),
        'purchases': purchases.map((e) => e.toJson()).toList(),
        'customerPayments': customerPayments.map((e) => e.toJson()).toList(),
        'stockMoves': stockMoves.map((e) => e.toJson()).toList(),
        'closes': closes.map((e) => e.toJson()).toList(),
        'captainsFixV1': _captainsFixed,
      };

  Timer? _saveTimer, _backupTimer;
  bool _needsFlush = false, _backupDirty = false;
  DateTime? lastBackupAt;

  /// حفظ مؤجّل (نصف ثانية) لتخفيف الكتابة، ويُفرَّغ فوراً عند إغلاق التطبيق
  void _save() {
    _needsFlush = true;
    _backupDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
    notifyListeners();
    _scheduleStats();
    _scheduleMenu();
  }

  void flush() {
    _saveTimer?.cancel();
    if (!_needsFlush) return;
    _needsFlush = false;
    _persist(jsonEncode(toJson()));
  }

  Future<String?> _embed(String? p) async {
    if (p == null || p.isEmpty) return null;
    if (p.startsWith('http')) return p;
    return await fileToDataUrl(p);
  }

  Future<String?> _local(String? v) async => (v != null && v.startsWith('data:')) ? await saveDataUrl(v) : v;

  /// نسخة كاملة تتضمن الصور (تُحوَّل من ملفات إلى نصوص)
  Future<String> exportJsonFull({bool compact = false, bool images = true}) async {
    final m = toJson();
    final st = Map<String, dynamic>.from(m['settings'] as Map);
    st['logoPath'] = images ? await _embed(settings.logoPath) : null;
    st['ownerImage'] = images ? await _embed(settings.ownerImage) : null;
    m['settings'] = st;
    final ps = <Map<String, dynamic>>[];
    for (final p in products) {
      final j = p.toJson();
      j['imagePath'] = images ? await _embed(p.imagePath) : null;
      ps.add(j);
    }
    m['products'] = ps;
    final prs = <Map<String, dynamic>>[];
    for (final pr in purchases) {
      final j = pr.toJson();
      j['receipt'] = images ? await _embed(pr.receipt) : null;
      prs.add(j);
    }
    m['purchases'] = prs;
    return compact ? jsonEncode(m) : const JsonEncoder.withIndent('  ').convert(m);
  }

  Future<void> _localizeImages() async {
    settings.logoPath = await _local(settings.logoPath);
    settings.ownerImage = await _local(settings.ownerImage);
    for (final p in products) {
      p.imagePath = await _local(p.imagePath);
    }
    for (final pr in purchases) {
      pr.receipt = await _local(pr.receipt);
    }
  }

  /// ترحيل الصور القديمة المخزنة داخل الملف الرئيسي إلى ملفات مستقلة (مرة واحدة)
  Future<void> migrateImages() async {
    final has = (settings.logoPath ?? '').startsWith('data:') ||
        (settings.ownerImage ?? '').startsWith('data:') ||
        products.any((p) => (p.imagePath ?? '').startsWith('data:')) ||
        purchases.any((p) => (p.receipt ?? '').startsWith('data:'));
    if (!has) return;
    await _localizeImages();
    _save();
    flush();
  }

  Future<bool> importJson(String text) async {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (!j.containsKey('products') || !j.containsKey('customers') || !j.containsKey('captains') || !j.containsKey('orders')) {
        return false;
      }
      _load(j);
      await _localizeImages();
      _save();
      flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- نسخ احتياطي سحابي ----
  Future<bool> backupNow() async {
    if (!cloud.isOwner) return false;
    var data = await exportJsonFull(compact: true);
    if (data.length > 9000000) data = await exportJsonFull(compact: true, images: false);
    final ok = await cloud.putBackup(data);
    if (ok) {
      lastBackupAt = DateTime.now();
      _backupDirty = false;
      notifyListeners();
    }
    return ok;
  }

  Future<String?> restoreFromCloud() async {
    final b = await cloud.getBackup();
    if (b == null) return 'تعذّر الاتصال بالسحابة';
    final data = b['data'];
    if (data is! String || data.isEmpty) return 'لا توجد نسخة احتياطية في السحابة';
    return await importJson(data) ? null : 'النسخة الاحتياطية غير صالحة';
  }

  void resetAll() {
    _seed();
    _save();
  }

  // ---- Auth ----
  bool login(String u, String p) {
    if (u.trim() == settings.username && settings.checkPassword(p)) {
      loggedIn = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  void logout() {
    loggedIn = false;
    notifyListeners();
  }

  void updateCredentials(String u, String p) {
    settings.username = u;
    if (p.isNotEmpty) {
      settings.setPassword(p);
      settings.mustChange = false;
    }
    _save();
  }

  void updateStore({required String name, required String phone, required String address, required String ownerName}) {
    settings.storeName = name.isEmpty ? 'سلطة بار' : name;
    settings.storePhone = phone;
    settings.storeAddress = address;
    settings.ownerName = ownerName.isEmpty ? 'صاحب المتجر' : ownerName;
    _save();
  }

  void setLogo(String? v) {
    settings.logoPath = v;
    _save();
  }

  void setOwnerImage(String? v) {
    settings.ownerImage = v;
    _save();
  }

  // ---- Lookups ----
  Product? product(int id) => _find(products, (x) => x.id == id);
  Customer? customer(int id) => _find(customers, (x) => x.id == id);
  Captain? captain(int id) => _find(captains, (x) => x.id == id);
  Order? order(int id) => _find(orders, (x) => x.id == id);

  // ---- Products ----
  void saveProduct(Product p) {
    if (p.id == 0) {
      p.id = _nP++;
      products.add(p);
    }
    _save();
  }

  void deleteProduct(int id) {
    products.removeWhere((x) => x.id == id);
    _save();
  }

  /// action: set | add | subtract
  String? adjustStock(int id, String action, double amount) {
    final p = product(id);
    if (p == null) return 'الصنف غير موجود';
    if (amount < 0) return 'أدخل كمية صحيحة';
    if (p.isPiece && amount != amount.roundToDouble()) return 'هذا الصنف بالقطعة ويجب إدخال رقم صحيح';
    double next = p.stock;
    if (action == 'set') {
      next = amount;
    } else if (action == 'add') {
      next += amount;
    } else {
      next -= amount;
    }
    if (next < 0) return 'لا يمكن أن يصبح المخزون بالسالب';
    final delta = next - p.stock;
    p.stock = next;
    if (delta != 0) _logMove(p, delta, action == 'set' ? 'count' : 'manual', action == 'set' ? 'جرد/تحديد الكمية' : (delta > 0 ? 'إضافة توريد' : 'خصم يدوي'));
    _save();
    return null;
  }

  // ---- Customers ----
  void saveCustomer(Customer c) {
    // بعد الحفظ تُحدَّث نسخ الطلبات الحديثة عند الكابتن (العنوان/الموقع)
    Future.microtask(() {
      if (!cloud.isOwner) return;
      for (final o in orders.where((o) => o.customerId == c.id && _recent(o)).toList()) {
        _syncOrder(o);
      }
    });
    if (c.id == 0) {
      c.id = _nC++;
      customers.add(c);
    }
    _save();
  }

  String? deleteCustomer(int id) {
    if (orders.any((o) => o.customerId == id)) return 'لا يمكن حذف عميل لديه طلبات محفوظة؛ عدّل بياناته بدلاً من الحذف';
    customers.removeWhere((x) => x.id == id);
    _save();
    return null;
  }

  // ---- Captains ----
  void saveCaptain(Captain c) {
    if (c.id == 0) {
      c.id = _nCap++;
      captains.add(c);
    }
    _save();
  }

  void toggleCaptain(int id) {
    final c = captain(id);
    if (c == null) return;
    c.available = !c.available;
    _save();
  }

  String? deleteCaptain(int id) {
    if (orders.any((o) => o.captainId == id && o.status != 'cancel')) return 'لا يمكن حذف كابتن لديه طلبات غير ملغاة';
    final capUid = captain(id)?.cloudUid;
    if (capUid != null && cloud.isOwner) cloud.revokeCaptain(capUid);
    captains.removeWhere((x) => x.id == id);
    settlements.removeWhere((x) => x.captainId == id);
    purchases.removeWhere((x) => x.captainId == id);
    _save();
    return null;
  }

  void savePurchase(Purchase p) {
    if (p.id == 0) {
      p.id = DateTime.now().millisecondsSinceEpoch;
      purchases.add(p);
    }
    _save();
  }

  void deletePurchase(int id) {
    purchases.removeWhere((x) => x.id == id);
    _save();
  }

  Balances balances(int captainId) {
    double cash = 0, credit = 0;
    for (final o in orders) {
      if (o.captainId == captainId && o.status != 'cancel') {
        cash += o.goodsDue;
        credit += o.captainCredit;
      }
    }
    for (final pr in purchases) {
      if (pr.captainId != captainId) continue;
      if (!pr.closed) {
        cash += pr.given; // عهدة بيد الكابتن لم تُسجَّل تكلفتها بعد
      } else if (pr.actual > pr.given) {
        credit += pr.actual - pr.given; // زيادة دفعها الكابتن من جيبه
      } else {
        cash += pr.given - pr.actual; // متبقٍّ يعيده للمحل
      }
    }
    double paidBy = 0, paidTo = 0;
    for (final s in settlements) {
      if (s.captainId != captainId) continue;
      if (s.type == 'captain_paid') {
        paidBy += s.amount;
      } else {
        paidTo += s.amount;
      }
    }
    return Balances(max(0, cash - paidBy), max(0, credit - paidTo));
  }

  String? addSettlement(int captainId, String type, double amount, String note) {
    if (amount <= 0) return 'أدخل مبلغاً صحيحاً';
    final b = balances(captainId);
    final maxAmount = type == 'captain_paid' ? b.cashDue : b.creditDue;
    if (amount > maxAmount + 0.000001) return 'المبلغ أكبر من الرصيد المتاح';
    settlements.add(Settlement(
        id: DateTime.now().millisecondsSinceEpoch, captainId: captainId, type: type, amount: amount, note: note, date: DateTime.now()));
    _save();
    return null;
  }

  // ---- الربط السحابي ----
  final Set<int> _dirty = {};
  Timer? _poll, _statsTimer;
  bool _polling = false;

  Map<String, dynamic> orderSnapshot(Order o) {
    final c = customer(o.customerId);
    return {
      'id': o.id,
      'captainId': o.captainId,
      'date': o.date.toIso8601String(),
      'status': o.status,
      'method': o.method,
      'customerName': c?.name ?? '',
      'customerPhone': c?.phone ?? '',
      'customerAddress': c?.address ?? '',
      'customerNotes': c?.notes ?? '',
      'customerLat': c?.lat,
      'customerLng': c?.lng,
      'items': [
        for (final i in o.items) {'name': i.name, 'qty': i.qty, 'unit': i.unit, 'price': i.price, 'total': i.lineTotal}
      ],
      'subtotal': o.subtotal,
      'discount': o.discount,
      'delivery': o.delivery,
      'total': o.total,
      'customerDue': o.customerDue,
      'paidAmount': o.paidAmount,
      'goodsDue': o.goodsDue,
      'notes': o.notes,
      'store': settings.storeName,
    };
  }

  bool _recent(Order o) =>
      o.status == 'new' || o.status == 'prep' || o.status == 'delivery' || DateTime.now().difference(o.date).inDays < 2;

  int _rank(String s) => switch (s) { 'new' => 0, 'prep' => 1, 'delivery' => 2, 'done' => 3, _ => -1 };

  Future<bool> _pushOrder(Order o) async {
    final ok = await cloud.putOrder(o.captainId, o.id, orderSnapshot(o));
    if (ok) {
      _dirty.remove(o.id);
    } else {
      _dirty.add(o.id);
    }
    return ok;
  }

  void _syncOrder(Order o) {
    if (cloud.isOwner) {
      _pushOrder(o);
      _pushWebStatus(o);
    }
  }

  void _scheduleStats() {
    if (!cloud.isOwner) return;
    _statsTimer?.cancel();
    _statsTimer = Timer(const Duration(seconds: 3), pushStats);
  }

  Future<void> pushStats() async {
    if (!cloud.isOwner) return;
    for (final c in captains.where((c) => c.login != null)) {
      final b = balances(c.id);
      await cloud.putStats(c.id, {
        'cashDue': b.cashDue,
        'creditDue': b.creditDue,
        'net': b.net,
        'name': c.name,
        'store': settings.storeName,
        'at': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<void> pushCaptain(int cid) async {
    for (final o in orders.where((o) => o.captainId == cid && _recent(o)).toList()) {
      await _pushOrder(o);
    }
    await pushStats();
  }

  /// يرفع الطلبات الحديثة والحسابات ثم ينظّف السحابة من القديم
  Future<int> fullSync() async {
    if (!cloud.isOwner) return 0;
    var n = 0;
    for (final o in orders.where(_recent).toList()) {
      if (await _pushOrder(o)) n++;
    }
    await pushStats();
    await cleanupCloud();
    return n;
  }

  Future<void> cleanupCloud() async {
    final now = DateTime.now();
    if (settings.onlineEnabled) await cloud.cleanWebOld(now.subtract(const Duration(days: 3)));
    for (final c in captains.where((c) => c.login != null).toList()) {
      final ids = await cloud.listOrderIds(c.id);
      if (ids == null) continue;
      for (final oid in ids) {
        final o = order(oid);
        final old = o == null || ((o.status == 'done' || o.status == 'cancel') && now.difference(o.date).inDays >= 2);
        if (old) await cloud.deleteOrder(c.id, oid);
      }
    }
  }

  void startCloud() {
    _poll?.cancel();
    if (!cloud.isOwner) return;
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => pollCloud());
    _backupTimer?.cancel();
    _backupTimer = Timer.periodic(const Duration(minutes: 20), (_) {
      if (_backupDirty) backupNow();
    });
    Future.delayed(const Duration(seconds: 40), () {
      if (cloud.isOwner) backupNow();
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (cloud.isOwner && settings.onlineEnabled) publishMenuNow(force: true);
    });
    fullSync();
  }

  void stopCloud() {
    _poll?.cancel();
    _poll = null;
    _backupTimer?.cancel();
    _menuTimer?.cancel();
  }

  Future<void> pollCloud() async {
    if (_polling || !cloud.isOwner) return;
    _polling = true;
    try {
      for (final id in _dirty.toList()) {
        final o = order(id);
        if (o == null) {
          _dirty.remove(id);
        } else {
          await _pushOrder(o);
        }
      }
      final inbox = await cloud.fetchInbox();
      if (inbox == null) return;
      for (final m in inbox) {
        final cid = m['cid'] as int, oid = m['oid'] as int;
        final st = '${m['status']}';
        final o = order(oid);
        if (o != null && o.captainId == cid && (st == 'delivery' || st == 'done') && _rank(st) > _rank(o.status)) {
          changeStatus(o, st);
          toastGlobal('${captain(cid)?.name ?? 'الكابتن'}: الطلب #$oid ← ${statusLabel(st)}');
        }
        final la = m['lat'], ln = m['lng'];
        if (o != null && o.captainId == cid && la is num && ln is num) {
          final cu = customer(o.customerId);
          if (cu != null) {
            cu.lat = la.toDouble();
            cu.lng = ln.toDouble();
            _save();
            _syncOrder(o);
            toastGlobal('تم تحديث موقع ${cu.name} من الكابتن 📍');
          }
        }
        await cloud.deleteInbox(cid, oid);
      }
      if (settings.onlineEnabled) await refreshWeb();
    } finally {
      _polling = false;
    }
  }

  // ---- القائمة الإلكترونية (طلب العميل) ----
  String _newKey() {
    const ch = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return String.fromCharCodes(List.generate(10, (_) => ch.codeUnitAt(r.nextInt(ch.length))));
  }

  String _linkBase(String param, String value) {
    final base = settings.menuUrl.trim();
    if (base.isEmpty) return '';
    final db = kFbDbUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base${base.contains('?') ? '&' : '?'}db=${Uri.encodeComponent(db)}&$param=$value';
  }

  String get menuLink => settings.menuKey.isEmpty ? '' : _linkBase('k', settings.menuKey);
  String trackLink(String key) => _linkBase('t', key);

  Future<void> updateOnline({
    bool? enabled,
    bool? open,
    String? url,
    double? fee,
    double? minOrder,
    String? note,
    List<Map<String, dynamic>>? pays,
    bool publish = true,
  }) async {
    if (enabled != null) settings.onlineEnabled = enabled;
    if (open != null) settings.onlineOpen = open;
    if (url != null) settings.menuUrl = url.trim();
    if (fee != null) settings.onlineFee = fee;
    if (minOrder != null) settings.minOrder = minOrder;
    if (note != null) settings.onlineNote = note.trim();
    if (pays != null) settings.payMethods = pays;
    if (settings.onlineEnabled && settings.menuKey.isEmpty) settings.menuKey = _newKey();
    _save();
    if (publish && cloud.isOwner) await publishMenuNow(force: true);
  }

  Future<void> rotateMenuKey() async {
    settings.menuKey = _newKey();
    _keySent = null;
    _save();
    if (cloud.isOwner) await publishMenuNow(force: true);
  }

  Map<String, dynamic> _menuJson() => {
        'enabled': settings.onlineEnabled,
        'open': settings.onlineOpen,
        'store': settings.storeName,
        'tagline': settings.storeAddress,
        'phone': settings.storePhone,
        'logo': (settings.logoPath ?? '').isNotEmpty,
        'note': settings.onlineNote,
        'minOrder': settings.minOrder,
        'deliveryFee': settings.onlineFee,
        'payments': [
          for (final m in settings.payMethods)
            {'id': m['id'], 'title': m['title'], 'kind': m['kind'], 'info': m['info'] ?? '', 'needRef': m['needRef'] == true}
        ],
        'items': [
          for (final p in products.where((p) => p.active))
            {'id': p.id, 'name': p.name, 'price': p.price, 'unit': p.unit, 'av': !p.track || p.stock > 0, 'img': (p.imagePath ?? '').isNotEmpty}
        ],
      };

  void _scheduleMenu() {
    if (!cloud.isOwner || !settings.onlineEnabled) return;
    _menuTimer?.cancel();
    _menuTimer = Timer(const Duration(seconds: 8), () => publishMenuNow());
  }

  Future<String?> _thumb(String path) async {
    try {
      Uint8List bytes;
      if (path.startsWith('data:')) {
        bytes = base64Decode(path.substring(path.indexOf(',') + 1));
      } else if (path.startsWith('http')) {
        return null;
      } else {
        bytes = await File(path).readAsBytes();
      }
      final out = await compute(_makeThumb, bytes);
      return 'data:image/jpeg;base64,${base64Encode(out)}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendImg(String id, String? path) async {
    if (path == null || path.isEmpty || _imgSig[id] == path) return;
    final t = await _thumb(path);
    if (t != null && await cloud.putMenuImg(id, t)) _imgSig[id] = path;
  }

  /// ينشر القائمة (والصور المصغّرة عند تغيّرها) للعملاء
  Future<bool> publishMenuNow({bool force = false}) async {
    if (!cloud.isOwner) return false;
    if (settings.menuKey.isNotEmpty && _keySent != settings.menuKey) {
      if (await cloud.putMenuKey(settings.menuKey)) _keySent = settings.menuKey;
    }
    final m = _menuJson();
    final h = jsonEncode(m);
    if (!force && h == _menuHash) return true;
    if (settings.onlineEnabled) {
      await _sendImg('logo', settings.logoPath);
      for (final p in products.where((p) => p.active)) {
        await _sendImg('p${p.id}', p.imagePath);
      }
    }
    final ok = await cloud.publishMenu(m);
    if (ok) {
      _menuHash = h;
      menuPublishedAt = DateTime.now();
      notifyListeners();
    }
    return ok;
  }

  Future<void> refreshWeb() async {
    final l = await cloud.fetchPendingWeb();
    if (l == null) return;
    final made = <String, Order>{for (final o in orders) if (o.webKey != null) o.webKey!: o};
    final pending = <Map<String, dynamic>>[];
    for (final w in l) {
      final o = made['${w['_key']}'];
      if (o != null) {
        _pushWebStatus(o); // طلب أُنشئ لكن لم تُحدَّث حالته في السحابة
      } else {
        pending.add(w);
      }
    }
    pending.sort((a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'));
    final fresh = pending.where((w) => !_seenWeb.contains('${w['_key']}')).toList();
    for (final w in fresh) {
      _seenWeb.add('${w['_key']}');
    }
    final changed = fresh.isNotEmpty || pending.length != webOrders.length;
    webOrders = pending;
    if (fresh.isNotEmpty) {
      toastGlobal(_webInit ? '🛒 طلب جديد من القائمة الإلكترونية (${pending.length} بانتظار القبول)' : '🛒 لديك ${pending.length} طلب وارد من القائمة الإلكترونية');
    }
    _webInit = true;
    if (changed) notifyListeners();
  }

  /// يحسب مجموع طلب وارد بالأسعار الحالية في متجرك
  ({double sub, List<String> missing}) webSubtotal(Map<String, dynamic> w) {
    var sub = 0.0;
    final missing = <String>[];
    for (final it in asMapList(w['items'])) {
      final pr = product((it['pid'] as num?)?.toInt() ?? 0);
      final q = _d(it['qty']);
      if (pr == null) {
        missing.add('${it['name'] ?? ''}');
      } else {
        sub += pr.price * q * unitFactor(pr.unit);
      }
    }
    return (sub: sub, missing: missing);
  }

  /// يحوّل الطلب الوارد إلى طلب حقيقي في النظام
  Future<({Order? order, String? error})> acceptWebOrder(Map<String, dynamic> w, {required int captainId, required double fee, required bool paidOk}) async {
    final key = '${w['_key']}';
    final cm = Map<String, dynamic>.from((w['customer'] as Map?) ?? {});
    final pm = Map<String, dynamic>.from((w['payment'] as Map?) ?? {});
    final phone = '${cm['phone'] ?? ''}';
    final wn = waNumber(phone);
    final lat = cm['lat'] is num ? (cm['lat'] as num).toDouble() : null;
    final lng = cm['lng'] is num ? (cm['lng'] as num).toDouble() : null;
    final items = <OrderItem>[];
    final missing = <String>[];
    for (final it in asMapList(w['items'])) {
      final q = _d(it['qty']);
      if (q <= 0) continue;
      final pr = product((it['pid'] as num?)?.toInt() ?? 0);
      if (pr == null) {
        missing.add('${it['name'] ?? ''}');
        continue;
      }
      if (pr.track && q > pr.stock) return (order: null, error: 'الكمية المطلوبة من ${pr.name} أكبر من المخزون (${qtyText(pr.stock)})');
      items.add(OrderItem(productId: pr.id, name: pr.name, price: pr.price, cost: pr.cost, unit: pr.unit, qty: q));
    }
    if (items.isEmpty) return (order: null, error: 'لا توجد أصناف صالحة في هذا الطلب');
    Customer? cu = wn.isEmpty ? null : customers.where((x) => waNumber(x.phone) == wn).firstOrNull;
    if (cu == null) {
      cu = Customer(id: 0, name: '${cm['name'] ?? 'عميل'}', phone: wn.isEmpty ? phone : wn, address: '${cm['address'] ?? ''}', lat: lat, lng: lng);
    } else {
      if (cu.address.isEmpty) cu.address = '${cm['address'] ?? ''}';
      if (lat != null && lng != null && !cu.hasLoc) {
        cu.lat = lat;
        cu.lng = lng;
      }
    }
    saveCustomer(cu);
    final kind = '${pm['kind'] ?? 'cod'}';
    final ref = '${pm['ref'] ?? ''}'.trim();
    final notes = [
      if ('${cm['notes'] ?? ''}'.trim().isNotEmpty) '${cm['notes']}'.trim(),
      'طلب إلكتروني — ${pm['title'] ?? ''}${ref.isEmpty ? '' : ' (مرجع: $ref)'}',
      if (missing.isNotEmpty) 'أصناف غير موجودة: ${missing.join('، ')}',
    ].join(' | ');
    final o = createOrder(
      customerId: cu.id,
      captainId: captainId,
      items: items,
      delivery: fee,
      discount: 0,
      notes: notes,
      method: (kind != 'cod' && paidOk) ? 'prepaid' : 'cod',
      paidNow: 0,
    );
    o.source = 'web';
    o.webKey = key;
    _save();
    _pushWebStatus(o);
    return (order: o, error: null);
  }

  Future<bool> rejectWebOrder(String key, String reason) async {
    final a = await cloud.setPublic(key, {'status': 'rejected'});
    if (!a) return false;
    await cloud.putTrack(key, {'status': 'rejected', 'reason': reason, 'at': DateTime.now().toIso8601String()});
    webOrders = webOrders.where((w) => '${w['_key']}' != key).toList();
    notifyListeners();
    return true;
  }

  void _pushWebStatus(Order o) {
    final k = o.webKey;
    if (k == null || !cloud.isOwner) return;
    final cap = captain(o.captainId);
    final st = switch (o.status) { 'new' => 'accepted', 'prep' => 'preparing', 'delivery' => 'delivering', 'done' => 'done', _ => 'cancelled' };
    cloud.setPublic(k, {'status': st});
    cloud.putTrack(k, {
      'status': st,
      'orderNo': o.id,
      'total': o.total,
      'delivery': o.delivery,
      'captainName': cap?.name ?? '',
      'captainPhone': st == 'delivering' ? (cap?.phone ?? '') : '',
      'at': DateTime.now().toIso8601String(),
    });
  }

  // ---- المخزون ----
  void _logMove(Product p, double delta, String type, String note) {
    stockMoves.add(StockMove(
        id: DateTime.now().microsecondsSinceEpoch + stockMoves.length,
        productId: p.id,
        delta: delta,
        balance: p.stock,
        type: type,
        note: note,
        date: DateTime.now()));
    if (stockMoves.length > 3000) stockMoves.removeRange(0, 500);
  }

  /// يغيّر مخزون صنف (إن كان يُتتبَّع) ويسجّل الحركة
  void _stock(int productId, double delta, String type, String note) {
    final p = product(productId);
    if (p == null || !p.track || delta == 0) return;
    p.stock = max(0, p.stock + delta);
    _logMove(p, delta, type, note);
  }

  // ---- الدَّين (الآجل) ----
  double customerDebt(int cid) {
    var d = 0.0;
    for (final o in orders) {
      if (o.customerId == cid && o.status != 'cancel') d += o.debt;
    }
    for (final x in customerPayments) {
      if (x.customerId == cid) d -= x.amount;
    }
    return d;
  }

  String? addCustomerPayment(int cid, double amount, String note) {
    if (amount <= 0) return 'أدخل مبلغاً صحيحاً';
    if (amount > customerDebt(cid) + 0.000001) return 'المبلغ أكبر من الدَّين المستحق';
    customerPayments.add(CustomerPayment(id: DateTime.now().millisecondsSinceEpoch, customerId: cid, amount: amount, note: note, date: DateTime.now()));
    _save();
    return null;
  }

  void saveClose(DayClose c) {
    closes.removeWhere((x) => x.day == c.day);
    closes.add(c);
    _save();
  }

  // ---- Orders ----
  /// حساب مبالغ الطلب حسب طريقة الدفع
  ({double sub, double disc, double goods, double paid, double due}) _calc(List<OrderItem> items, double discount, String method, double paidNow) {
    final sub = items.fold<double>(0, (a, i) => a + i.lineTotal);
    final disc = discount.clamp(0, sub).toDouble();
    final goods = max(0.0, sub - disc);
    double paid = goods, due = 0;
    if (method == 'cod') {
      paid = 0;
      due = goods;
    } else if (method == 'partial') {
      paid = paidNow.clamp(0, goods).toDouble();
      due = goods - paid;
    } else if (method == 'credit') {
      paid = 0;
      due = 0;
    }
    return (sub: sub, disc: disc, goods: goods, paid: paid, due: due);
  }

  Order createOrder({
    required int customerId,
    required int captainId,
    required List<OrderItem> items,
    required double delivery,
    required double discount,
    required String notes,
    required String method,
    required double paidNow,
  }) {
    final c = _calc(items, discount, method, paidNow);
    final free = method == 'prepaid' || method == 'credit';
    final o = Order(
      id: _nO++,
      date: DateTime.now(),
      customerId: customerId,
      captainId: captainId,
      items: items,
      subtotal: c.sub,
      delivery: delivery,
      discount: c.disc,
      total: c.goods + delivery,
      goodsTotal: c.goods,
      paidNow: c.paid,
      goodsDue: c.due,
      captainCredit: free ? delivery : 0,
      notes: notes,
      method: method,
    );
    for (final i in items) {
      _stock(i.productId, -i.qty, 'sale', 'طلب #${o.id}');
    }
    orders.add(o);
    _save();
    _syncOrder(o);
    return o;
  }

  /// تعديل طلب محفوظ (الأصناف، العميل، الكابتن، الدفع...)
  String? updateOrder(
    Order o, {
    required int customerId,
    required int captainId,
    required List<OrderItem> items,
    required double delivery,
    required double discount,
    required String notes,
    required String method,
    required double paidNow,
  }) {
    final oldCaptain = o.captainId;
    final live = o.status != 'cancel';
    if (live) {
      for (final i in items) {
        final p = product(i.productId);
        if (p == null || !p.track) continue;
        final back = o.items.where((x) => x.productId == i.productId).fold<double>(0, (a, x) => a + x.qty);
        final need = items.where((x) => x.productId == i.productId).fold<double>(0, (a, x) => a + x.qty);
        if (need > p.stock + back + 0.000001) return 'الكمية المطلوبة من ${p.name} أكبر من المخزون المتاح';
      }
      for (final i in o.items) {
        _stock(i.productId, i.qty, 'return', 'تعديل طلب #${o.id}');
      }
    }
    final c = _calc(items, discount, method, paidNow);
    final free = method == 'prepaid' || method == 'credit';
    o
      ..customerId = customerId
      ..captainId = captainId
      ..items = items
      ..subtotal = c.sub
      ..discount = c.disc
      ..delivery = delivery
      ..total = c.goods + delivery
      ..goodsTotal = c.goods
      ..paidNow = c.paid
      ..goodsDue = c.due
      ..captainCredit = free ? delivery : 0
      ..notes = notes
      ..method = method;
    if (live) {
      for (final i in items) {
        _stock(i.productId, -i.qty, 'sale', 'تعديل طلب #${o.id}');
      }
    }
    _save();
    if (cloud.isOwner) {
      if (oldCaptain != captainId) cloud.deleteOrder(oldCaptain, o.id);
      _syncOrder(o);
    }
    return null;
  }

  String? changeStatus(Order o, String s) {
    if (o.status == s) return null;
    if (s == 'cancel') {
      for (final i in o.items) {
        _stock(i.productId, i.qty, 'return', 'إلغاء طلب #${o.id}');
      }
    } else if (o.status == 'cancel') {
      for (final i in o.items) {
        final p = product(i.productId);
        if (p != null && p.track && i.qty > p.stock) return 'لا يمكن إعادة الطلب: المخزون غير كافٍ';
      }
      for (final i in o.items) {
        _stock(i.productId, -i.qty, 'sale', 'إعادة طلب #${o.id}');
      }
    }
    o.status = s;
    if (s == 'delivery') o.startAt ??= DateTime.now();
    if (s == 'done') o.doneAt = DateTime.now();
    _save();
    _syncOrder(o);
    return null;
  }

  void deleteOrder(int id) {
    final o = order(id);
    if (o == null) return;
    if (o.status != 'cancel') {
      for (final i in o.items) {
        _stock(i.productId, i.qty, 'return', 'حذف طلب #${o.id}');
      }
    }
    if (cloud.isOwner) cloud.deleteOrder(o.captainId, id);
    orders.removeWhere((x) => x.id == id);
    _save();
  }
}

// ====================================================================
//  نصوص الرسائل
// ====================================================================

String _itemsText(Order o) =>
    o.items.map((i) => '• ${i.name} × ${qtyText(i.qty)} ${unitShort(i.unit)} = ${money(i.lineTotal)}').join('\n');

String invoiceText(AppStore s, Order o) {
  final c = s.customer(o.customerId);
  final cap = s.captain(o.captainId);
  final full = o.method == 'prepaid';
  final pay = full
      ? 'تم الدفع بالكامل (الأصناف + التوصيل) ✅'
      : o.method == 'credit'
          ? 'آجل — يُقيَّد على حسابكم'
          : o.method == 'partial'
              ? 'مدفوع جزئياً'
              : 'الدفع عند الاستلام';
  final dueLine = o.method == 'credit'
      ? 'المطلوب عند الاستلام: لا يوجد — الطلب آجل على حسابكم (${money(o.total)})\n'
      : o.customerDue <= 0
          ? 'المطلوب عند الاستلام: لا يوجد — طلبك مدفوع بالكامل ✅\n'
          : 'المطلوب عند الاستلام (شامل التوصيل): ${money(o.customerDue)}\n';
  return 'مرحباً ${c?.name ?? ''} 🌿\n'
      'فاتورة طلبك من ${s.settings.storeName} رقم #${o.id}\n'
      '──────────────\n'
      '${_itemsText(o)}\n'
      '──────────────\n'
      'مجموع الأصناف: ${money(o.subtotal)}\n'
      'الخصم: ${money(o.discount)}\n'
      'رسوم التوصيل: ${money(o.delivery)}\n'
      'الإجمالي شامل التوصيل: ${money(o.total)}\n'
      'حالة الدفع: $pay\n'
      'المبلغ المدفوع: ${money(o.paidAmount)}\n'
      '$dueLine'
      'الكابتن: ${cap?.name ?? '-'} (${cap?.phone ?? '-'})\n'
      'العنوان: ${c?.address ?? '-'}\n'
      '${s.settings.storePhone.isEmpty ? '' : 'للتواصل: ${s.settings.storePhone}\n'}'
      'شكراً لثقتكم ❤️';
}

String captainText(AppStore s, Order o) {
  final c = s.customer(o.customerId);
  final collect = o.method == 'prepaid' || o.method == 'credit'
      ? (o.method == 'credit' ? '📒 الطلب آجل على حساب العميل\n' : '✅ الطلب مدفوع بالكامل (الأصناف + التوصيل)\n') +
          'لا تحصّل أي مبلغ من العميل.\n'
          'أجرة توصيلك: ${money(o.delivery)} (تُقيَّد لك على المحل)\n'
      : 'المطلوب تحصيله من العميل: ${money(o.customerDue)}\n'
          'المطلوب توريده للمحل: ${money(o.goodsDue)}\n'
          'أجرة توصيلك: ${money(o.delivery)} (تبقى معك من المبلغ المحصّل)\n';
  return '🏍️ تكليف توصيل من ${s.settings.storeName}\n'
      'الطلب #${o.id}\n'
      '──────────────\n'
      '${_itemsText(o)}\n'
      '──────────────\n'
      'العميل: ${c?.name ?? '-'}\n'
      'هاتف العميل: ${c?.phone ?? '-'}\n'
      'العنوان: ${c?.address ?? '-'}\n'
      '${c != null && c.hasLoc ? 'الموقع على الخريطة: ${mapLink(c.lat!, c.lng!)}\n' : ''}'
      'طريقة الدفع: ${paymentLabel(o.method)}\n'
      '$collect'
      'ملاحظات: ${o.notes.isEmpty ? 'لا توجد' : o.notes}\n'
      'نتمنى لك توصيلاً موفقاً 🙏';
}

String _statement(AppStore s, Captain c) {
  final b = s.balances(c.id);
  final ps = s.purchases.where((p) => p.captainId == c.id).toList()..sort((x, y) => x.date.compareTo(y.date));
  final lines = ps.map((p) {
    if (!p.closed) return '• ${p.title}: سُلّم ${money(p.given)} — قيد التنفيذ';
    final d = p.actual - p.given;
    final res = d > 0 ? 'لك ${money(d)}' : d < 0 ? 'عليك ${money(-d)}' : 'مطابق';
    return '• ${p.title}: سُلّم ${money(p.given)} — الفعلي ${money(p.actual)} — $res';
  }).join('\n');
  final net = b.net;
  return 'كشف حساب الكابتن ${c.name} — ${s.settings.storeName}\n'
      '──────────────\n'
      'عليك للمحل (توريد/عهدة): ${money(b.cashDue)}\n'
      'لك عند المحل (توصيل + مشتريات): ${money(b.creditDue)}\n'
      '${ps.isEmpty ? '' : 'المشتريات الخارجية:\n$lines\n'}'
      '──────────────\n'
      '${net > 0 ? 'الصافي: لك على المحل ${money(net)}' : net < 0 ? 'الصافي: عليك للمحل ${money(-net)}' : 'الحساب متساوٍ ✅'}\n'
      'شكراً لجهودك 🙏';
}

// ====================================================================
//  تسجيل الدخول
// ====================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final u = TextEditingController();
  final p = TextEditingController();
  final cu = TextEditingController();
  final cp = TextEditingController();
  bool hide = true, captain = false, busy = false;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: C.brandGradient),
        child: Stack(children: [
          Positioned(top: -80, left: -60, child: Container(width: 240, height: 240, decoration: BoxDecoration(shape: BoxShape.circle, color: C.gold.withOpacity(.08)))),
          Positioned(bottom: -90, right: -70, child: Container(width: 280, height: 280, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(.05)))),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 430),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 60, offset: Offset(0, 24))],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Avatar(s.settings.logoPath, size: 100, fallback: Icons.eco_rounded),
                  const SizedBox(height: 14),
                  Text(s.settings.storeName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: C.g)),
                  const Text('مكرونة مخلوطة .. طعم يرضيك', style: TextStyle(color: C.muted, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 18),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('صاحب المتجر'), icon: Icon(Icons.storefront_rounded)),
                      ButtonSegment(value: true, label: Text('كابتن'), icon: Icon(Icons.two_wheeler_rounded)),
                    ],
                    selected: {captain},
                    onSelectionChanged: (v) => setState(() => captain = v.first),
                  ),
                  const SizedBox(height: 16),
                  if (!captain) ...[
                    TextField(controller: u, decoration: const InputDecoration(labelText: 'اسم المستخدم', prefixIcon: Icon(Icons.person_outline))),
                    const SizedBox(height: 12),
                    TextField(
                      controller: p,
                      obscureText: hide,
                      onSubmitted: (_) => _go(s),
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => hide = !hide)),
                      ),
                    ),
                    const SizedBox(height: 18),
                    LuxButton('تسجيل الدخول', Icons.login_rounded, () => _go(s)),
                  ] else ...[
                    TextField(
                      controller: cu,
                      keyboardType: TextInputType.visiblePassword,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'اسم الدخول (إنجليزي)', prefixIcon: Icon(Icons.badge_outlined)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: cp,
                      obscureText: hide,
                      onSubmitted: (_) => _goCaptain(),
                      decoration: InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => hide = !hide)),
                      ),
                    ),
                    const SizedBox(height: 18),
                    LuxButton(busy ? 'جاري الدخول...' : 'دخول الكابتن', Icons.two_wheeler_rounded, busy ? null : _goCaptain),
                    const SizedBox(height: 12),
                    const Text('اسم الدخول وكلمة المرور يزوّدك بهما صاحب المتجر.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF9AA59F))),
                  ],
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  void _go(AppStore s) {
    if (!s.login(u.text, p.text)) toast(context, 'اسم المستخدم أو كلمة المرور غير صحيحة');
  }

  Future<void> _goCaptain() async {
    if (cu.text.trim().isEmpty || cp.text.isEmpty) return toast(context, 'أدخل اسم الدخول وكلمة المرور');
    setState(() => busy = true);
    final err = await cloud.captainLogin(cu.text, cp.text);
    if (!mounted) return;
    setState(() => busy = false);
    if (err != null) toast(context, err);
  }
}

// ====================================================================
//  الرئيسية
// ====================================================================

class DashboardPage extends StatelessWidget {
  final void Function(int) go;
  const DashboardPage({super.key, required this.go});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final now = DateTime.now();
    final today = s.orders.where((o) => o.status != 'cancel' && dayKey(o.date) == dayKey(now)).toList();
    final sales = today.fold<double>(0, (a, o) => a + o.total);
    final pending = s.orders.where((o) => o.status == 'new' || o.status == 'prep' || o.status == 'delivery').length;
    final recent = [...s.orders]..sort((a, b) => b.date.compareTo(a.date));
    final low = s.products.where((p) => p.active && p.track && p.stock <= p.lowStock).toList();
    final w = MediaQuery.of(context).size.width;

    Widget hero(String t, String v) => Expanded(
          child: Column(children: [
            FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: const TextStyle(color: Color(0xFFFFE58B), fontSize: 18, fontWeight: FontWeight.w900))),
            const SizedBox(height: 3),
            Text(t, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
        );
    Widget vline() => Container(width: 1, height: 34, color: Colors.white24);

    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: C.brandGradient,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: C.gold.withOpacity(.55)),
          boxShadow: [BoxShadow(color: C.dark.withOpacity(.3), blurRadius: 28, offset: const Offset(0, 14))],
        ),
        child: Column(children: [
          Row(children: [
            Avatar(s.settings.ownerImage, size: 54),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('أهلاً بك 👋', style: TextStyle(color: C.gold, fontSize: 12, fontWeight: FontWeight.w800)),
                Text(s.settings.ownerName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              ]),
            ),
            IconButton(
              onPressed: () => go(6),
              icon: const Icon(Icons.settings_rounded, color: Colors.white70),
            ),
          ]),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(color: Colors.white.withOpacity(.08), borderRadius: BorderRadius.circular(18)),
            child: Row(children: [
              hero('مبيعات اليوم', money(sales)),
              vline(),
              hero('طلبات اليوم', '${today.length}'),
              vline(),
              hero('قيد التنفيذ', '$pending'),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      GridView.count(
        crossAxisCount: w > 760 ? 4 : 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: w > 760 ? 2.4 : 1.7,
        children: [
          StatTile('المنتجات', '${s.products.length}', Icons.restaurant_menu_rounded, C.gold),
          StatTile('إجمالي العملاء', '${s.customers.length}', Icons.people_alt_rounded, C.blue),
          StatTile('الكباتن المتاحون', '${s.captains.where((c) => c.available).length}', Icons.two_wheeler_rounded, C.purple),
          StatTile('تنبيهات المخزون', '${low.length}', Icons.warning_amber_rounded, C.orange),
        ],
      ),
      const SizedBox(height: 18),
      PageHead('آخر الطلبات', trailing: TextButton(onPressed: () => go(1), child: const Text('عرض الكل'))),
      if (recent.isEmpty) const LuxCard(child: Empty('لا توجد طلبات بعد', icon: Icons.receipt_long_outlined)),
      for (final o in recent.take(6))
        LuxCard(
          accent: statusColor(o.status),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePage(orderId: o.id))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('#${o.id} — ${s.customer(o.customerId)?.name ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text('${s.captain(o.captainId)?.name ?? '-'} • ${dateText(o.date)}', style: const TextStyle(color: C.muted, fontSize: 11)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(o.total), style: const TextStyle(fontWeight: FontWeight.w900, color: C.g)),
              const SizedBox(height: 4),
              Badge2(statusLabel(o.status), statusColor(o.status)),
            ]),
          ]),
        ),
      const SizedBox(height: 10),
      PageHead('تنبيهات المخزون', trailing: TextButton(onPressed: () => go(2), child: const Text('إدارة الأصناف'))),
      if (low.isEmpty) const LuxCard(child: Empty('لا توجد تنبيهات مخزون حالياً ✓', icon: Icons.verified_rounded)),
      for (final p in low)
        LuxCard(
          accent: C.orange,
          child: Row(children: [
            ImgBox(p.imagePath, size: 44),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w900)),
                Text('المخزون: ${qtyText(p.stock)} ${unitShort(p.unit)} — حد التنبيه: ${qtyText(p.lowStock)}',
                    style: const TextStyle(color: C.orange, fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

// ====================================================================
//  الطلبات
// ====================================================================

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  String q = '';
  String filter = 'all';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final list = s.orders.where((o) {
      final c = s.customer(o.customerId);
      final t = q.trim().toLowerCase();
      final okQ = t.isEmpty || '${o.id}' == t || (c?.name.toLowerCase().contains(t) ?? false) || (c?.phone.contains(t) ?? false);
      return okQ && (filter == 'all' || o.status == filter);
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      TextField(
        onChanged: (v) => setState(() => q = v),
        decoration: const InputDecoration(hintText: 'بحث برقم الطلب أو العميل أو الهاتف...', prefixIcon: Icon(Icons.search)),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final f in ['all', 'new', 'prep', 'delivery', 'done', 'cancel'])
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text(f == 'all' ? 'الكل' : statusLabel(f)),
                selected: filter == f,
                selectedColor: C.g,
                showCheckmark: false,
                labelStyle: TextStyle(color: filter == f ? Colors.white : C.text, fontWeight: FontWeight.w800, fontSize: 12),
                onSelected: (_) => setState(() => filter = f),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      if (list.isEmpty) const Empty('لا توجد نتائج', icon: Icons.receipt_long_outlined),
      for (final o in list) _card(context, s, o),
    ]);
  }

  Widget _card(BuildContext context, AppStore s, Order o) {
    final c = s.customer(o.customerId);
    final cap = s.captain(o.captainId);
    return LuxCard(
      accent: statusColor(o.status),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePage(orderId: o.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('#${o.id}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: C.g)),
          const SizedBox(width: 8),
          Expanded(child: Text(c?.name ?? '-', style: const TextStyle(fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
          Text(money(o.total), style: const TextStyle(fontWeight: FontWeight.w900, color: C.g2)),
        ]),
        const SizedBox(height: 4),
        Text('${c?.phone ?? '-'} • ${cap?.name ?? '-'}', style: const TextStyle(color: C.muted, fontSize: 11)),
        Text(dateText(o.date), style: const TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 8),
        Row(children: [
          Flexible(child: Badge2(paymentLabel(o.method), o.method == 'prepaid' ? C.g2 : C.orange)),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: 'تغيير الحالة',
            onSelected: (v) {
              final err = context.read<AppStore>().changeStatus(o, v);
              toast(context, err ?? 'تم تحديث حالة الطلب');
            },
            itemBuilder: (_) => [
              for (final st in ['new', 'prep', 'delivery', 'done', 'cancel']) PopupMenuItem(value: st, child: Text(statusLabel(st))),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: statusColor(o.status).withOpacity(.12), borderRadius: BorderRadius.circular(99)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(statusLabel(o.status), style: TextStyle(color: statusColor(o.status), fontWeight: FontWeight.w900, fontSize: 12)),
                Icon(Icons.arrow_drop_down, color: statusColor(o.status), size: 18),
              ]),
            ),
          ),
        ]),
        const Divider(height: 18),
        Wrap(children: [
          _act(Icons.receipt_long_rounded, 'فاتورة', C.g, () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePage(orderId: o.id)))),
          _act(Icons.edit_rounded, 'تعديل', C.blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderFormPage(edit: o)))),
          _act(Icons.send_rounded, 'للعميل', C.wa, () => sendWa(context, c?.phone ?? '', invoiceText(s, o))),
          _act(Icons.two_wheeler_rounded, 'للكابتن', const Color(0xFFB68B24), () => sendWa(context, cap?.phone ?? '', captainText(s, o))),
          _act(Icons.delete_outline_rounded, 'حذف', C.red, () async {
            if (await confirmDialog(context, 'حذف الطلب #${o.id} نهائياً؟ سيتم إرجاع الكمية للمخزون إن لم يكن ملغياً.', yes: 'حذف')) {
              if (context.mounted) {
                context.read<AppStore>().deleteOrder(o.id);
                toast(context, 'تم حذف الطلب');
              }
            }
          }),
        ]),
      ]),
    );
  }

  Widget _act(IconData i, String t, Color c, VoidCallback f) => Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: TextButton.icon(
          onPressed: f,
          icon: Icon(i, color: c, size: 18),
          label: Text(t, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
        ),
      );
}

// ====================================================================
//  إنشاء طلب
// ====================================================================

class _Line {
  final Product p;
  double qty;
  double price;
  _Line(this.p, this.qty, [double? price]) : price = price ?? p.price;
}

class OrderFormPage extends StatefulWidget {
  final Order? edit;
  const OrderFormPage({super.key, this.edit});
  @override
  State<OrderFormPage> createState() => _OrderFormPageState();
}

class _OrderFormPageState extends State<OrderFormPage> {
  int? customerId, captainId;
  final cart = <_Line>[];
  final delivery = TextEditingController(text: '500');
  final discount = TextEditingController(text: '0');
  final notes = TextEditingController();
  final paid = TextEditingController(text: '0');
  String discType = 'fixed';
  String method = 'prepaid';
  String pq = '';
  final Map<int, double> _reserved = {};

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    if (e == null) return;
    final st = context.read<AppStore>();
    customerId = e.customerId;
    captainId = e.captainId;
    for (final i in e.items) {
      final pr = st.product(i.productId) ?? Product(id: i.productId, name: i.name, price: i.price, unit: i.unit, track: false);
      cart.add(_Line(pr, i.qty, i.price));
      if (e.status != 'cancel') _reserved[i.productId] = (_reserved[i.productId] ?? 0) + i.qty;
    }
    String t(double v) => qtyText(v).replaceAll(',', '');
    delivery.text = t(e.delivery);
    discount.text = t(e.discount);
    notes.text = e.notes;
    paid.text = t(e.paidNow);
    method = e.method;
  }

  /// الكمية المتاحة للبيع (مع إضافة ما حجزه الطلب نفسه عند التعديل)
  double _avail(Product p) => p.track ? p.stock + (_reserved[p.id] ?? 0) : double.infinity;

  double get sub => cart.fold(0, (a, l) => a + l.price * l.qty * unitFactor(l.p.unit));
  double get del => num2(delivery.text).clamp(0, double.infinity).toDouble();
  double get disc {
    final v = num2(discount.text).clamp(0, double.infinity).toDouble();
    final d = discType == 'percentage' ? sub * v / 100 : v;
    return d.clamp(0, sub).toDouble();
  }

  double get goods => (sub - disc).clamp(0, double.infinity).toDouble();
  double get total => goods + del;

  void add(Product p) {
    setState(() {
      final i = cart.indexWhere((l) => l.p.id == p.id);
      final step = p.isPiece ? 1.0 : 100.0;
      if (i >= 0) {
        cart[i].qty = (cart[i].qty + step).clamp(0, _avail(p)).toDouble();
      } else {
        cart.add(_Line(p, step.clamp(0, _avail(p)).toDouble()));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final t = pq.trim().toLowerCase();
    final products = s.products.where((p) => p.active && (t.isEmpty || p.name.toLowerCase().contains(t))).toList();
    final paidV = num2(paid.text).clamp(0, goods).toDouble();
    final note = switch (method) {
      'cod' => 'المطلوب من العميل عند التسليم: ${money(goods + del)} (الأصناف ${money(goods)} + التوصيل ${money(del)})',
      'partial' => 'المدفوع الآن: ${money(paidV)} — المتبقي عند التسليم شامل التوصيل: ${money(goods - paidV + del)}',
      'credit' => 'آجل: يُقيَّد ${money(goods + del)} دَيناً على العميل، ولا يحصّل الكابتن شيئاً، وتُقيَّد أجرة التوصيل ${money(del)} للكابتن على المحل',
      _ => 'الطلب مدفوع بالكامل شامل التوصيل (${money(goods + del)}). لا يُحصَّل شيء من العميل، وتُقيَّد أجرة التوصيل ${money(del)} للكابتن على المحل',
    };

    return Scaffold(
      appBar: AppBar(title: Text(widget.edit == null ? 'إنشاء طلب جديد' : 'تعديل الطلب #${widget.edit!.id}'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            LuxCard(
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: customerId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'العميل', prefixIcon: Icon(Icons.person_outline)),
                      items: [for (final c in s.customers) DropdownMenuItem(value: c.id, child: Text('${c.name} — ${c.phone}${c.hasLoc ? '  📍' : ''}', overflow: TextOverflow.ellipsis))],
                      onChanged: (v) => setState(() => customerId = v),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: 'عميل جديد',
                    onPressed: () => showSheet(context, (_) => _CustomerForm(onSaved: (id) {
                      if (mounted) setState(() => customerId = id);
                    })),
                    icon: const Icon(Icons.person_add_alt_1),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: captainId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'الكابتن', prefixIcon: Icon(Icons.two_wheeler_rounded)),
                      items: [
                        for (final c in s.captains.where((c) => c.available || c.id == captainId)) DropdownMenuItem(value: c.id, child: Text('${c.name} — ${c.phone}', overflow: TextOverflow.ellipsis))
                      ],
                      onChanged: (v) => setState(() => captainId = v),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: 'كابتن جديد',
                    onPressed: () => showSheet(context, (_) => _CaptainForm(onSaved: (id) {
                      if (mounted) setState(() => captainId = id);
                    })),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ]),
            ),
            const PageHead('اختر الأصناف'),
            TextField(
              onChanged: (v) => setState(() => pq = v),
              decoration: const InputDecoration(hintText: 'بحث في الأصناف...', prefixIcon: Icon(Icons.search)),
            ),
            const SizedBox(height: 10),
            if (products.isEmpty) const Empty('لا توجد أصناف متاحة'),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: products.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisExtent: 150, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemBuilder: (_, i) => _tile(products[i]),
            ),
            const SizedBox(height: 16),
            const PageHead('السلة'),
            if (cart.isEmpty) const LuxCard(child: Empty('السلة فارغة', icon: Icons.shopping_cart_outlined)),
            for (final l in cart)
              LuxCard(
                key: ValueKey(l.p.id),
                child: Row(children: [
                  ImgBox(l.p.imagePath, size: 46),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.p.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                      Text('${money(l.price)} / ${unitName(l.p.unit)}', style: const TextStyle(color: C.muted, fontSize: 10)),
                      const SizedBox(height: 2),
                      Text(money(l.price * l.qty * unitFactor(l.p.unit)), style: const TextStyle(color: C.g2, fontWeight: FontWeight.w900)),
                    ]),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => setState(() {
                      final step = l.p.isPiece ? 1.0 : 100.0;
                      l.qty = (l.qty - step);
                      if (l.qty <= 0) cart.remove(l);
                    }),
                  ),
                  SizedBox(
                    width: 58,
                    child: TextFormField(
                      key: ValueKey('q${l.p.id}${l.qty}'),
                      initialValue: qtyText(l.qty).replaceAll(',', ''),
                      textAlign: TextAlign.center,
                      keyboardType: numType,
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(vertical: 8)),
                      onFieldSubmitted: (v) => setState(() {
                        var q = num2(v);
                        if (l.p.isPiece) q = q.floorToDouble();
                        l.qty = q.clamp(0, _avail(l.p)).toDouble();
                        if (l.qty <= 0) cart.remove(l);
                      }),
                    ),
                  ),
                  IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline, color: C.g2), onPressed: () => add(l.p)),
                  IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, color: C.red), onPressed: () => setState(() => cart.remove(l))),
                ]),
              ),
            const SizedBox(height: 8),
            LuxCard(
              child: Column(children: [
                Row(children: [
                  Expanded(child: TextField(controller: delivery, keyboardType: numType, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'رسوم التوصيل (YER)'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: discType,
                      decoration: const InputDecoration(labelText: 'نوع الخصم'),
                      items: const [DropdownMenuItem(value: 'fixed', child: Text('مبلغ ثابت')), DropdownMenuItem(value: 'percentage', child: Text('نسبة %'))],
                      onChanged: (v) => setState(() => discType = v!),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: discount, keyboardType: numType, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'قيمة الخصم'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: notes, decoration: const InputDecoration(labelText: 'ملاحظات الطلب'))),
                ]),
              ]),
            ),
            LuxCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('طريقة الدفع والمحاسبة', style: TextStyle(fontWeight: FontWeight.w900, color: C.g)),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: method,
                  isExpanded: true,
                  items: [for (final m in ['prepaid', 'cod', 'partial', 'credit']) DropdownMenuItem(value: m, child: Text(paymentLabel(m)))],
                  onChanged: (v) => setState(() => method = v!),
                ),
                if (method == 'partial') ...[
                  const SizedBox(height: 10),
                  TextField(controller: paid, keyboardType: numType, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'المبلغ المدفوع مقدماً')),
                ],
                const SizedBox(height: 8),
                Text(note, style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: C.brandGradient,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: C.gold.withOpacity(.7)),
                boxShadow: [BoxShadow(color: C.dark.withOpacity(.25), blurRadius: 22, offset: const Offset(0, 10))],
              ),
              child: Column(children: [
                _sum('المجموع الفرعي', money(sub)),
                _sum('التوصيل', money(del)),
                _sum('الخصم', '- ${money(disc)}'),
                const Divider(color: Colors.white24),
                Row(children: [
                  const Text('الإجمالي النهائي', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  Text(money(total), style: const TextStyle(color: Color(0xFFFFE58B), fontSize: 22, fontWeight: FontWeight.w900)),
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            LuxButton('حفظ الطلب وفتح الفاتورة', Icons.check_circle_rounded, () => _save(context, s), colors: const [Color(0xFFB68B24), C.gold], fg: C.dark),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  Widget _tile(Product p) {
    final inCart = cart.where((l) => l.p.id == p.id).fold<double>(0, (a, l) => a + l.qty);
    final out = _avail(p) <= 0;
    return GestureDetector(
      onTap: out ? null : () => add(p),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: inCart > 0 ? C.gold : C.line, width: inCart > 0 ? 2 : 1),
          boxShadow: [BoxShadow(color: C.g.withOpacity(.08), blurRadius: 14, offset: const Offset(0, 6))],
        ),
        child: Stack(fit: StackFit.expand, children: [
          imgWidget(p.imagePath,
              fallback: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFDCEFE2), Color(0xFFF5EEC8)], begin: Alignment.topRight, end: Alignment.bottomLeft)),
                child: const Icon(Icons.restaurant_rounded, color: C.g, size: 40),
              )),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, C.dark.withOpacity(.9)], stops: const [.35, 1])),
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
              const SizedBox(height: 2),
              Text('${money(p.price)} / ${unitShort(p.unit)}', style: const TextStyle(color: Color(0xFFFFE58B), fontWeight: FontWeight.w800, fontSize: 10)),
            ]),
          ),
          if (inCart > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: C.gold, borderRadius: BorderRadius.circular(99)),
                child: Text(qtyText(inCart), style: const TextStyle(color: C.dark, fontWeight: FontWeight.w900, fontSize: 12)),
              ),
            ),
          if (out)
            Positioned.fill(
              child: Container(color: Colors.white70, alignment: Alignment.center, child: const Text('نفد المخزون', style: TextStyle(color: C.red, fontWeight: FontWeight.w900))),
            ),
        ]),
      ),
    );
  }

  Widget _sum(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [Text(a, style: const TextStyle(color: Colors.white70)), const Spacer(), Text(b, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))]),
      );

  void _save(BuildContext context, AppStore s) {
    if (cart.isEmpty) return toast(context, 'أضف صنفاً واحداً على الأقل');
    if (customerId == null || captainId == null) return toast(context, 'اختر العميل والكابتن');
    for (final l in cart) {
      if (l.qty <= 0) return toast(context, 'أدخل كمية صحيحة للصنف ${l.p.name}');
      if (l.qty > _avail(l.p)) return toast(context, 'الكمية المطلوبة من ${l.p.name} أكبر من المخزون (${qtyText(_avail(l.p))})');
      if (l.p.isPiece && l.qty != l.qty.roundToDouble()) return toast(context, 'صنف ${l.p.name} يُباع بالقطعة، أدخل رقماً صحيحاً');
    }
    final items = [for (final l in cart) OrderItem(productId: l.p.id, name: l.p.name, price: l.price, cost: l.p.cost, unit: l.p.unit, qty: l.qty)];
    final e = widget.edit;
    if (e != null) {
      final err = s.updateOrder(e,
          customerId: customerId!,
          captainId: captainId!,
          items: items,
          delivery: del,
          discount: disc,
          notes: notes.text.trim(),
          method: method,
          paidNow: num2(paid.text));
      if (err != null) return toast(context, err);
      Navigator.pop(context);
      toast(context, 'تم تعديل الطلب ✓');
      return;
    }
    final o = s.createOrder(
      customerId: customerId!,
      captainId: captainId!,
      items: items,
      delivery: del,
      discount: disc,
      notes: notes.text.trim(),
      method: method,
      paidNow: num2(paid.text),
    );
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => InvoicePage(orderId: o.id)));
  }
}

// ====================================================================
//  الفاتورة
// ====================================================================

class InvoicePage extends StatefulWidget {
  final int orderId;
  const InvoicePage({super.key, required this.orderId});
  @override
  State<InvoicePage> createState() => _InvoicePageState();
}

class _InvoicePageState extends State<InvoicePage> {
  final boundary = GlobalKey();

  Future<Uint8List> _capture() async {
    final b = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 3);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) throw Exception('no data');
    return bd.buffer.asUint8List();
  }

  /// يلتقط الفاتورة كصورة ويفتح قائمة المشاركة (واتساب وغيره)
  Future<void> _shareImage(int id, String caption) async {
    try {
      await shareBytesFile(await _capture(), 'invoice-$id.png', 'image/png', text: caption);
    } catch (_) {
      if (mounted) toast(context, 'تعذّر إنشاء صورة الفاتورة');
    }
  }

  /// فاتورة PDF (الصورة داخل صفحة A4) للمشاركة أو الطباعة
  Future<void> _sharePdf(int id) async {
    try {
      final png = await _capture();
      final doc = pw.Document();
      final image = pw.MemoryImage(png);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ));
      await shareBytesFile(Uint8List.fromList(await doc.save()), 'invoice-$id.pdf', 'application/pdf');
    } catch (_) {
      if (mounted) toast(context, 'تعذّر إنشاء ملف PDF');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final o = s.order(widget.orderId);
    if (o == null) return const Scaffold(body: Empty('الطلب غير موجود'));
    final c = s.customer(o.customerId);
    final cap = s.captain(o.captainId);

    Widget small(String t, IconData i, Color col, VoidCallback f) => TextButton.icon(
          onPressed: f,
          icon: Icon(i, size: 18, color: col),
          label: Text(t, style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 12)),
        );

    return Scaffold(
      appBar: AppBar(title: Text('فاتورة #${o.id}'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(10), children: [
            RepaintBoundary(
              key: boundary,
              child: Container(color: C.bg, padding: const EdgeInsets.all(6), child: InvoiceCard(store: s, order: o)),
            ),
            const SizedBox(height: 12),
            LuxCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const PageHead('إرسال الفاتورة'),
                LuxButton('مشاركة الفاتورة كصورة', Icons.image_rounded, () => _shareImage(o.id, 'فاتورة #${o.id} — ${s.settings.storeName}'), colors: const [C.g, C.g2]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(onPressed: () => _sharePdf(o.id), icon: const Icon(Icons.picture_as_pdf_rounded, color: C.red), label: const Text('PDF / طباعة'))),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderFormPage(edit: o))), icon: const Icon(Icons.edit_rounded), label: const Text('تعديل الطلب'))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: LuxButton('رسالة للعميل', Icons.send_rounded, () => sendWa(context, c?.phone ?? '', invoiceText(s, o)), colors: const [Color(0xFF128C4A), C.wa])),
                  const SizedBox(width: 10),
                  Expanded(child: LuxButton('رسالة للكابتن', Icons.two_wheeler_rounded, () => sendWa(context, cap?.phone ?? '', captainText(s, o)), colors: const [Color(0xFFB68B24), C.gold], fg: C.dark)),
                ]),
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.center, children: [
                  small('نسخ رسالة العميل', Icons.copy_rounded, C.g, () => copyText(context, invoiceText(s, o), 'تم نسخ رسالة العميل')),
                  small('نسخ رسالة الكابتن', Icons.copy_rounded, C.g, () => copyText(context, captainText(s, o), 'تم نسخ رسالة الكابتن')),
                  small('اتصال بالعميل', Icons.call_rounded, C.blue, () => callPhone(context, c?.phone ?? '')),
                  small('اتصال بالكابتن', Icons.call_rounded, C.purple, () => callPhone(context, cap?.phone ?? '')),
                ]),
              ]),
            ),
            LuxCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const PageHead('حالة الطلب'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final st in ['new', 'prep', 'delivery', 'done', 'cancel'])
                    ChoiceChip(
                      label: Text(statusLabel(st)),
                      selected: o.status == st,
                      selectedColor: statusColor(st),
                      showCheckmark: false,
                      labelStyle: TextStyle(color: o.status == st ? Colors.white : C.text, fontWeight: FontWeight.w800, fontSize: 12),
                      onSelected: (_) {
                        final err = context.read<AppStore>().changeStatus(o, st);
                        toast(context, err ?? 'تم تحديث الحالة');
                      },
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 30),
          ]),
        ),
      ),
    );
  }
}

class InvoiceCard extends StatelessWidget {
  final AppStore store;
  final Order order;
  const InvoiceCard({super.key, required this.store, required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order;
    final s = store.settings;
    final c = store.customer(o.customerId);
    final cap = store.captain(o.captainId);
    final due = o.customerDue;

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 520;
      final fs = narrow ? 12.0 : 11.0;

      Widget info(String t, List<List<String>> rows) => TopBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
              const SizedBox(height: 6),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${r[0]}: ', style: TextStyle(color: C.muted, fontSize: fs - 1)),
                    TextSpan(text: r[1], style: TextStyle(fontWeight: FontWeight.w800, fontSize: fs)),
                  ])),
                ),
            ]),
          );

      Widget sumRow(String a, String b) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Flexible(child: Text(a, style: TextStyle(fontSize: fs))),
              const Spacer(),
              const SizedBox(width: 6),
              Text(b, style: TextStyle(fontWeight: FontWeight.w800, fontSize: fs)),
            ]),
          );

      Widget payBox() => TopBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('تفاصيل السداد', style: TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
              const SizedBox(height: 4),
              sumRow('حالة الدفع', o.method == 'prepaid' ? 'تم الدفع بالكامل' : o.method == 'credit' ? 'آجل (دَين على العميل)' : o.method == 'partial' ? 'مدفوع جزئياً' : 'الدفع عند الاستلام'),
              sumRow('المبلغ المدفوع', money(o.paidAmount)),
              sumRow('المطلوب عند الاستلام', money(due)),
            ]),
          );

      Widget sumBox() => TopBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('ملخص الفاتورة', style: TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
              const SizedBox(height: 4),
              sumRow('مجموع الأصناف', money(o.subtotal)),
              sumRow('الخصم', money(o.discount)),
              sumRow('رسوم التوصيل', money(o.delivery)),
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(gradient: const LinearGradient(colors: [C.dark, Color(0xFF28634A)]), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.gold)),
                child: Row(children: [
                  const Text('الإجمالي', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
                  const Spacer(),
                  Text(money(o.total), style: const TextStyle(color: Color(0xFFFFE58B), fontWeight: FontWeight.w900, fontSize: 15)),
                ]),
              ),
            ]),
          );

      Widget twoOrOne(Widget a, Widget b) => narrow
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 10), b])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]);

      Widget metaItem(String l, String v) => Text.rich(
            TextSpan(children: [TextSpan(text: '$l: '), TextSpan(text: v, style: const TextStyle(color: Color(0xFFF1D56F), fontWeight: FontWeight.w900))]),
            style: const TextStyle(color: Colors.white, fontSize: 11),
          );

      // الأصناف
      Widget itemsView() {
        if (narrow) {
          return Container(
            decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(14)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  color: C.g,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: const Row(children: [
                    Text('الأصناف', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
                    Spacer(),
                    Text('الإجمالي', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
                  ]),
                ),
                Container(height: 2, color: C.gold),
                for (var i = 0; i < o.items.length; i++)
                  Container(
                    color: i.isOdd ? const Color(0xFFFBFCFB) : Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(o.items[i].name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text('${qtyText(o.items[i].qty)} ${unitShort(o.items[i].unit)} × ${money(o.items[i].price)}', style: const TextStyle(color: C.muted, fontSize: 11)),
                        ]),
                      ),
                      Text(money(o.items[i].lineTotal), style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
                    ]),
                  ),
              ]),
            ),
          );
        }
        Widget cell(String t, {bool head = false, bool bold = false}) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
              child: Text(t, style: TextStyle(fontSize: 11, color: head ? Colors.white : C.text, fontWeight: (head || bold) ? FontWeight.w900 : FontWeight.w500)),
            );
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Table(
            columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2), 2: FlexColumnWidth(1.4), 3: FlexColumnWidth(1.4), 4: FlexColumnWidth(2)},
            children: [
              TableRow(
                decoration: const BoxDecoration(color: C.g, border: Border(bottom: BorderSide(color: C.gold, width: 2))),
                children: [for (final h in ['الصنف', 'السعر', 'الكمية', 'الوحدة', 'الإجمالي']) cell(h, head: true)],
              ),
              for (var i = 0; i < o.items.length; i++)
                TableRow(
                  decoration: BoxDecoration(color: i.isOdd ? const Color(0xFFFBFCFB) : Colors.white, border: const Border(bottom: BorderSide(color: Color(0xFFEDF1EE)))),
                  children: [
                    cell(o.items[i].name, bold: true),
                    cell(money(o.items[i].price)),
                    cell(qtyText(o.items[i].qty)),
                    cell(unitShort(o.items[i].unit)),
                    cell(money(o.items[i].lineTotal), bold: true),
                  ],
                ),
            ],
          ),
        );
      }

      final headerBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [C.dark, Color(0xFF246148)]), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.gold)),
        child: const Text('فاتورة بيع', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
      );

      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFD8E4DC)),
          boxShadow: [BoxShadow(color: C.dark.withOpacity(.14), blurRadius: 30, offset: const Offset(0, 12))],
        ),
        child: Stack(children: [
          Positioned.fill(
            child: Center(child: Opacity(opacity: .05, child: ImgBox(s.logoPath, size: 240, fallback: Icons.eco_rounded))),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(height: 10, decoration: const BoxDecoration(gradient: C.goldGradient)),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFF1F8F3), Colors.white, Color(0xFFFBF7E9)])),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Avatar(s.logoPath, size: narrow ? 52 : 58, fallback: Icons.eco_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.storeName, style: TextStyle(fontSize: narrow ? 20 : 22, fontWeight: FontWeight.w900, color: C.g)),
                      if (s.storeAddress.isNotEmpty) Text(s.storeAddress, style: const TextStyle(fontSize: 10, color: C.muted)),
                      if (s.storePhone.isNotEmpty) Text(s.storePhone, style: const TextStyle(fontSize: 10, color: C.muted)),
                    ]),
                  ),
                  if (!narrow) headerBadge,
                ]),
                if (narrow) ...[const SizedBox(height: 10), Align(alignment: AlignmentDirectional.centerStart, child: headerBadge)],
              ]),
            ),
            Container(
              color: C.dark,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Wrap(spacing: 18, runSpacing: 4, children: [
                metaItem('رقم الفاتورة', '#${o.id}'),
                metaItem('التاريخ', dateText(o.date)),
                metaItem('الحالة', statusLabel(o.status)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: twoOrOne(
                info('بيانات العميل', [['الاسم', c?.name ?? '-'], ['الهاتف', c?.phone ?? '-'], ['العنوان', c?.address ?? '-']]),
                info('بيانات التوصيل', [['الكابتن', cap?.name ?? '-'], ['الهاتف', cap?.phone ?? '-'], ['الدفع', paymentLabel(o.method)]]),
              ),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: itemsView()),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: TopBox(
                padding: const EdgeInsets.all(14),
                gradient: const LinearGradient(colors: [Color(0xFFF4F9EF), Colors.white, Color(0xFFF9F6E9)]),
                borderColor: const Color(0xFFD9E5C7),
                child: Column(children: [
                  Text(due == 0 ? (o.method == 'credit' ? 'طلب آجل — يُقيَّد على حساب العميل' : 'الطلب مدفوع بالكامل — لا يوجد مبلغ مطلوب') : 'المبلغ المتبقي عند الاستلام', style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
                  const SizedBox(height: 4),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(money(due), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Color(0xFF174B38)))),
                  Text(due == 0 ? (o.method == 'credit' ? 'لا يحصّل الكابتن أي مبلغ' : 'شامل قيمة الأصناف ورسوم التوصيل') : 'يشمل المبلغ المتبقي رسوم التوصيل',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: C.muted)),
                ]),
              ),
            ),
            Padding(padding: const EdgeInsets.all(14), child: twoOrOne(payBox(), sumBox())),
            if (o.notes.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFFFFAF0), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFEFE2B5))),
                child: Text('ملاحظات الطلب: ${o.notes}', style: TextStyle(fontSize: fs)),
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(color: Color(0xFFF4F9F5), border: Border(top: BorderSide(color: Color(0xFFDCE7DF)))),
              child: Column(children: [
                Text('شكراً لثقتكم واختياركم ${s.storeName} ♥', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
                const Text('نسعد بخدمتكم دائماً', style: TextStyle(color: C.muted, fontSize: 11)),
                if (s.storePhone.isNotEmpty) Text('للتواصل: ${s.storePhone}', style: const TextStyle(color: C.muted, fontSize: 11)),
              ]),
            ),
          ]),
        ]),
      );
    });
  }
}

// ====================================================================
//  الأصناف والمخزون
// ====================================================================

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final t = q.trim().toLowerCase();
    final list = s.products.where((p) => t.isEmpty || p.name.toLowerCase().contains(t)).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      Row(children: [
        Expanded(
          child: TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(hintText: 'بحث في الأصناف...', prefixIcon: Icon(Icons.search)),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: () => showSheet(context, (_) => const _ProductForm()),
          icon: const Icon(Icons.add),
          label: const Text('صنف'),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: 'جرد المخزون',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StocktakePage())),
          icon: const Icon(Icons.fact_check_rounded),
        ),
      ]),
      const SizedBox(height: 14),
      if (list.isEmpty) const Empty('لا توجد أصناف', icon: Icons.restaurant_menu),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: list.length,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 250, mainAxisExtent: 300, crossAxisSpacing: 12, mainAxisSpacing: 12),
        itemBuilder: (_, i) => _card(context, list[i]),
      ),
    ]);
  }

  Widget _card(BuildContext context, Product p) {
    final low = p.track && p.stock <= p.lowStock;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.line),
        boxShadow: [BoxShadow(color: C.g.withOpacity(.08), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 128,
          child: Stack(fit: StackFit.expand, children: [
            imgWidget(p.imagePath,
                fallback: Container(
                  decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFDCEFE2), Color(0xFFF5EEC8)], begin: Alignment.topRight, end: Alignment.bottomLeft)),
                  child: const Icon(Icons.restaurant_rounded, color: C.g, size: 44),
                )),
            Positioned(top: 8, right: 8, child: Badge2(p.active ? 'متاح' : 'مخفي', p.active ? C.blue : C.muted, solid: true)),
            if (!p.active) Positioned.fill(child: Container(color: Colors.white.withOpacity(.55))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
            const SizedBox(height: 4),
            Text('${money(p.price)} / ${unitShort(p.unit).isEmpty ? 'وحدة' : unitShort(p.unit)}', style: const TextStyle(color: C.g2, fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 6),
            Badge2(p.track ? 'المخزون: ${qtyText(p.stock)}' : 'بدون تتبّع', p.track ? (low ? C.orange : C.g2) : C.muted),
          ]),
        ),
        const Spacer(),
        const Divider(height: 1),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(tooltip: 'المخزون', visualDensity: VisualDensity.compact, onPressed: () => _adjust(context, p), icon: const Icon(Icons.inventory_2_outlined, size: 20, color: C.g)),
          IconButton(tooltip: 'سجل الحركة', visualDensity: VisualDensity.compact, onPressed: () => showSheet(context, (_) => StockLogSheet(product: p)), icon: const Icon(Icons.history_rounded, size: 20, color: C.purple)),
          IconButton(tooltip: 'تعديل', visualDensity: VisualDensity.compact, onPressed: () => showSheet(context, (_) => _ProductForm(product: p)), icon: const Icon(Icons.edit_outlined, size: 20, color: C.blue)),
          IconButton(
            tooltip: 'حذف',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 20, color: C.red),
            onPressed: () async {
              if (await confirmDialog(context, 'حذف الصنف "${p.name}"؟', yes: 'حذف')) {
                if (context.mounted) {
                  context.read<AppStore>().deleteProduct(p.id);
                  toast(context, 'تم حذف الصنف');
                }
              }
            },
          ),
        ]),
      ]),
    );
  }

  Future<void> _adjust(BuildContext context, Product p) async {
    final c = TextEditingController();
    String action = 'add';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text('مخزون: ${p.name}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('الحالي: ${qtyText(p.stock)} ${unitShort(p.unit)}', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'add', label: Text('إضافة')),
                ButtonSegment(value: 'subtract', label: Text('خصم')),
                ButtonSegment(value: 'set', label: Text('تحديد')),
              ],
              selected: {action},
              onSelectionChanged: (v) => set(() => action = v.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: c, keyboardType: numType, autofocus: true, decoration: const InputDecoration(labelText: 'الكمية')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final err = context.read<AppStore>().adjustStock(p.id, action, num2(c.text));
                if (err != null) {
                  toast(context, err);
                } else {
                  Navigator.pop(ctx);
                  toast(context, 'تم تحديث المخزون');
                }
              },
              child: const Text('تطبيق'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductForm extends StatefulWidget {
  final Product? product;
  const _ProductForm({this.product});
  @override
  State<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<_ProductForm> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.product?.name ?? '');
  late final price = TextEditingController(text: widget.product == null ? '' : '${widget.product!.price}');
  late final stock = TextEditingController(text: widget.product == null ? '0' : '${widget.product!.stock}');
  late final low = TextEditingController(text: widget.product == null ? '10' : '${widget.product!.lowStock}');
  late String unit = widget.product?.unit ?? 'piece';
  late bool active = widget.product?.active ?? true;
  late bool track = widget.product?.track ?? true;
  String? image;

  @override
  void initState() {
    super.initState();
    image = widget.product?.imagePath;
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.product != null;
    return Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(edit ? 'تعديل الصنف' : 'إضافة صنف', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
        const SizedBox(height: 14),
        ImagePickField(
          value: image,
          label: 'صورة الصنف',
          fallback: Icons.restaurant_rounded,
          onChanged: (v) {
            if (mounted) setState(() => image = v);
          },
        ),
        inp('اسم الصنف', name, required: true),
        inp('السعر (YER)', price, type: numType, required: true),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            value: unit,
            decoration: const InputDecoration(labelText: 'وحدة البيع'),
            items: [for (final u in ['piece', 'g100', 'ml100']) DropdownMenuItem(value: u, child: Text(unitName(u)))],
            onChanged: (v) => setState(() => unit = v!),
          ),
        ),
        Row(children: [
          Expanded(child: inp('المخزون', stock, type: numType)),
          const SizedBox(width: 10),
          Expanded(child: inp('حد التنبيه', low, type: numType)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeColor: C.g2,
          title: const Text('متاح للبيع', style: TextStyle(fontWeight: FontWeight.w800)),
          value: active,
          onChanged: (v) => setState(() => active = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeColor: C.g2,
          title: const Text('تتبّع المخزون', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('أوقفه للأصناف التي لا تُجرد (مثل المشروبات المحضّرة)', style: TextStyle(fontSize: 11)),
          value: track,
          onChanged: (v) => setState(() => track = v),
        ),
        const SizedBox(height: 6),
        LuxButton('حفظ', Icons.save_rounded, () {
          if (!form.currentState!.validate()) return;
          final st = context.read<AppStore>();
          final p = widget.product ?? Product(id: 0, name: '', price: 0);
          p.name = name.text.trim();
          p.price = num2(price.text);
          p.unit = unit;
          p.stock = num2(stock.text);
          p.lowStock = num2(low.text);
          p.active = active;
          p.track = track;
          p.imagePath = image;
          st.saveProduct(p);
          Navigator.pop(context);
          toast(context, edit ? 'تم حفظ التعديلات' : 'تمت إضافة الصنف');
        }),
      ]),
    );
  }
}

// ====================================================================
//  العملاء
// ====================================================================

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key});
  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final t = q.trim().toLowerCase();
    final list = s.customers.where((c) => t.isEmpty || c.name.toLowerCase().contains(t) || c.phone.contains(t)).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      Row(children: [
        Expanded(
          child: TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف...', prefixIcon: Icon(Icons.search)),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: () => showSheet(context, (_) => const _CustomerForm()),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('عميل'),
        ),
      ]),
      const SizedBox(height: 14),
      if (list.isEmpty) const Empty('لا يوجد عملاء', icon: Icons.people_outline),
      for (final c in list) _card(context, s, c),
    ]);
  }

  Widget _card(BuildContext context, AppStore s, Customer c) {
    final count = s.orders.where((o) => o.customerId == c.id).length;
    return LuxCard(
      accent: C.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            backgroundColor: C.g.withOpacity(.1),
            child: Text(c.name.isEmpty ? '?' : c.name.characters.first, style: const TextStyle(color: C.g, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(c.phone, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          Badge2('$count طلب', C.g2),
          if (c.hasLoc) ...[const SizedBox(width: 6), Badge2('📍 موقع', C.blue)],
          if (s.customerDebt(c.id) > 0) ...[const SizedBox(width: 6), Badge2('عليه ${money(s.customerDebt(c.id))}', C.red)],
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.location_on_outlined, size: 16, color: C.muted),
          const SizedBox(width: 4),
          Expanded(child: Text(c.address.isEmpty ? '-' : c.address, style: const TextStyle(fontSize: 12))),
        ]),
        if (c.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('ملاحظات: ${c.notes}', style: const TextStyle(color: C.muted, fontSize: 12)),
          ),
        const Divider(height: 18),
        Wrap(children: [
          TextButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerPage(customerId: c.id))),
            icon: const Icon(Icons.history_rounded, size: 18),
            label: const Text('السجل والحساب'),
          ),
          if (c.hasLoc)
            TextButton.icon(
              onPressed: () => openNavigation(context, lat: c.lat, lng: c.lng, address: c.address),
              icon: const Icon(Icons.navigation_rounded, size: 18, color: C.blue),
              label: const Text('الموقع', style: TextStyle(color: C.blue)),
            ),
          TextButton.icon(
            onPressed: () => sendWa(context, c.phone, 'مرحباً ${c.name} 🌿 من ${s.settings.storeName}'),
            icon: const Icon(Icons.chat_rounded, size: 18, color: C.wa),
            label: const Text('واتساب', style: TextStyle(color: C.wa)),
          ),
          TextButton.icon(
            onPressed: () => callPhone(context, c.phone),
            icon: const Icon(Icons.call_rounded, size: 18, color: C.blue),
            label: const Text('اتصال', style: TextStyle(color: C.blue)),
          ),
          TextButton.icon(
            onPressed: () => showSheet(context, (_) => _CustomerForm(customer: c)),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('تعديل'),
          ),
          TextButton.icon(
            onPressed: () async {
              if (await confirmDialog(context, 'حذف العميل "${c.name}"؟', yes: 'حذف')) {
                if (context.mounted) {
                  final err = context.read<AppStore>().deleteCustomer(c.id);
                  toast(context, err ?? 'تم حذف العميل');
                }
              }
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: C.red),
            label: const Text('حذف', style: TextStyle(color: C.red)),
          ),
        ]),
      ]),
    );
  }
}

class _CustomerForm extends StatefulWidget {
  final Customer? customer;
  final void Function(int id)? onSaved;
  const _CustomerForm({this.customer, this.onSaved});
  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.customer?.name ?? '');
  late final phone = TextEditingController(text: widget.customer?.phone ?? '');
  late final address = TextEditingController(text: widget.customer?.address ?? '');
  late final notes = TextEditingController(text: widget.customer?.notes ?? '');
  final locCtrl = TextEditingController();
  late double? lat = widget.customer?.lat;
  late double? lng = widget.customer?.lng;
  bool busy = false;

  Future<void> _resolve() async {
    if (locCtrl.text.trim().isEmpty) return;
    setState(() => busy = true);
    final r = await resolveLocation(locCtrl.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r != null) {
        lat = r.lat;
        lng = r.lng;
      }
    });
    toast(context, r == null ? 'تعذّر استخراج الموقع. استخدم رابط "مشاركة الموقع" الكامل أو الصق الإحداثيات' : 'تم تحديد الموقع ✓');
  }

  Future<void> _here() async {
    setState(() => busy = true);
    final r = await getMyLocation(context);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r != null) {
        lat = r.lat;
        lng = r.lng;
      }
    });
    if (r != null) toast(context, 'تم أخذ موقع هذا الجهاز ✓');
  }

  Widget _locBox() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFFBFDFB), borderRadius: BorderRadius.circular(18), border: Border.all(color: C.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.location_on_rounded, color: lat == null ? C.muted : C.g2),
            const SizedBox(width: 8),
            Expanded(
              child: Text(lat == null ? 'لم يُحدَّد موقع على الخريطة' : 'تم تحديد الموقع ✓  ${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: lat == null ? C.muted : C.g2)),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: locCtrl,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'الصق رابط الموقع أو الإحداثيات',
              hintText: 'https://maps.app.goo.gl/... أو 15.3547, 44.2067',
              suffixIcon: busy
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(icon: const Icon(Icons.check_circle_rounded, color: C.g2), onPressed: _resolve),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              onPressed: busy ? null : _here,
              icon: const Icon(Icons.my_location_rounded, size: 18),
              label: const Text('موقع هذا الجهاز', style: TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              onPressed: () => openNavigation(context, address: address.text),
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('بحث بالعنوان', style: TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              onPressed: () => sendWa(context, phone.text, 'مرحباً ${name.text.trim()} 🌿\nلتسهيل وصول الكابتن إليك، أرسل لنا موقعك من واتساب: اضغط 📎 ثم "الموقع" ثم "إرسال موقعك الحالي". شكراً لك.'),
              icon: const Icon(Icons.chat_rounded, size: 18, color: C.wa),
              label: const Text('اطلب الموقع من العميل', style: TextStyle(fontSize: 12)),
            ),
            if (lat != null)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                onPressed: () => openNavigation(context, lat: lat, lng: lng),
                icon: const Icon(Icons.navigation_rounded, size: 18, color: C.blue),
                label: const Text('فتح', style: TextStyle(fontSize: 12)),
              ),
            if (lat != null)
              TextButton(
                onPressed: () => setState(() {
                  lat = null;
                  lng = null;
                }),
                child: const Text('مسح الموقع', style: TextStyle(color: C.red, fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 6),
          const Text('الأسهل: اطلب من العميل إرسال موقعه في واتساب، ثم اضغط مطولاً على الرسالة ← نسخ، والصق الرابط هنا.',
              style: TextStyle(color: C.muted, fontSize: 11, height: 1.5)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final edit = widget.customer != null;
    return Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(edit ? 'تعديل العميل' : 'إضافة عميل', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
        const SizedBox(height: 14),
        inp('الاسم', name, required: true),
        inp('رقم الهاتف (مع رمز الدولة)', phone, type: TextInputType.phone, required: true, hint: '9677xxxxxxxx'),
        inp('العنوان', address, lines: 2),
        _locBox(),
        inp('ملاحظات', notes, lines: 2),
        LuxButton('حفظ', Icons.save_rounded, () async {
          if (!form.currentState!.validate()) return;
          if (locCtrl.text.trim().isNotEmpty && lat == null) await _resolve();
          if (!mounted) return;
          final wn = waNumber(phone.text);
          if (wn.isEmpty) return toast(context, 'رقم الهاتف غير صالح');
          final dup = context.read<AppStore>().customers.where((x) => x.id != (widget.customer?.id ?? 0) && waNumber(x.phone) == wn).toList();
          if (dup.isNotEmpty) return toast(context, 'الرقم مسجّل لعميل آخر: ${dup.first.name}');
          final c = widget.customer ?? Customer(id: 0, name: '', phone: '', address: '');
          c.name = name.text.trim();
          c.phone = phone.text.trim();
          c.address = address.text.trim();
          c.notes = notes.text.trim();
          c.lat = lat;
          c.lng = lng;
          context.read<AppStore>().saveCustomer(c);
          widget.onSaved?.call(c.id);
          Navigator.pop(context);
          toast(context, edit ? 'تم حفظ التعديلات' : 'تمت إضافة العميل');
        }),
      ]),
    );
  }
}

// ====================================================================
//  الكباتن
// ====================================================================

class CaptainsPage extends StatelessWidget {
  const CaptainsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      PageHead('الكباتن',
          trailing: FilledButton.icon(
            onPressed: () => showSheet(context, (_) => const _CaptainForm()),
            icon: const Icon(Icons.add),
            label: const Text('كابتن'),
          )),
      if (s.captains.isEmpty) const Empty('لا يوجد كباتن', icon: Icons.two_wheeler_rounded),
      for (final c in s.captains) _card(context, s, c),
    ]);
  }

  Widget _card(BuildContext context, AppStore s, Captain c) {
    final b = s.balances(c.id);
    final n = s.orders.where((o) => o.captainId == c.id && o.status != 'cancel').length;
    return LuxCard(
      accent: c.available ? C.g2 : C.muted,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(backgroundColor: C.purple.withOpacity(.12), child: const Icon(Icons.two_wheeler_rounded, color: C.purple)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(c.phone, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          Switch(value: c.available, activeColor: C.g2, onChanged: (_) => context.read<AppStore>().toggleCaptain(c.id)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _box('عليه للمحل', money(b.cashDue), b.cashDue > 0 ? C.red : C.g2)),
          const SizedBox(width: 6),
          Expanded(child: _box('له عند المحل', money(b.creditDue), b.creditDue > 0 ? C.purple : C.g2)),
          const SizedBox(width: 6),
          Expanded(child: _box('الطلبات', '$n', C.blue)),
        ]),
        const Divider(height: 18),
        Wrap(children: [
          TextButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CaptainLedgerPage(captainId: c.id))),
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
            label: const Text('كشف الحساب'),
          ),
          TextButton.icon(
            onPressed: () => showSheet(context, (_) => _CaptainAccountSheet(captain: c)),
            icon: Icon(c.login == null ? Icons.phone_android_rounded : Icons.verified_user_rounded, size: 18, color: c.login == null ? C.muted : C.g2),
            label: Text(c.login == null ? 'حساب التطبيق' : 'حساب التطبيق ✓'),
          ),
          TextButton.icon(
            onPressed: () => sendWa(context, c.phone, _statement(s, c)),
            icon: const Icon(Icons.chat_rounded, size: 18, color: C.wa),
            label: const Text('واتساب', style: TextStyle(color: C.wa)),
          ),
          TextButton.icon(
            onPressed: () => callPhone(context, c.phone),
            icon: const Icon(Icons.call_rounded, size: 18, color: C.blue),
            label: const Text('اتصال', style: TextStyle(color: C.blue)),
          ),
          TextButton.icon(
            onPressed: () => showSheet(context, (_) => _CaptainForm(captain: c)),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('تعديل'),
          ),
          TextButton.icon(
            onPressed: () async {
              if (await confirmDialog(context, 'حذف الكابتن "${c.name}"؟', yes: 'حذف')) {
                if (context.mounted) {
                  final err = context.read<AppStore>().deleteCaptain(c.id);
                  toast(context, err ?? 'تم حذف الكابتن');
                }
              }
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: C.red),
            label: const Text('حذف', style: TextStyle(color: C.red)),
          ),
        ]),
      ]),
    );
  }

  Widget _box(String t, String v, Color col) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: col.withOpacity(.08), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: const TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: TextStyle(color: col, fontWeight: FontWeight.w900, fontSize: 16))),
        ]),
      );
}

class CaptainLedgerPage extends StatelessWidget {
  final int captainId;
  const CaptainLedgerPage({super.key, required this.captainId});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final c = s.captain(captainId);
    if (c == null) return const Scaffold(body: Empty('الكابتن غير موجود'));
    final b = s.balances(captainId);
    final orders = s.orders.where((o) => o.captainId == captainId && o.status != 'cancel' && o.goodsDue > 0).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final creditOrders = s.orders.where((o) => o.captainId == captainId && o.status != 'cancel' && o.captainCredit > 0).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final sets = s.settlements.where((x) => x.captainId == captainId).toList()..sort((a, b) => b.date.compareTo(a.date));
    final purchases = s.purchases.where((x) => x.captainId == captainId).toList()..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: Text('حساب ${c.name}'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: C.brandGradient, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.gold.withOpacity(.7))),
              child: Column(children: [
                const Text('المطلوب توريده للمحل', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                Text(money(b.cashDue), style: const TextStyle(color: Color(0xFFFFE58B), fontSize: 28, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: C.gold, foregroundColor: C.dark),
                  onPressed: b.cashDue <= 0 ? null : () => _settle(context, c, b.cashDue),
                  icon: const Icon(Icons.payments_rounded),
                  label: const Text('تسجيل توريد من الكابتن'),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: C.purple.withOpacity(.45), width: 1.5),
                boxShadow: [BoxShadow(color: C.purple.withOpacity(.08), blurRadius: 18, offset: const Offset(0, 8))],
              ),
              child: Column(children: [
                const Text('مستحق للكابتن عند المحل (أجرة توصيل + مشتريات خارجية)', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontWeight: FontWeight.w800, fontSize: 12)),
                const SizedBox(height: 4),
                Text(money(b.creditDue), style: const TextStyle(color: C.purple, fontSize: 26, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: C.purple, foregroundColor: Colors.white),
                  onPressed: b.creditDue <= 0 ? null : () => _settle(context, c, b.creditDue, type: 'owner_paid'),
                  icon: const Icon(Icons.payments_rounded),
                  label: const Text('تسجيل دفع للكابتن'),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (b.net > 0 ? C.purple : b.net < 0 ? C.red : C.g2).withOpacity(.09),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(children: [
                Icon(b.net == 0 ? Icons.verified_rounded : Icons.balance_rounded, color: b.net > 0 ? C.purple : b.net < 0 ? C.red : C.g2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    b.net > 0 ? 'الصافي: للكابتن على المحل ${money(b.net)}' : b.net < 0 ? 'الصافي: على الكابتن للمحل ${money(-b.net)}' : 'الحساب متساوٍ ✅',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => sendWa(context, c.phone, _statement(s, c)),
              icon: const Icon(Icons.chat_rounded, color: C.wa),
              label: const Text('إرسال كشف الحساب للكابتن (واتساب)'),
            ),
            const SizedBox(height: 16),
            PageHead('مشتريات خارجية',
                trailing: FilledButton.icon(
                  onPressed: () => showSheet(context, (_) => _PurchaseForm(captainId: captainId)),
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة'),
                )),
            if (purchases.isEmpty) const Empty('لا توجد مشتريات خارجية', icon: Icons.shopping_bag_outlined),
            for (final pr in purchases) _purchaseCard(context, pr),
            const SizedBox(height: 8),
            const PageHead('أجرة توصيل مستحقة للكابتن'),
            if (creditOrders.isEmpty) const Empty('لا توجد أجور توصيل مقيّدة', icon: Icons.verified_rounded),
            for (final o in creditOrders)
              LuxCard(
                accent: C.purple,
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('#${o.id} — ${s.customer(o.customerId)?.name ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text('${dateText(o.date)} • طلب مدفوع بالكامل', style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  Text(money(o.captainCredit), style: const TextStyle(color: C.purple, fontWeight: FontWeight.w900)),
                ]),
              ),
            const SizedBox(height: 8),
            const PageHead('طلبات عليها مبالغ للمحل'),
            if (orders.isEmpty) const Empty('لا توجد مبالغ مستحقة', icon: Icons.verified_rounded),
            for (final o in orders)
              LuxCard(
                accent: statusColor(o.status),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('#${o.id} — ${s.customer(o.customerId)?.name ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text(dateText(o.date), style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  Text(money(o.goodsDue), style: const TextStyle(color: C.red, fontWeight: FontWeight.w900)),
                ]),
              ),
            const SizedBox(height: 8),
            const PageHead('التسويات'),
            if (sets.isEmpty) const Empty('لا توجد تسويات', icon: Icons.history),
            for (final x in sets)
              LuxCard(
                accent: C.g2,
                child: Row(children: [
                  const Icon(Icons.check_circle, color: C.g2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(x.type == 'captain_paid' ? 'سدّد الكابتن للمحل' : 'دفع المحل للكابتن', style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text('${dateText(x.date)}${x.note.isEmpty ? '' : ' • ${x.note}'}', style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  Text(money(x.amount), style: const TextStyle(color: C.g2, fontWeight: FontWeight.w900)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
      ]);

  Widget _purchaseCard(BuildContext context, Purchase p) {
    final extra = p.actual - p.given;
    final Color col = !p.closed ? C.orange : extra > 0 ? C.purple : extra < 0 ? C.red : C.g2;
    final String result = !p.closed
        ? 'قيد التنفيذ — المبلغ المسلَّم عهدة على الكابتن حتى تسجَّل التكلفة الفعلية'
        : extra > 0
            ? 'زيادة دفعها الكابتن من جيبه — تُردّ له: ${money(extra)}'
            : extra < 0
                ? 'متبقٍّ يعيده الكابتن للمحل: ${money(-extra)}'
                : 'المبلغ مطابق، لا فرق';
    return LuxCard(
      accent: col,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15))),
          Badge2(p.closed ? 'مغلق' : 'قيد التنفيذ', col),
        ]),
        const SizedBox(height: 2),
        Text(dateText(p.date), style: const TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _kv('سُلّم للكابتن', money(p.given))),
          Expanded(child: _kv('التكلفة الفعلية', p.closed ? money(p.actual) : '—')),
        ]),
        const SizedBox(height: 8),
        Text(result, style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 12)),
        if (p.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('ملاحظات: ${p.note}', style: const TextStyle(color: C.muted, fontSize: 11))),
        const Divider(height: 18),
        Wrap(children: [
          TextButton.icon(
            onPressed: () => showSheet(context, (_) => _PurchaseForm(captainId: p.captainId, purchase: p)),
            icon: Icon(p.closed ? Icons.edit_outlined : Icons.receipt_long_rounded, size: 18),
            label: Text(p.closed ? 'تعديل' : 'تسجيل التكلفة الفعلية'),
          ),
          TextButton.icon(
            onPressed: () async {
              if (await confirmDialog(context, 'حذف هذه المشتريات؟ سيتغيّر رصيد الكابتن.', yes: 'حذف')) {
                if (context.mounted) {
                  context.read<AppStore>().deletePurchase(p.id);
                  toast(context, 'تم الحذف');
                }
              }
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: C.red),
            label: const Text('حذف', style: TextStyle(color: C.red)),
          ),
        ]),
      ]),
    );
  }

  Future<void> _settle(BuildContext context, Captain c, double max, {String type = 'captain_paid'}) async {
    final amount = TextEditingController(text: max.toStringAsFixed(max == max.roundToDouble() ? 0 : 2));
    final note = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(type == 'captain_paid' ? 'توريد من ${c.name} للمحل' : 'دفع أجرة توصيل لـ ${c.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amount, keyboardType: numType, decoration: InputDecoration(labelText: type == 'captain_paid' ? 'المبلغ المورَّد' : 'المبلغ المدفوع للكابتن')),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final err = context.read<AppStore>().addSettlement(c.id, type, num2(amount.text), note.text.trim());
              if (err != null) {
                toast(context, err);
              } else {
                Navigator.pop(ctx);
                toast(context, 'تم تسجيل التسوية');
              }
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
  }
}

class _CaptainAccountSheet extends StatefulWidget {
  final Captain captain;
  const _CaptainAccountSheet({required this.captain});
  @override
  State<_CaptainAccountSheet> createState() => _CaptainAccountSheetState();
}

class _CaptainAccountSheetState extends State<_CaptainAccountSheet> {
  final login = TextEditingController();
  final pw = TextEditingController();
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.captain;
    final title = Text('حساب تطبيق ${c.name}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g));
    if (!cloud.configured || !cloud.isOwner) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        title,
        const SizedBox(height: 12),
        const Text('فعّل الربط السحابي أولاً من الإعدادات ← الربط السحابي، ثم ارجع هنا لإنشاء حساب الكابتن.', style: TextStyle(color: C.muted)),
        const SizedBox(height: 12),
      ]);
    }
    if (c.login != null) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        title,
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: C.g2.withOpacity(.1), borderRadius: BorderRadius.circular(14)),
          child: Text('الحساب مفعّل ✓\nاسم الدخول: ${c.login}\nيدخل الكابتن من شاشة الدخول ← تبويب "كابتن".', style: const TextStyle(fontWeight: FontWeight.w800, height: 1.6)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () async {
                  if (!await confirmDialog(context, 'إلغاء صلاحية دخول ${c.name} للتطبيق؟', yes: 'إلغاء الصلاحية')) return;
                  setState(() => busy = true);
                  final uidC = c.cloudUid;
                  final ok = uidC == null ? true : await cloud.revokeCaptain(uidC);
                  if (!mounted) return;
                  setState(() => busy = false);
                  if (!ok) return toast(context, 'تعذّر إلغاء الصلاحية، تحقق من الاتصال');
                  c.login = null;
                  c.cloudUid = null;
                  context.read<AppStore>().saveCaptain(c);
                  Navigator.pop(context);
                  toast(context, 'تم إلغاء صلاحية الدخول');
                },
          icon: const Icon(Icons.block_rounded, color: C.red),
          label: const Text('إلغاء صلاحية الدخول', style: TextStyle(color: C.red)),
        ),
        const SizedBox(height: 8),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      title,
      const SizedBox(height: 12),
      const Text('أنشئ لهذا الكابتن اسم دخول وكلمة مرور ليدخل بهما من تطبيقه ويرى طلباته.', style: TextStyle(color: C.muted, fontSize: 12)),
      const SizedBox(height: 12),
      inp('اسم الدخول (حروف إنجليزية وأرقام، مثال: osama)', login),
      inp('كلمة المرور (6 أحرف على الأقل)', pw),
      LuxButton(busy ? 'جاري الإنشاء...' : 'إنشاء الحساب', Icons.person_add_alt_1, busy
          ? null
          : () async {
              setState(() => busy = true);
              final (err, newUid) = await cloud.createCaptainAccount(c.id, c.name, login.text, pw.text);
              if (!mounted) return;
              setState(() => busy = false);
              if (err != null) return toast(context, err);
              final st = context.read<AppStore>();
              c.login = login.text.trim().toLowerCase();
              c.cloudUid = newUid;
              st.saveCaptain(c);
              st.pushCaptain(c.id);
              Navigator.pop(context);
              toast(context, 'تم إنشاء حساب الكابتن ✓');
            }),
      const SizedBox(height: 8),
    ]);
  }
}

class _PurchaseForm extends StatefulWidget {
  final int captainId;
  final Purchase? purchase;
  const _PurchaseForm({required this.captainId, this.purchase});
  @override
  State<_PurchaseForm> createState() => _PurchaseFormState();
}

class _PurchaseFormState extends State<_PurchaseForm> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(text: widget.purchase?.title ?? '');
  late final given = TextEditingController(text: widget.purchase == null ? '' : qtyText(widget.purchase!.given).replaceAll(',', ''));
  late final actual = TextEditingController(
      text: (widget.purchase != null && widget.purchase!.closed) ? qtyText(widget.purchase!.actual).replaceAll(',', '') : '');
  late final note = TextEditingController(text: widget.purchase?.note ?? '');

  @override
  Widget build(BuildContext context) {
    final edit = widget.purchase != null;
    final g = num2(given.text);
    final a = num2(actual.text);
    final String preview;
    if (a <= 0) {
      preview = 'لم تُسجَّل التكلفة بعد: يُعتبر ${money(g)} عهدة على الكابتن حتى يُكمل الشراء.';
    } else if (a > g) {
      preview = 'الكابتن دفع زيادة من جيبه، وسيُقيَّد له على المحل: ${money(a - g)}';
    } else if (a < g) {
      preview = 'متبقٍّ يعيده الكابتن للمحل: ${money(g - a)}';
    } else {
      preview = 'المبلغ مطابق، لا فرق.';
    }
    return Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(edit ? 'تعديل المشتريات' : 'مشتريات خارجية جديدة', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
        const SizedBox(height: 14),
        inp('وصف المشتريات (مثال: عبوات بلاستيك)', title, required: true),
        inp('المبلغ المسلَّم للكابتن (YER)', given, type: numType, onChanged: (_) => setState(() {})),
        inp('التكلفة الفعلية (اتركها فارغة إن لم يُكمل الشراء)', actual, type: numType, onChanged: (_) => setState(() {})),
        inp('ملاحظات / رقم الفاتورة', note, lines: 2),
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.gold.withOpacity(.12), borderRadius: BorderRadius.circular(14)),
          child: Text(preview, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ),
        LuxButton('حفظ', Icons.save_rounded, () {
          if (!form.currentState!.validate()) return;
          final st = context.read<AppStore>();
          final pr = widget.purchase ?? Purchase(id: 0, captainId: widget.captainId, title: '', given: 0, date: DateTime.now());
          pr.title = title.text.trim();
          pr.given = num2(given.text);
          pr.actual = num2(actual.text);
          pr.closed = actual.text.trim().isNotEmpty && pr.actual > 0;
          pr.note = note.text.trim();
          st.savePurchase(pr);
          Navigator.pop(context);
          toast(context, 'تم حفظ المشتريات');
        }),
      ]),
    );
  }
}

class _CaptainForm extends StatefulWidget {
  final Captain? captain;
  final void Function(int id)? onSaved;
  const _CaptainForm({this.captain, this.onSaved});
  @override
  State<_CaptainForm> createState() => _CaptainFormState();
}

class _CaptainFormState extends State<_CaptainForm> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.captain?.name ?? '');
  late final phone = TextEditingController(text: widget.captain?.phone ?? '');

  @override
  Widget build(BuildContext context) {
    final edit = widget.captain != null;
    return Form(
      key: form,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(edit ? 'تعديل الكابتن' : 'إضافة كابتن', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
        const SizedBox(height: 14),
        inp('الاسم', name, required: true),
        inp('رقم الهاتف (مع رمز الدولة)', phone, type: TextInputType.phone, required: true),
        LuxButton('حفظ', Icons.save_rounded, () {
          if (!form.currentState!.validate()) return;
          final c = widget.captain ?? Captain(id: 0, name: '', phone: '');
          c.name = name.text.trim();
          c.phone = phone.text.trim();
          context.read<AppStore>().saveCaptain(c);
          widget.onSaved?.call(c.id);
          Navigator.pop(context);
          toast(context, edit ? 'تم حفظ التعديلات' : 'تمت إضافة الكابتن');
        }),
      ]),
    );
  }
}

// ====================================================================
//  الإعدادات (ملف صاحب المتجر + المتجر + الدخول + النسخ الاحتياطي)
// ====================================================================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppStore s = context.read<AppStore>();
  late final owner = TextEditingController(text: s.settings.ownerName);
  late final name = TextEditingController(text: s.settings.storeName);
  late final phone = TextEditingController(text: s.settings.storePhone);
  late final address = TextEditingController(text: s.settings.storeAddress);
  late final user = TextEditingController(text: s.settings.username);
  late final pass = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppStore>();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
          const PageHead('الملف الشخصي لصاحب المتجر'),
          LuxCard(
            child: Column(children: [
              ImagePickField(
                value: st.settings.ownerImage,
                label: 'صورتي الشخصية',
                circle: true,
                size: 84,
                maxSide: 400,
                fallback: Icons.person_rounded,
                onChanged: (v) {
                  s.setOwnerImage(v);
                  if (mounted) toast(context, v == null ? 'تم حذف الصورة' : 'تم تحديث الصورة الشخصية');
                },
              ),
              inp('اسم صاحب المتجر', owner),
              LuxButton('حفظ الملف الشخصي', Icons.save_rounded, () {
                s.updateStore(name: name.text.trim(), phone: phone.text.trim(), address: address.text.trim(), ownerName: owner.text.trim());
                toast(context, 'تم حفظ الملف الشخصي');
              }),
            ]),
          ),
          const PageHead('بيانات المتجر'),
          LuxCard(
            child: Column(children: [
              ImagePickField(
                value: st.settings.logoPath,
                label: 'شعار المتجر',
                circle: true,
                size: 84,
                maxSide: 400,
                png: true,
                fallback: Icons.eco_rounded,
                onChanged: (v) {
                  s.setLogo(v);
                  if (mounted) toast(context, v == null ? 'تم حذف الشعار' : 'تم تحديث الشعار');
                },
              ),
              inp('اسم المتجر', name),
              inp('هاتف المتجر', phone, type: TextInputType.phone),
              inp('العنوان / الشعار النصي', address, lines: 2),
              LuxButton('حفظ بيانات المتجر', Icons.save_rounded, () {
                s.updateStore(name: name.text.trim(), phone: phone.text.trim(), address: address.text.trim(), ownerName: owner.text.trim());
                toast(context, 'تم حفظ بيانات المتجر');
              }),
            ]),
          ),
          const PageHead('بيانات الدخول'),
          LuxCard(
            child: Column(children: [
              inp('اسم المستخدم', user),
              inp('كلمة المرور الجديدة (اتركها فارغة للإبقاء على الحالية)', pass, obscure: true),
              LuxButton('تحديث بيانات الدخول', Icons.lock_outline, () {
                if (user.text.trim().isEmpty) return toast(context, 'أدخل اسم المستخدم');
                if (pass.text.isNotEmpty && pass.text.length < 6) return toast(context, 'كلمة المرور 6 أحرف على الأقل');
                s.updateCredentials(user.text.trim(), pass.text);
                pass.clear();
                toast(context, 'تم تحديث بيانات الدخول');
              }),
            ]),
          ),
          const PageHead('النسخ الاحتياطي'),
          LuxCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('بياناتك تُحفظ تلقائياً داخل التطبيق. عند حذف التطبيق أو تغيير الهاتف تضيع، فخذ نسخة احتياطية (تشمل الصور) واحتفظ بها في مكان آمن.',
                  style: TextStyle(color: C.muted, fontSize: 12)),
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.upload_file_rounded), label: const Text('تصدير نسخة احتياطية')),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: _importFile, icon: const Icon(Icons.folder_open_rounded), label: const Text('استيراد من ملف')),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.download_rounded), label: const Text('لصق واستيراد نص')),
            ]),
          ),
          const PageHead('القائمة الإلكترونية (طلب العميل)'),
          LuxCard(
            accent: st.settings.onlineEnabled ? C.g2 : C.muted,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(st.settings.onlineEnabled ? 'مفعّلة ✓ — العملاء يطلبون من الرابط أو QR' : 'غير مفعّلة. فعّلها ليطلب العملاء بأنفسهم من قائمة بالأصناف والأسعار.',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, height: 1.6)),
              const SizedBox(height: 10),
              LuxButton('إعدادات الطلب الإلكتروني و QR', Icons.qr_code_2_rounded, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OnlineSettingsPage()))),
            ]),
          ),
          const PageHead('الربط السحابي (تطبيق الكابتن)'),
          ListenableBuilder(
            listenable: cloud,
            builder: (context, _) => LuxCard(
              accent: cloud.isOwner ? C.g2 : C.orange,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (!cloud.configured)
                  const Text('لم يُضبط Firebase بعد. عدّل ملف lib/cloud_config.dart بمفتاح المشروع ورابط قاعدة البيانات (انظر ملف firebase_setup.md).',
                      style: TextStyle(color: C.muted, fontSize: 12, height: 1.6))
                else if (cloud.isOwner) ...[
                  Text('متصل بالسحابة ✓\n${cloud.email ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, height: 1.6)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      toast(context, 'جاري المزامنة...');
                      final n = await s.fullSync();
                      if (mounted) toast(context, 'تمت المزامنة ($n طلب)');
                    },
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('مزامنة كل البيانات الآن'),
                  ),
                  const SizedBox(height: 8),
                  Text(s.lastBackupAt == null ? 'النسخ الاحتياطي التلقائي: يعمل كل 20 دقيقة عند وجود تغييرات' : 'آخر نسخة احتياطية سحابية: ${dateText(s.lastBackupAt!)}',
                      style: const TextStyle(color: C.muted, fontSize: 11)),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () async {
                      toast(context, 'جاري رفع النسخة الاحتياطية...');
                      final ok = await s.backupNow();
                      if (mounted) toast(context, ok ? 'تم حفظ نسخة احتياطية في السحابة ✓' : 'تعذّر الحفظ — حدّث قواعد Firebase');
                    },
                    icon: const Icon(Icons.cloud_upload_rounded),
                    label: const Text('نسخ احتياطي إلى السحابة الآن'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (!await confirmDialog(context, 'استرجاع آخر نسخة من السحابة؟ ستُستبدل بيانات هذا الجهاز بها.', yes: 'استرجاع')) return;
                      final err = await s.restoreFromCloud();
                      if (mounted) toast(context, err ?? 'تم الاسترجاع بنجاح ✓');
                    },
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('استرجاع من السحابة'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      if (await confirmDialog(context, 'فصل هذا الجهاز عن السحابة؟ لن تصل الطلبات للكباتن حتى تعيد التفعيل.', yes: 'فصل')) {
                        s.stopCloud();
                        await cloud.logout();
                      }
                    },
                    child: const Text('فصل الربط', style: TextStyle(color: C.red)),
                  ),
                ] else ...[
                  const Text('فعّل الربط ليرى الكباتن طلباتهم في تطبيقهم، وتصلك تحديثات الحالة منهم.', style: TextStyle(color: C.muted, fontSize: 12, height: 1.6)),
                  const SizedBox(height: 10),
                  LuxButton('تفعيل الربط السحابي', Icons.cloud_done_rounded, _activate),
                ],
              ]),
            ),
          ),
          const PageHead('منطقة الخطر'),
          LuxCard(
            accent: C.red,
            child: Row(children: [
              const Expanded(child: Text('إعادة ضبط كل البيانات للوضع الافتراضي', style: TextStyle(fontWeight: FontWeight.w800))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: C.red),
                onPressed: () async {
                  if (await confirmDialog(context, 'سيتم حذف جميع الطلبات والبيانات نهائياً. هل أنت متأكد؟', yes: 'إعادة ضبط')) {
                    s.resetAll();
                    if (mounted) toast(context, 'تمت إعادة الضبط');
                  }
                },
                child: const Text('إعادة ضبط'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _activate() async {
    final em = TextEditingController();
    final pw = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('تفعيل الربط السحابي'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('أدخل بريدك الإلكتروني وكلمة مرور (6 أحرف فأكثر). أول مرة يُنشأ الحساب تلقائياً، ولاحقاً استخدم نفس البيانات.', style: TextStyle(fontSize: 12, color: C.muted)),
          const SizedBox(height: 12),
          TextField(controller: em, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
          const SizedBox(height: 10),
          TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تفعيل')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (!em.text.contains('@') || pw.text.length < 6) return toast(context, 'أدخل بريداً صحيحاً وكلمة مرور 6 أحرف على الأقل');
    toast(context, 'جاري الاتصال...');
    final err = await cloud.ownerActivate(em.text.trim(), pw.text, s.settings.ownerName);
    if (!mounted) return;
    if (err != null) return toast(context, err);
    s.startCloud();
    toast(context, 'تم تفعيل الربط السحابي ✓');
  }

  Future<void> _export() async {
    toast(context, 'جاري تجهيز النسخة...');
    final txt = await s.exportJsonFull();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('نسخة احتياطية'),
        content: Text('حجم البيانات: ${(txt.length / 1024).toStringAsFixed(0)} ك.ب\nالنسخة تشمل الأصناف والعملاء والطلبات والصور.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          OutlinedButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: txt));
              Navigator.pop(ctx);
              toast(context, 'تم نسخ البيانات');
            },
            child: const Text('نسخ'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await shareBytesFile(Uint8List.fromList(utf8.encode(txt)), 'salad-bar-backup-${dayKey(DateTime.now())}.json', 'application/json');
              } catch (_) {
                if (mounted) toast(context, 'تعذّر مشاركة الملف');
              }
            },
            child: const Text('حفظ / مشاركة ملف'),
          ),
        ],
      ),
    );
  }

  Future<void> _importFile() async {
    final t = await pickTextFile();
    if (t == null) return;
    final ok = await s.importJson(t);
    if (mounted) toast(context, ok ? 'تم الاستيراد بنجاح' : 'ملف غير صالح');
  }

  void _import() {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('استيراد بيانات'),
        content: TextField(controller: c, maxLines: 8, decoration: const InputDecoration(hintText: 'الصق نص JSON هنا')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              final ok = await s.importJson(c.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) toast(context, ok ? 'تم الاستيراد بنجاح' : 'نص غير صالح');
            },
            child: const Text('استيراد'),
          ),
        ],
      ),
    );
  }
}

// ====================================================================
//  الهيكل الرئيسي
// ====================================================================

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  final key = GlobalKey<ScaffoldState>();
  late final AppStore _store;

  @override
  void initState() {
    super.initState();
    _store = context.read<AppStore>();
    _store.startCloud();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _store.settings.mustChange) _forcePasswordChange();
    });
  }

  Future<void> _forcePasswordChange() async {
    final u = TextEditingController(text: _store.settings.username);
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    String? err;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: const Text('تأمين الحساب'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('لحماية بياناتك اختر اسم مستخدم وكلمة مرور جديدة قبل المتابعة.', style: TextStyle(fontSize: 12, color: C.muted, height: 1.6)),
                const SizedBox(height: 12),
                TextField(controller: u, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
                const SizedBox(height: 10),
                TextField(controller: p1, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة (6 أحرف فأكثر)')),
                const SizedBox(height: 10),
                TextField(controller: p2, obscureText: true, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور')),
                if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: C.red, fontWeight: FontWeight.w800, fontSize: 12))),
              ]),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  if (u.text.trim().isEmpty) return set(() => err = 'أدخل اسم المستخدم');
                  if (p1.text.length < 6) return set(() => err = 'كلمة المرور 6 أحرف على الأقل');
                  if (p1.text == '1234') return set(() => err = 'اختر كلمة مرور غير الافتراضية');
                  if (p1.text != p2.text) return set(() => err = 'كلمتا المرور غير متطابقتين');
                  _store.updateCredentials(u.text.trim(), p1.text);
                  Navigator.pop(ctx);
                },
                child: const Text('حفظ ومتابعة'),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) toast(context, 'تم تحديث بيانات الدخول ✓');
  }

  @override
  void dispose() {
    _store.stopCloud();
    super.dispose();
  }

  static const titles = ['الرئيسية', 'الطلبات', 'الأصناف والمخزون', 'العملاء', 'الكباتن', 'التقارير والمبيعات', 'الإعدادات'];
  static const icons = [
    Icons.dashboard_rounded,
    Icons.receipt_long_rounded,
    Icons.restaurant_menu_rounded,
    Icons.people_alt_rounded,
    Icons.two_wheeler_rounded,
    Icons.insights_rounded,
    Icons.settings_rounded,
  ];

  void go(int i) => setState(() => index = i);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final pages = [
      DashboardPage(go: go),
      const OrdersPage(),
      const ProductsPage(),
      const CustomersPage(),
      const CaptainsPage(),
      const ReportsPage(),
      const SettingsPage(),
    ];
    final wide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      key: key,
      appBar: AppBar(
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient)),
        titleSpacing: 0,
        title: Row(children: [
          const SizedBox(width: 6),
          Avatar(s.settings.logoPath, size: 34, fallback: Icons.eco_rounded),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(s.settings.storeName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              Text(titles[index], style: const TextStyle(fontSize: 10, color: C.gold, fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
        actions: [
          if (s.settings.onlineEnabled)
            IconButton(
              tooltip: 'طلبات القائمة الإلكترونية',
              icon: Badge(label: Text('${s.webOrders.length}'), isLabelVisible: s.webOrders.isNotEmpty, child: const Icon(Icons.shopping_basket_rounded)),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WebOrdersPage())),
            ),
          GestureDetector(
            onTap: () => go(6),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Avatar(s.settings.ownerImage, size: 30)),
          ),
          IconButton(
            tooltip: 'خروج',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () => context.read<AppStore>().logout(),
          ),
        ],
      ),
      drawer: wide
          ? null
          : Drawer(
              child: Column(children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 56, 20, 22),
                  decoration: const BoxDecoration(gradient: C.brandGradient),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Avatar(s.settings.ownerImage, size: 56),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.settings.ownerName, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
                          Text(s.settings.storeName, style: const TextStyle(color: C.gold, fontSize: 12, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    const Text('مكرونة مخلوطة .. طعم يرضيك', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ]),
                ),
                Expanded(
                  child: ListView(padding: EdgeInsets.zero, children: [
                    for (var i = 0; i < titles.length; i++)
                      ListTile(
                        leading: Icon(icons[i], color: index == i ? C.gold : C.g),
                        title: Text(titles[i], style: TextStyle(fontWeight: FontWeight.w800, color: index == i ? C.g : C.text)),
                        selected: index == i,
                        selectedTileColor: C.g.withOpacity(.07),
                        onTap: () {
                          Navigator.pop(context);
                          go(i);
                        },
                      ),
                  ]),
                ),
              ]),
            ),
      body: Row(children: [
        if (wide)
          NavigationRail(
            backgroundColor: Colors.white,
            selectedIndex: index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: go,
            destinations: [
              for (var i = 0; i < titles.length; i++)
                NavigationRailDestination(icon: Icon(icons[i]), label: Text(titles[i], style: const TextStyle(fontSize: 11))),
            ],
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1250), child: pages[index]),
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.gold,
        foregroundColor: C.dark,
        icon: const Icon(Icons.add_rounded),
        label: const Text('طلب جديد', style: TextStyle(fontWeight: FontWeight.w900)),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrderFormPage())),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index < 4 ? index : 4,
              onDestinationSelected: (i) {
                if (i == 4) {
                  key.currentState?.openDrawer();
                } else {
                  go(i);
                }
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'الرئيسية'),
                NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long_rounded), label: 'الطلبات'),
                NavigationDestination(icon: Icon(Icons.restaurant_menu_outlined), selectedIcon: Icon(Icons.restaurant_menu_rounded), label: 'الأصناف'),
                NavigationDestination(icon: Icon(Icons.people_alt_outlined), selectedIcon: Icon(Icons.people_alt_rounded), label: 'العملاء'),
                NavigationDestination(icon: Icon(Icons.menu_rounded), label: 'المزيد'),
              ],
            ),
    );
  }
}

// ====================================================================
//  نقطة البداية
// ====================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final raw = await loadPersisted();
  await cloud.load();
  final store = AppStore()..init(raw);
  await store.migrateImages();
  WidgetsBinding.instance.addObserver(_LifeObserver(store));
  runApp(StoreScope(notifier: store, child: const SaladBarApp()));
}

Uint8List _makeThumb(Uint8List b) {
  final im = imglib.decodeImage(b);
  if (im == null) return b;
  final r = imglib.copyResize(imglib.bakeOrientation(im), width: 360);
  return Uint8List.fromList(imglib.encodeJpg(r, quality: 72));
}

class _LifeObserver with WidgetsBindingObserver {
  final AppStore store;
  _LifeObserver(this.store);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) store.flush();
  }
}

class _SplashGate extends StatefulWidget {
  final Widget child;
  const _SplashGate({required this.child});
  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool done = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: done
          ? widget.child
          : Scaffold(
              key: const ValueKey('splash'),
              body: Container(
                decoration: const BoxDecoration(gradient: C.brandGradient),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Avatar(s.settings.logoPath, size: 110, fallback: Icons.eco_rounded),
                    const SizedBox(height: 18),
                    Text(s.settings.storeName, style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text('مكرونة مخلوطة .. طعم يرضيك', style: TextStyle(color: C.gold, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 28),
                    const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: C.gold)),
                  ]),
                ),
              ),
            ),
    );
  }
}

class SaladBarApp extends StatelessWidget {
  const SaladBarApp({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'سلطة بار',
      theme: buildTheme(),
      scaffoldMessengerKey: messengerKey,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: _SplashGate(
        child: ListenableBuilder(
          listenable: cloud,
          builder: (context, _) => cloud.isCaptain ? const CaptainHome() : (s.loggedIn ? const HomeShell() : const LoginScreen()),
        ),
      ),
    );
  }
}

// ====================================================================
//  واجهة الكابتن
// ====================================================================

Future<void> openMap(BuildContext c, String address) async {
  if (address.trim().isEmpty) return toast(c, 'لا يوجد عنوان');
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}'),
        mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && c.mounted) toast(c, 'تعذّر فتح الخريطة');
}

class CaptainHome extends StatefulWidget {
  const CaptainHome({super.key});
  @override
  State<CaptainHome> createState() => _CaptainHomeState();
}

class _CaptainHomeState extends State<CaptainHome> {
  List<Map<String, dynamic>> orders = [];
  Map<String, dynamic>? stats;
  bool loading = true, offline = false, busy = false;
  DateTime? last;
  int tab = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _load();
    timer = Timer.periodic(const Duration(seconds: 8), (_) => _load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final o = await cloud.fetchMyOrders();
    final st = await cloud.fetchMyStats();
    if (!mounted) return;
    setState(() {
      loading = false;
      if (o == null) {
        offline = true;
      } else {
        offline = false;
        last = DateTime.now();
        orders = asMapList(o)..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
      }
      if (st != null && st.isNotEmpty) stats = st;
    });
  }

  /// الكابتن عند باب العميل: يحفظ موقعه الحالي كموقع للعميل
  Future<void> _saveLoc(Map<String, dynamic> o) async {
    if (busy) return;
    if (!await confirmDialog(context, 'هل أنت الآن عند العميل؟ سيُحفظ موقعك الحالي كموقع لهذا العميل ليستفيد منه الطلب القادم.', yes: 'حفظ الموقع')) return;
    setState(() => busy = true);
    final p = await getMyLocation(context);
    if (p == null) {
      if (mounted) setState(() => busy = false);
      return;
    }
    final ok = await cloud.captainSendLocation(_d(o['id']).toInt(), '${o['status']}', p.lat, p.lng);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (ok) {
        o['customerLat'] = p.lat;
        o['customerLng'] = p.lng;
      }
    });
    toast(context, ok ? 'تم حفظ موقع العميل ✓' : 'تعذّر الإرسال — تحقق من الاتصال');
  }

  bool _isActive(Map<String, dynamic> o) {
    final st = '${o['status']}';
    return st == 'new' || st == 'prep' || st == 'delivery';
  }

  Future<void> _set(Map<String, dynamic> o, String st) async {
    if (busy) return;
    setState(() => busy = true);
    final ok = await cloud.captainSetStatus(_d(o['id']).toInt(), st);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (ok) o['status'] = st;
    });
    toast(context, ok ? 'تم تحديث حالة الطلب ✓' : 'تعذّر التحديث — تحقق من الاتصال');
  }

  @override
  Widget build(BuildContext context) {
    final active = orders.where(_isActive).toList();
    final history = orders.where((o) => !_isActive(o)).toList();
    final store = '${stats?['store'] ?? orders.firstOrNull?['store'] ?? 'سلطة بار'}';
    final titles = ['طلباتي الحالية', 'الطلبات المنتهية', 'حسابي'];
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient)),
        titleSpacing: 12,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(store, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          Text('${titles[tab]} • ${cloud.name ?? ''}', style: const TextStyle(fontSize: 10, color: C.gold, fontWeight: FontWeight.w700)),
        ]),
        actions: [
          IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded), onPressed: _load),
        ],
      ),
      body: Column(children: [
        if (offline)
          Container(
            width: double.infinity,
            color: C.orange.withOpacity(.15),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: const Text('لا يوجد اتصال — تُعرض آخر بيانات محمّلة', textAlign: TextAlign.center, style: TextStyle(color: C.orange, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : switch (tab) {
                  0 => _list(active, 'لا توجد طلبات حالياً', Icons.two_wheeler_rounded),
                  1 => _list(history, 'لا توجد طلبات منتهية', Icons.history_rounded),
                  _ => _account(),
                },
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(label: Text('${active.length}'), isLabelVisible: active.isNotEmpty, child: const Icon(Icons.two_wheeler_outlined)),
            selectedIcon: Badge(label: Text('${active.length}'), isLabelVisible: active.isNotEmpty, child: const Icon(Icons.two_wheeler_rounded)),
            label: 'الحالية',
          ),
          const NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history_rounded), label: 'المنتهية'),
          const NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet_rounded), label: 'حسابي'),
        ],
      ),
    );
  }

  Widget _list(List<Map<String, dynamic>> list, String emptyText, IconData icon) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
        children: [
          if (list.isEmpty) Empty(emptyText, icon: icon),
          for (final o in list) _card(o),
        ],
      ),
    );
  }

  Widget _line(IconData i, String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, size: 16, color: C.muted),
          const SizedBox(width: 6),
          Expanded(child: Text(t, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
        ]),
      );

  Widget _card(Map<String, dynamic> o) {
    final st = '${o['status'] ?? 'new'}';
    final due = _d(o['customerDue']);
    final fee = _d(o['delivery']);
    final items = asMapList(o['items']);
    final phone = '${o['customerPhone'] ?? ''}';
    final addr = '${o['customerAddress'] ?? ''}';
    final notes = '${o['notes'] ?? ''}';
    final id = _d(o['id']).toInt();
    final lat = o['customerLat'] is num ? (o['customerLat'] as num).toDouble() : null;
    final lng = o['customerLng'] is num ? (o['customerLng'] as num).toDouble() : null;
    final hasLoc = lat != null && lng != null;
    final date = DateTime.tryParse('${o['date']}');
    return LuxCard(
      accent: statusColor(st),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('#$id', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: C.g)),
          const SizedBox(width: 8),
          Expanded(child: Text('${o['customerName'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15), overflow: TextOverflow.ellipsis)),
          Badge2(statusLabel(st), statusColor(st)),
        ]),
        const SizedBox(height: 6),
        if (phone.isNotEmpty) _line(Icons.phone_rounded, phone),
        _line(Icons.location_on_rounded, '${addr.isEmpty ? 'لا يوجد عنوان' : addr}${hasLoc ? '   📍 موقع دقيق' : ''}'),
        if (date != null) _line(Icons.schedule_rounded, dateText(date)),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
            child: Text(
              items.map((i) => '• ${i['name']} × ${qtyText(_d(i['qty']))} ${unitShort('${i['unit'] ?? ''}')}').join('\n'),
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: (due > 0 ? C.orange : C.g2).withOpacity(.1), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Text(due > 0 ? 'المطلوب تحصيله من العميل' : ('${o['method']}' == 'credit' ? '📒 آجل على حساب العميل — لا تحصّل أي مبلغ' : '✅ مدفوع بالكامل — لا تحصّل أي مبلغ'),
                textAlign: TextAlign.center, style: TextStyle(color: due > 0 ? C.orange : C.g2, fontWeight: FontWeight.w900, fontSize: 13)),
            if (due > 0) ...[
              const SizedBox(height: 2),
              Text(money(due), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: C.dark)),
              Text('يُورَّد للمحل: ${money(_d(o['goodsDue']))} • أجرتك: ${money(fee)} (تبقى معك)',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: C.muted)),
            ] else
              Text('أجرتك: ${money(fee)} (تُقيَّد لك على المحل)', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ),
        if (notes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: _line(Icons.sticky_note_2_outlined, 'ملاحظات: $notes')),
        const Divider(height: 18),
        Wrap(children: [
          if (phone.isNotEmpty) TextButton.icon(onPressed: () => callPhone(context, phone), icon: const Icon(Icons.call_rounded, size: 18, color: C.blue), label: const Text('اتصال', style: TextStyle(color: C.blue))),
          TextButton.icon(onPressed: () => openNavigation(context, lat: lat, lng: lng, address: addr), icon: Icon(hasLoc ? Icons.navigation_rounded : Icons.map_rounded, size: 18, color: C.purple), label: Text(hasLoc ? 'ملاحة للموقع' : 'الخريطة', style: const TextStyle(color: C.purple))),
          if (st == 'new' || st == 'prep' || st == 'delivery') TextButton.icon(onPressed: () => _saveLoc(o), icon: const Icon(Icons.pin_drop_rounded, size: 18, color: C.orange), label: const Text('حفظ موقع العميل', style: TextStyle(color: C.orange))),
          if (phone.isNotEmpty) TextButton.icon(onPressed: () => sendWa(context, phone, 'مرحباً ${o['customerName'] ?? ''} 🌿 أنا الكابتن ${cloud.name ?? ''} من ${o['store'] ?? 'المتجر'}، في الطريق إليك بطلبك #$id.'), icon: const Icon(Icons.chat_rounded, size: 18, color: C.wa), label: const Text('واتساب', style: TextStyle(color: C.wa))),
        ]),
        if (st == 'new' || st == 'prep') ...[
          const SizedBox(height: 6),
          LuxButton('بدأت التوصيل', Icons.two_wheeler_rounded, busy ? null : () => _set(o, 'delivery'), colors: const [Color(0xFF5B21B6), C.purple]),
        ] else if (st == 'delivery') ...[
          const SizedBox(height: 6),
          LuxButton('تم التسليم', Icons.check_circle_rounded, busy
              ? null
              : () async {
                  if (await confirmDialog(context, 'تأكيد تسليم الطلب #$id للعميل؟', yes: 'تم التسليم')) _set(o, 'done');
                }, colors: const [Color(0xFF1F6F43), C.g2]),
        ],
      ]),
    );
  }

  Widget _stat(String t, String v, Color col) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: col.withOpacity(.09), borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Expanded(child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13))),
          Text(v, style: TextStyle(color: col, fontWeight: FontWeight.w900, fontSize: 18)),
        ]),
      );

  Widget _account() {
    final cash = _d(stats?['cashDue']);
    final credit = _d(stats?['creditDue']);
    final net = _d(stats?['net']);
    final at = DateTime.tryParse('${stats?['at']}');
    return ListView(padding: const EdgeInsets.all(14), children: [
      LuxCard(
        child: Row(children: [
          const CircleAvatar(radius: 26, backgroundColor: Color(0xFFEAF4ED), child: Icon(Icons.two_wheeler_rounded, color: C.g, size: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(cloud.name ?? 'كابتن', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const Text('كابتن توصيل', style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        ]),
      ),
      const PageHead('كشف حسابي'),
      if (stats == null)
        const LuxCard(child: Empty('لم يصل كشف الحساب بعد', icon: Icons.account_balance_wallet_outlined))
      else ...[
        _stat('عليّ للمحل (توريد)', money(cash), cash > 0 ? C.red : C.g2),
        const SizedBox(height: 8),
        _stat('لي عند المحل', money(credit), credit > 0 ? C.purple : C.g2),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(gradient: C.brandGradient, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.gold.withOpacity(.6))),
          child: Column(children: [
            Text(net > 0 ? 'الصافي: لي على المحل' : net < 0 ? 'الصافي: عليّ للمحل' : 'الحساب متساوٍ', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Text(money(net.abs()), style: const TextStyle(color: Color(0xFFFFE58B), fontSize: 26, fontWeight: FontWeight.w900)),
          ]),
        ),
        if (at != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('آخر تحديث: ${dateText(at)}', textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 11))),
      ],
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: () async {
          if (await confirmDialog(context, 'تسجيل الخروج من حساب الكابتن؟', yes: 'خروج')) {
            await cloud.logout();
          }
        },
        icon: const Icon(Icons.logout_rounded, color: C.red),
        label: const Text('تسجيل الخروج', style: TextStyle(color: C.red)),
      ),
    ]);
  }
}
