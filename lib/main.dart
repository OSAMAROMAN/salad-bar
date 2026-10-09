// سلطة بار — نظام إدارة الطلبات (نسخة أندرويد / APK)
// الدخول الافتراضي: admin / 1234
// الحزم: image_picker, url_launcher, path_provider, share_plus, file_picker
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
      _ => 'مدفوع بالكامل (شامل التوصيل)',
    };

// ====================================================================
//  أدوات الهاتف: تخزين، صور، واتساب، مشاركة
// ====================================================================

File? _dataFile;
Future<void> _writeChain = Future.value();

/// يقرأ البيانات المحفوظة من ذاكرة التطبيق (يُستدعى مرة واحدة عند التشغيل)
Future<String?> loadPersisted() async {
  try {
    final d = await getApplicationDocumentsDirectory();
    _dataFile = File('${d.path}/salad_bar_data.json');
    if (await _dataFile!.exists()) return await _dataFile!.readAsString();
  } catch (_) {}
  return null;
}

void _persist(String s) {
  final f = _dataFile;
  if (f == null) return;
  _writeChain = _writeChain.then((_) async {
    try {
      await f.writeAsString(s, flush: true);
    } catch (_) {}
  });
}

final ImagePicker _picker = ImagePicker();

/// اختيار صورة (معرض أو كاميرا) مع تصغيرها وإرجاعها كـ data URL
Future<String?> pickImageData({int maxSide = 600, bool png = false, bool camera = false}) async {
  try {
    final x = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: maxSide.toDouble(),
      maxHeight: maxSide.toDouble(),
      imageQuality: 85,
    );
    if (x == null) return null;
    final b = await x.readAsBytes();
    final isPng = x.path.toLowerCase().endsWith('.png');
    return 'data:${isPng ? 'image/png' : 'image/jpeg'};base64,${base64Encode(b)}';
  } catch (_) {
    return null;
  }
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
  return Image.network(path,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => fallback,
      loadingBuilder: (c, child, p) => p == null ? child : fallback);
}

// ====================================================================
//  النماذج
// ====================================================================

class AppSettings {
  String username, password, storeName, storePhone, storeAddress, ownerName;
  String? logoPath, ownerImage;
  AppSettings({
    this.username = 'admin',
    this.password = '1234',
    this.storeName = 'سلطة بار',
    this.storePhone = '',
    this.storeAddress = '',
    this.ownerName = 'صاحب المتجر',
    this.logoPath,
    this.ownerImage,
  });
  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        'storeName': storeName,
        'storePhone': storePhone,
        'storeAddress': storeAddress,
        'ownerName': ownerName,
        'logoPath': logoPath,
        'ownerImage': ownerImage,
      };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        username: j['username'] ?? 'admin',
        password: j['password'] ?? '1234',
        storeName: j['storeName'] ?? 'سلطة بار',
        storePhone: j['storePhone'] ?? '',
        storeAddress: j['storeAddress'] ?? '',
        ownerName: j['ownerName'] ?? 'صاحب المتجر',
        logoPath: j['logoPath'],
        ownerImage: j['ownerImage'],
      );
}

class Product {
  int id;
  String name, unit;
  double price, stock, lowStock;
  bool active;
  String? imagePath;
  Product({
    required this.id,
    required this.name,
    required this.price,
    this.unit = 'piece',
    this.stock = 0,
    this.lowStock = 10,
    this.active = true,
    this.imagePath,
  });
  bool get isPiece => unit == 'piece';
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'price': price,
        'unit': unit,
        'stock': stock,
        'lowStock': lowStock,
        'active': active,
        'imagePath': imagePath,
      };
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'],
        name: j['name'],
        price: _d(j['price']),
        unit: j['unit'] ?? 'piece',
        stock: _d(j['stock']),
        lowStock: _d(j['lowStock']),
        active: j['active'] ?? true,
        imagePath: j['imagePath'],
      );
}

class Customer {
  int id;
  String name, phone, address, notes;
  Customer({required this.id, required this.name, required this.phone, required this.address, this.notes = ''});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'address': address, 'notes': notes};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'],
        name: j['name'],
        phone: j['phone'] ?? '',
        address: j['address'] ?? '',
        notes: j['notes'] ?? '',
      );
}

class Captain {
  int id;
  String name, phone;
  bool available;
  Captain({required this.id, required this.name, required this.phone, this.available = true});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'available': available};
  factory Captain.fromJson(Map<String, dynamic> j) =>
      Captain(id: j['id'], name: j['name'], phone: j['phone'] ?? '', available: j['available'] ?? true);
}

class OrderItem {
  int productId;
  String name, unit;
  double price, qty;
  OrderItem({required this.productId, required this.name, required this.price, required this.unit, required this.qty});
  double get lineTotal => price * qty * unitFactor(unit);
  Map<String, dynamic> toJson() => {'productId': productId, 'name': name, 'price': price, 'unit': unit, 'qty': qty};
  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        productId: j['productId'],
        name: j['name'],
        price: _d(j['price']),
        unit: j['unit'] ?? 'piece',
        qty: _d(j['qty']),
      );
}

class Order {
  int id, customerId, captainId;
  DateTime date;
  List<OrderItem> items;
  double subtotal, delivery, discount, total;
  double goodsTotal, paidNow, goodsDue, captainCredit;
  String notes, status, method;
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
    this.notes = '',
    this.status = 'new',
    this.method = 'prepaid',
  });

  /// المبلغ المطلوب تحصيله من العميل عند الاستلام (متبقي الأصناف + التوصيل)
  /// المحاسَب بالكامل = الأصناف + التوصيل مدفوعان، فلا يُطلب من العميل شيء
  double get customerDue => method == 'prepaid' ? 0 : goodsDue + delivery;
  double get paidAmount => method == 'prepaid' ? total : paidNow;

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
        'notes': notes,
        'status': status,
        'method': method,
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
        notes: j['notes'] ?? '',
        status: j['status'] ?? 'new',
        method: j['method'] ?? 'prepaid',
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

class Balances {
  final double cashDue, creditDue;
  const Balances(this.cashDue, this.creditDue);
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
  int _nP = 1, _nC = 1, _nCap = 1, _nO = 1;

  void init(String? raw) {
    var ok = false;
    if (raw != null) {
      try {
        _load(jsonDecode(raw) as Map<String, dynamic>);
        ok = true;
      } catch (_) {}
    }
    if (!ok) _seed();
    loggedIn = false;
    ready = true;
  }

  void _seed() {
    settings = AppSettings(storeAddress: 'مكرونة مخلوطة .. طعم يرضيك');
    products = [];
    _nP = 1;
    void add(String n, double p) => products.add(Product(id: _nP++, name: n, price: p, stock: 999, lowStock: 10));
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
      Captain(id: 1, name: 'كابتن محمد', phone: '967733333333'),
      Captain(id: 2, name: 'كابتن أحمد', phone: '967744444444'),
    ];
    orders = [];
    settlements = [];
    _nC = 2;
    _nCap = 3;
    _nO = 1;
  }

  void _load(Map<String, dynamic> j) {
    settings = AppSettings.fromJson(Map<String, dynamic>.from(j['settings'] ?? {}));
    products = (j['products'] as List).map((e) => Product.fromJson(Map<String, dynamic>.from(e))).toList();
    customers = (j['customers'] as List).map((e) => Customer.fromJson(Map<String, dynamic>.from(e))).toList();
    captains = (j['captains'] as List).map((e) => Captain.fromJson(Map<String, dynamic>.from(e))).toList();
    orders = (j['orders'] as List).map((e) => Order.fromJson(Map<String, dynamic>.from(e))).toList();
    settlements = ((j['settlements'] ?? []) as List).map((e) => Settlement.fromJson(Map<String, dynamic>.from(e))).toList();
    _nP = (products.map((e) => e.id).fold(0, max)) + 1;
    _nC = (customers.map((e) => e.id).fold(0, max)) + 1;
    _nCap = (captains.map((e) => e.id).fold(0, max)) + 1;
    _nO = (orders.map((e) => e.id).fold(0, max)) + 1;
  }

  Map<String, dynamic> toJson() => {
        'settings': settings.toJson(),
        'products': products.map((e) => e.toJson()).toList(),
        'customers': customers.map((e) => e.toJson()).toList(),
        'captains': captains.map((e) => e.toJson()).toList(),
        'orders': orders.map((e) => e.toJson()).toList(),
        'settlements': settlements.map((e) => e.toJson()).toList(),
      };

  void _save() {
    _persist(jsonEncode(toJson()));
    notifyListeners();
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  bool importJson(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      if (!j.containsKey('products') || !j.containsKey('customers') || !j.containsKey('captains') || !j.containsKey('orders')) {
        return false;
      }
      _load(j);
      _save();
      return true;
    } catch (_) {
      return false;
    }
  }

  void resetAll() {
    _seed();
    _save();
  }

  // ---- Auth ----
  bool login(String u, String p) {
    if (u.trim() == settings.username && p == settings.password) {
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
    settings.password = p;
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
    p.stock = next;
    _save();
    return null;
  }

  // ---- Customers ----
  void saveCustomer(Customer c) {
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
    captains.removeWhere((x) => x.id == id);
    settlements.removeWhere((x) => x.captainId == id);
    _save();
    return null;
  }

  Balances balances(int captainId) {
    double cash = 0, credit = 0;
    for (final o in orders) {
      if (o.captainId == captainId && o.status != 'cancel') {
        cash += o.goodsDue;
        credit += o.captainCredit;
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

  // ---- Orders ----
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
    }
    final o = Order(
      id: _nO++,
      date: DateTime.now(),
      customerId: customerId,
      captainId: captainId,
      items: items,
      subtotal: sub,
      delivery: delivery,
      discount: disc,
      total: goods + delivery,
      goodsTotal: goods,
      paidNow: paid,
      goodsDue: due,
      captainCredit: method == 'prepaid' ? delivery : 0,
      notes: notes,
      method: method,
    );
    for (final i in items) {
      final p = product(i.productId);
      if (p != null) p.stock = max(0, p.stock - i.qty);
    }
    orders.add(o);
    _save();
    return o;
  }

  String? changeStatus(Order o, String s) {
    if (o.status == s) return null;
    if (s == 'cancel') {
      for (final i in o.items) {
        final p = product(i.productId);
        if (p != null) p.stock += i.qty;
      }
    } else if (o.status == 'cancel') {
      for (final i in o.items) {
        final p = product(i.productId);
        if (p == null || i.qty > p.stock) return 'لا يمكن إعادة الطلب: المخزون غير كافٍ';
      }
      for (final i in o.items) {
        product(i.productId)!.stock -= i.qty;
      }
    }
    o.status = s;
    _save();
    return null;
  }

  void deleteOrder(int id) {
    final o = order(id);
    if (o == null) return;
    if (o.status != 'cancel') {
      for (final i in o.items) {
        final p = product(i.productId);
        if (p != null) p.stock += i.qty;
      }
    }
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
      : o.method == 'partial'
          ? 'مدفوع جزئياً'
          : 'الدفع عند الاستلام';
  final dueLine = o.customerDue <= 0
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
  final collect = o.method == 'prepaid'
      ? '✅ الطلب مدفوع بالكامل (الأصناف + التوصيل)\n'
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
      'طريقة الدفع: ${paymentLabel(o.method)}\n'
      '$collect'
      'ملاحظات: ${o.notes.isEmpty ? 'لا توجد' : o.notes}\n'
      'نتمنى لك توصيلاً موفقاً 🙏';
}

String _statement(AppStore s, Captain c) {
  final b = s.balances(c.id);
  return 'كشف حساب الكابتن ${c.name} — ${s.settings.storeName}\n'
      'المطلوب توريده للمحل: ${money(b.cashDue)}\n'
      'مستحق لك عند المحل (أجرة التوصيل): ${money(b.creditDue)}\n'
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
  final u = TextEditingController(text: 'admin');
  final p = TextEditingController();
  bool hide = true;

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
                  Avatar(s.settings.logoPath, size: 110, fallback: Icons.eco_rounded),
                  const SizedBox(height: 14),
                  Text(s.settings.storeName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: C.g)),
                  const Text('مكرونة مخلوطة .. طعم يرضيك', style: TextStyle(color: C.muted, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 22),
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
                  const SizedBox(height: 12),
                  const Text('بيانات البداية: admin / 1234 — يمكن تغييرها من الإعدادات.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF9AA59F))),
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
    final low = s.products.where((p) => p.active && p.stock <= p.lowStock).toList();
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
  _Line(this.p, this.qty);
}

class OrderFormPage extends StatefulWidget {
  const OrderFormPage({super.key});
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

  double get sub => cart.fold(0, (a, l) => a + l.p.price * l.qty * unitFactor(l.p.unit));
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
        cart[i].qty = (cart[i].qty + step).clamp(0, p.stock).toDouble();
      } else {
        cart.add(_Line(p, step.clamp(0, p.stock).toDouble()));
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
      _ => 'الطلب مدفوع بالكامل شامل التوصيل (${money(goods + del)}). لا يُحصَّل شيء من العميل، وتُقيَّد أجرة التوصيل ${money(del)} للكابتن على المحل',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء طلب جديد'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
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
                      items: [for (final c in s.customers) DropdownMenuItem(value: c.id, child: Text('${c.name} — ${c.phone}', overflow: TextOverflow.ellipsis))],
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
                        for (final c in s.captains.where((c) => c.available)) DropdownMenuItem(value: c.id, child: Text('${c.name} — ${c.phone}', overflow: TextOverflow.ellipsis))
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
                      Text('${money(l.p.price)} / ${unitName(l.p.unit)}', style: const TextStyle(color: C.muted, fontSize: 10)),
                      const SizedBox(height: 2),
                      Text(money(l.p.price * l.qty * unitFactor(l.p.unit)), style: const TextStyle(color: C.g2, fontWeight: FontWeight.w900)),
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
                        l.qty = q.clamp(0, l.p.stock).toDouble();
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
                  items: [for (final m in ['prepaid', 'cod', 'partial']) DropdownMenuItem(value: m, child: Text(paymentLabel(m)))],
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
    final out = p.stock <= 0;
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
      if (l.qty > l.p.stock) return toast(context, 'الكمية المطلوبة من ${l.p.name} أكبر من المخزون (${qtyText(l.p.stock)})');
      if (l.p.isPiece && l.qty != l.qty.roundToDouble()) return toast(context, 'صنف ${l.p.name} يُباع بالقطعة، أدخل رقماً صحيحاً');
    }
    final o = s.createOrder(
      customerId: customerId!,
      captainId: captainId!,
      items: [for (final l in cart) OrderItem(productId: l.p.id, name: l.p.name, price: l.p.price, unit: l.p.unit, qty: l.qty)],
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

  /// يلتقط الفاتورة كصورة ويفتح قائمة المشاركة (واتساب وغيره)
  Future<void> _shareImage(int id, String caption) async {
    try {
      final b = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 3);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw Exception('no data');
      await shareBytesFile(bd.buffer.asUint8List(), 'invoice-$id.png', 'image/png', text: caption);
    } catch (_) {
      if (mounted) toast(context, 'تعذّر إنشاء صورة الفاتورة');
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
              sumRow('حالة الدفع', o.method == 'prepaid' ? 'تم الدفع بالكامل' : o.method == 'partial' ? 'مدفوع جزئياً' : 'الدفع عند الاستلام'),
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
                  Text(due == 0 ? 'الطلب مدفوع بالكامل — لا يوجد مبلغ مطلوب' : 'المبلغ المتبقي عند الاستلام', style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 13)),
                  const SizedBox(height: 4),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(money(due), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Color(0xFF174B38)))),
                  Text(due == 0 ? 'شامل قيمة الأصناف ورسوم التوصيل' : 'يشمل المبلغ المتبقي رسوم التوصيل',
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
    final low = p.stock <= p.lowStock;
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
            Badge2('المخزون: ${qtyText(p.stock)}', low ? C.orange : C.g2),
          ]),
        ),
        const Spacer(),
        const Divider(height: 1),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(tooltip: 'المخزون', visualDensity: VisualDensity.compact, onPressed: () => _adjust(context, p), icon: const Icon(Icons.inventory_2_outlined, size: 20, color: C.g)),
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
        inp('ملاحظات', notes, lines: 2),
        LuxButton('حفظ', Icons.save_rounded, () {
          if (!form.currentState!.validate()) return;
          final c = widget.customer ?? Customer(id: 0, name: '', phone: '', address: '');
          c.name = name.text.trim();
          c.phone = phone.text.trim();
          c.address = address.text.trim();
          c.notes = notes.text.trim();
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
                const Text('مستحق للكابتن عند المحل (أجرة توصيل الطلبات المدفوعة)', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontWeight: FontWeight.w800, fontSize: 12)),
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
            const SizedBox(height: 16),
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
//  التقارير
// ====================================================================

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  DateTime? day = DateTime.now(); // null = all

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final list = s.orders.where((o) => day == null || dayKey(o.date) == dayKey(day!)).toList();
    final valid = list.where((o) => o.status != 'cancel').toList();
    final sales = valid.fold<double>(0, (a, o) => a + o.total);
    final delivery = valid.fold<double>(0, (a, o) => a + o.delivery);
    final goods = valid.fold<double>(0, (a, o) => a + o.goodsTotal);
    final unfinished = valid.where((o) => o.status != 'done').length;
    final cash = s.captains.fold<double>(0, (a, c) => a + s.balances(c.id).cashDue);

    final top = <String, double>{};
    final topQty = <String, double>{};
    for (final o in valid) {
      for (final i in o.items) {
        top[i.name] = (top[i.name] ?? 0) + i.lineTotal;
        topQty[i.name] = (topQty[i.name] ?? 0) + i.qty;
      }
    }
    final ranked = top.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxV = ranked.isEmpty ? 1.0 : ranked.first.value;

    final w = MediaQuery.of(context).size.width;
    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      LuxCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.event, color: C.g),
            const SizedBox(width: 10),
            Expanded(child: Text(day == null ? 'كل الفترات' : dayKey(day!), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
          ]),
          Wrap(children: [
            TextButton(
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: day ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                );
                if (d != null) setState(() => day = d);
              },
              child: const Text('اختيار يوم'),
            ),
            TextButton(onPressed: () => setState(() => day = DateTime.now()), child: const Text('اليوم')),
            TextButton(onPressed: () => setState(() => day = null), child: const Text('الكل')),
          ]),
        ]),
      ),
      GridView.count(
        crossAxisCount: w > 760 ? 3 : 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: w > 760 ? 2.8 : 1.7,
        children: [
          StatTile('إجمالي المبيعات', money(sales), Icons.payments_rounded, C.g2),
          StatTile('عدد الطلبات', '${valid.length}', Icons.shopping_bag_rounded, C.gold),
          StatTile('قيمة الأصناف', money(goods), Icons.restaurant_rounded, C.blue),
          StatTile('رسوم التوصيل', money(delivery), Icons.delivery_dining_rounded, C.purple),
          StatTile('طلبات غير مكتملة', '$unfinished', Icons.hourglass_bottom_rounded, C.orange),
          StatTile('مستحق على الكباتن', money(cash), Icons.account_balance_wallet_rounded, C.red),
        ],
      ),
      const SizedBox(height: 18),
      const PageHead('الأكثر مبيعاً'),
      if (ranked.isEmpty) const LuxCard(child: Empty('لا توجد بيانات', icon: Icons.bar_chart)),
      for (final e in ranked.take(8))
        LuxCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w800))),
              Text(money(e.value), style: const TextStyle(color: C.g2, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: e.value / maxV, minHeight: 8, color: C.gold, backgroundColor: C.g.withOpacity(.08)),
            ),
            const SizedBox(height: 4),
            Text('الكمية: ${qtyText(topQty[e.key] ?? 0)}', style: const TextStyle(color: C.muted, fontSize: 11)),
          ]),
        ),
    ]);
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
  late final pass = TextEditingController(text: s.settings.password);

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
              inp('كلمة المرور', pass, obscure: true),
              LuxButton('تحديث بيانات الدخول', Icons.lock_outline, () {
                if (user.text.trim().isEmpty || pass.text.isEmpty) return toast(context, 'أدخل اسم المستخدم وكلمة المرور');
                s.updateCredentials(user.text.trim(), pass.text);
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

  void _export() {
    final txt = s.exportJson();
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
    final ok = s.importJson(t);
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
            onPressed: () {
              final ok = s.importJson(c.text);
              Navigator.pop(ctx);
              toast(context, ok ? 'تم الاستيراد بنجاح' : 'نص غير صالح');
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
  final store = AppStore()..init(raw);
  runApp(StoreScope(notifier: store, child: const SaladBarApp()));
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
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: s.loggedIn ? const HomeShell() : const LoginScreen(),
    );
  }
}
