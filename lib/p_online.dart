part of 'main.dart';

// ====================================================================
//  القائمة الإلكترونية: الإعدادات + QR + الطلبات الواردة
// ====================================================================

class OnlineSettingsPage extends StatefulWidget {
  const OnlineSettingsPage({super.key});
  @override
  State<OnlineSettingsPage> createState() => _OnlineSettingsPageState();
}

class _OnlineSettingsPageState extends State<OnlineSettingsPage> {
  late final AppStore s = context.read<AppStore>();
  String _t(double v) => qtyText(v).replaceAll(',', '');
  late final url = TextEditingController(text: s.settings.menuUrl);
  late final fee = TextEditingController(text: _t(s.settings.onlineFee));
  late final minO = TextEditingController(text: _t(s.settings.minOrder));
  late final note = TextEditingController(text: s.settings.onlineNote);
  final qrKey = GlobalKey();
  bool busy = false;

  Future<void> _shareQr(String link) async {
    try {
      final b = qrKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 3);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw Exception('no data');
      await shareBytesFile(bd.buffer.asUint8List(), 'menu-qr.png', 'image/png', text: 'امسح الرمز لطلبك من ${s.settings.storeName}\n$link');
    } catch (_) {
      if (mounted) toast(context, 'تعذّر إنشاء صورة الرمز');
    }
  }

  void _editPay([Map<String, dynamic>? m]) => showSheet(context, (_) => _PaySheet(method: m));

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppStore>();
    final cfg = st.settings;
    final link = st.menuLink;
    return Scaffold(
      appBar: AppBar(title: const Text('الطلب الإلكتروني'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
            if (!cloud.isOwner || !cloud.configured)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: C.orange.withOpacity(.12), borderRadius: BorderRadius.circular(14)),
                child: const Text('فعّل الربط السحابي أولاً من الإعدادات ← الربط السحابي، فالقائمة تعمل عبر Firebase.', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, height: 1.6)),
              ),
            LuxCard(
              child: Column(children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: C.g2,
                  title: const Text('تفعيل القائمة الإلكترونية', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('يظهر للعملاء قائمة أصنافك وأسعارها ويطلبون منها', style: TextStyle(fontSize: 11)),
                  value: cfg.onlineEnabled,
                  onChanged: (v) => st.updateOnline(enabled: v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: C.g2,
                  title: const Text('نستقبل الطلبات الآن', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('أطفئه عند إغلاق المحل ليظهر للعميل "مغلق"', style: TextStyle(fontSize: 11)),
                  value: cfg.onlineOpen,
                  onChanged: cfg.onlineEnabled ? (v) => st.updateOnline(open: v) : null,
                ),
              ]),
            ),
            const PageHead('رابط صفحة القائمة'),
            LuxCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('الصفحة ملف واحد (index.html) ترفعه مرة واحدة على GitHub Pages، ثم تضع هنا عنوانه. الخطوات في ملف menu_setup.md.',
                    style: TextStyle(color: C.muted, fontSize: 12, height: 1.6)),
                const SizedBox(height: 10),
                TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'عنوان الصفحة', hintText: 'https://اسمك.github.io/menu/')),
                const SizedBox(height: 10),
                LuxButton('حفظ العنوان', Icons.save_rounded, () async {
                  await st.updateOnline(url: url.text);
                  if (mounted) toast(context, 'تم حفظ العنوان');
                }),
              ]),
            ),
            if (cfg.onlineEnabled && link.isNotEmpty) ...[
              const PageHead('رابط العملاء و QR'),
              LuxCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: RepaintBoundary(
                      key: qrKey,
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(cfg.storeName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: C.g)),
                          const SizedBox(height: 2),
                          const Text('امسح الرمز واطلب مباشرة', style: TextStyle(color: C.muted, fontWeight: FontWeight.w700, fontSize: 12)),
                          const SizedBox(height: 10),
                          QrImageView(data: link, version: QrVersions.auto, size: 230, backgroundColor: Colors.white),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(link, style: const TextStyle(fontSize: 11, color: C.muted)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(onPressed: () => copyText(context, link, 'تم نسخ الرابط'), icon: const Icon(Icons.copy_rounded), label: const Text('نسخ الرابط')),
                    OutlinedButton.icon(onPressed: () => Share.share('اطلب من ${cfg.storeName} 🌿\n$link'), icon: const Icon(Icons.share_rounded), label: const Text('مشاركة الرابط')),
                    OutlinedButton.icon(onPressed: () => _shareQr(link), icon: const Icon(Icons.qr_code_2_rounded), label: const Text('مشاركة صورة QR')),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
                        } catch (_) {
                          if (mounted) toast(context, 'تعذّر فتح الرابط');
                        }
                      },
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('فتح للمعاينة'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        if (!await confirmDialog(context, 'تغيير مفتاح الرابط؟ ستتوقف الروابط وصور QR السابقة عن استقبال الطلبات، وعليك نشر الجديد.', yes: 'تغيير')) return;
                        await st.rotateMenuKey();
                        if (mounted) toast(context, 'تم إنشاء رابط جديد');
                      },
                      icon: const Icon(Icons.autorenew_rounded, color: C.red),
                      label: const Text('تغيير المفتاح', style: TextStyle(color: C.red)),
                    ),
                  ]),
                ]),
              ),
            ] else if (cfg.onlineEnabled)
              const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('أدخل عنوان الصفحة أعلاه ليظهر الرابط و QR.', style: TextStyle(color: C.orange, fontWeight: FontWeight.w800))),
            const PageHead('إعدادات الطلب'),
            LuxCard(
              child: Column(children: [
                inp('رسوم التوصيل الافتراضية (YER)', fee, type: numType),
                inp('الحد الأدنى للطلب (YER) — 0 لعدم التحديد', minO, type: numType),
                inp('رسالة تظهر للعملاء (اختياري)', note, lines: 2),
                LuxButton('حفظ ونشر', Icons.cloud_upload_rounded, () async {
                  await st.updateOnline(fee: num2(fee.text), minOrder: num2(minO.text), note: note.text);
                  if (mounted) toast(context, 'تم الحفظ والنشر');
                }),
              ]),
            ),
            PageHead('طرق الدفع', trailing: FilledButton.icon(onPressed: _editPay, icon: const Icon(Icons.add), label: const Text('إضافة'))),
            for (final m in cfg.payMethods)
              LuxCard(
                accent: m['kind'] == 'cod' ? C.orange : C.g2,
                onTap: () => _editPay(m),
                child: Row(children: [
                  Icon(m['kind'] == 'cod' ? Icons.payments_rounded : Icons.account_balance_rounded, color: m['kind'] == 'cod' ? C.orange : C.g2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${m['title']}', style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text(m['kind'] == 'cod' ? 'يدفع للكابتن عند الاستلام' : 'تحويل/محفظة مسبق${m['needRef'] == true ? ' • يلزم رقم العملية' : ''}',
                          style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  const Icon(Icons.edit_outlined, size: 18, color: C.muted),
                ]),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      final ok = await st.publishMenuNow(force: true);
                      if (!mounted) return;
                      setState(() => busy = false);
                      toast(context, ok ? 'تم نشر القائمة ✓' : 'تعذّر النشر — تأكد من الربط السحابي وتحديث القواعد');
                    },
              icon: const Icon(Icons.publish_rounded),
              label: Text(busy ? 'جاري النشر...' : 'نشر القائمة الآن'),
            ),
            if (st.menuPublishedAt != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('آخر نشر: ${dateText(st.menuPublishedAt!)}', textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 11))),
            const SizedBox(height: 4),
            const Text('تتحدث القائمة تلقائياً عند تغيير الأصناف أو الأسعار أو التوفر. الأصناف غير المتاحة أو الناقصة تظهر للعميل "غير متوفر".',
                textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 11, height: 1.6)),
          ]),
        ),
      ),
    );
  }
}

class _PaySheet extends StatefulWidget {
  final Map<String, dynamic>? method;
  const _PaySheet({this.method});
  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  late final title = TextEditingController(text: '${widget.method?['title'] ?? ''}');
  late final info = TextEditingController(text: '${widget.method?['info'] ?? ''}');
  late String kind = '${widget.method?['kind'] ?? 'prepaid'}';
  late bool needRef = widget.method?['needRef'] == true;

  @override
  Widget build(BuildContext context) {
    final st = context.read<AppStore>();
    final edit = widget.method != null;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(edit ? 'تعديل طريقة الدفع' : 'إضافة طريقة دفع', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
      const SizedBox(height: 14),
      inp('الاسم الظاهر للعميل (مثال: تحويل كريمي)', title),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: kind,
          decoration: const InputDecoration(labelText: 'النوع'),
          items: const [
            DropdownMenuItem(value: 'cod', child: Text('الدفع عند الاستلام')),
            DropdownMenuItem(value: 'prepaid', child: Text('تحويل / محفظة (يدفع مسبقاً)')),
          ],
          onChanged: (v) => setState(() => kind = v!),
        ),
      ),
      inp('التعليمات للعميل (رقم الحساب، اسم المستفيد...)', info, lines: 3),
      if (kind != 'cod')
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeColor: C.g2,
          title: const Text('إلزام العميل بإدخال رقم العملية أو الإيصال', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          value: needRef,
          onChanged: (v) => setState(() => needRef = v),
        ),
      const SizedBox(height: 6),
      LuxButton('حفظ', Icons.save_rounded, () async {
        if (title.text.trim().isEmpty) return toast(context, 'اكتب اسم الطريقة');
        final list = [for (final m in st.settings.payMethods) Map<String, dynamic>.from(m)];
        final entry = {
          'id': widget.method?['id'] ?? 'm${DateTime.now().millisecondsSinceEpoch}',
          'title': title.text.trim(),
          'kind': kind,
          'info': info.text.trim(),
          'needRef': kind != 'cod' && needRef,
        };
        final i = list.indexWhere((m) => m['id'] == entry['id']);
        if (i >= 0) {
          list[i] = entry;
        } else {
          list.add(entry);
        }
        Navigator.pop(context);
        await st.updateOnline(pays: list);
      }),
      if (edit && st.settings.payMethods.length > 1) ...[
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () async {
            if (!await confirmDialog(context, 'حذف طريقة الدفع هذه؟', yes: 'حذف')) return;
            final list = [for (final m in st.settings.payMethods) if (m['id'] != widget.method!['id']) Map<String, dynamic>.from(m)];
            if (context.mounted) Navigator.pop(context);
            await st.updateOnline(pays: list);
          },
          icon: const Icon(Icons.delete_outline_rounded, color: C.red),
          label: const Text('حذف', style: TextStyle(color: C.red)),
        ),
      ],
      const SizedBox(height: 8),
    ]);
  }
}

// ---------------- الطلبات الواردة ----------------

class WebOrdersPage extends StatefulWidget {
  const WebOrdersPage({super.key});
  @override
  State<WebOrdersPage> createState() => _WebOrdersPageState();
}

class _WebOrdersPageState extends State<WebOrdersPage> {
  @override
  void initState() {
    super.initState();
    context.read<AppStore>().refreshWeb();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final list = s.webOrders;
    return Scaffold(
      appBar: AppBar(title: Text('الطلبات الواردة (${list.length})'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: RefreshIndicator(
            onRefresh: s.refreshWeb,
            child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(14), children: [
              if (list.isEmpty) const Empty('لا توجد طلبات واردة الآن', icon: Icons.shopping_basket_outlined),
              for (final w in list) _card(context, s, w),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, AppStore s, Map<String, dynamic> w) {
    final cm = Map<String, dynamic>.from((w['customer'] as Map?) ?? {});
    final pm = Map<String, dynamic>.from((w['payment'] as Map?) ?? {});
    final at = DateTime.tryParse('${w['createdAt']}')?.toLocal();
    final tot = s.webSubtotal(w);
    final phone = '${cm['phone'] ?? ''}';
    final lat = cm['lat'] is num ? (cm['lat'] as num).toDouble() : null;
    final lng = cm['lng'] is num ? (cm['lng'] as num).toDouble() : null;
    final receipt = '${pm['receipt'] ?? ''}';
    final its = asMapList(w['items']);
    return LuxCard(
      accent: C.orange,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.person_rounded, color: C.g),
          const SizedBox(width: 6),
          Expanded(child: Text('${cm['name'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
          if (at != null) Text(dateText(at), style: const TextStyle(color: C.muted, fontSize: 11)),
        ]),
        const SizedBox(height: 4),
        Text(phone, style: const TextStyle(color: C.muted, fontWeight: FontWeight.w700)),
        Text('${cm['address'] ?? ''}', style: const TextStyle(fontSize: 12.5)),
        if ('${cm['notes'] ?? ''}'.isNotEmpty) Text('ملاحظات: ${cm['notes']}', style: const TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
          child: Text(
            its.map((i) {
              final pr = s.product((i['pid'] as num?)?.toInt() ?? 0);
              return '• ${pr?.name ?? '${i['name']} ⚠ غير موجود'} × ${qtyText(_d(i['qty']))}${pr == null ? '' : ' = ${money(pr.price * _d(i['qty']) * unitFactor(pr.unit))}'}';
            }).join('\n'),
            style: const TextStyle(fontSize: 12.5, height: 1.7),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          const Text('مجموع الأصناف بأسعارك الحالية', style: TextStyle(fontSize: 12)),
          const Spacer(),
          Text(money(tot.sub), style: const TextStyle(fontWeight: FontWeight.w900, color: C.g2)),
        ]),
        if (tot.missing.isNotEmpty) Text('⚠ أصناف غير موجودة الآن: ${tot.missing.join('، ')}', style: const TextStyle(color: C.red, fontSize: 11.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Badge2('${pm['title'] ?? 'دفع'}', pm['kind'] == 'cod' ? C.orange : C.g2),
          if ('${pm['ref'] ?? ''}'.isNotEmpty) Badge2('مرجع: ${pm['ref']}', C.blue),
          if (lat != null) Badge2('📍 موقع', C.blue),
        ]),
        const Divider(height: 18),
        Wrap(children: [
          if (phone.isNotEmpty) TextButton.icon(onPressed: () => callPhone(context, phone), icon: const Icon(Icons.call_rounded, size: 18, color: C.blue), label: const Text('اتصال', style: TextStyle(color: C.blue))),
          if (phone.isNotEmpty) TextButton.icon(onPressed: () => sendWa(context, phone, 'مرحباً ${cm['name'] ?? ''} 🌿 بخصوص طلبك من ${s.settings.storeName}'), icon: const Icon(Icons.chat_rounded, size: 18, color: C.wa), label: const Text('واتساب', style: TextStyle(color: C.wa))),
          if (lat != null) TextButton.icon(onPressed: () => openNavigation(context, lat: lat, lng: lng), icon: const Icon(Icons.navigation_rounded, size: 18, color: C.purple), label: const Text('الموقع', style: TextStyle(color: C.purple))),
          if (receipt.startsWith('data:'))
            TextButton.icon(
              onPressed: () {
                final bytes = _decodeImg(receipt);
                if (bytes == null) return toast(context, 'تعذّر عرض الإيصال');
                showDialog(context: context, builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(bytes))));
              },
              icon: const Icon(Icons.receipt_rounded, size: 18),
              label: const Text('الإيصال'),
            ),
        ]),
        Row(children: [
          Expanded(child: LuxButton('قبول', Icons.check_circle_rounded, () => showSheet(context, (_) => _AcceptSheet(web: w)), colors: const [Color(0xFF1F6F43), C.g2])),
          const SizedBox(width: 8),
          Expanded(
            child: LuxButton('رفض', Icons.cancel_rounded, () async {
              final c = TextEditingController();
              final go = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                  title: const Text('رفض الطلب'),
                  content: TextField(controller: c, decoration: const InputDecoration(labelText: 'السبب الذي يراه العميل', hintText: 'مثال: الصنف غير متوفر حالياً')),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
                    FilledButton(style: FilledButton.styleFrom(backgroundColor: C.red), onPressed: () => Navigator.pop(ctx, true), child: const Text('رفض')),
                  ],
                ),
              );
              if (go != true) return;
              final ok = await s.rejectWebOrder('${w['_key']}', c.text.trim().isEmpty ? 'تعذّر قبول الطلب حالياً' : c.text.trim());
              if (context.mounted) toast(context, ok ? 'تم رفض الطلب وإبلاغ العميل' : 'تعذّر الإرسال — تحقق من الاتصال');
            }, colors: const [Color(0xFFA4202C), C.red]),
          ),
        ]),
      ]),
    );
  }
}

class _AcceptSheet extends StatefulWidget {
  final Map<String, dynamic> web;
  const _AcceptSheet({required this.web});
  @override
  State<_AcceptSheet> createState() => _AcceptSheetState();
}

class _AcceptSheetState extends State<_AcceptSheet> {
  int? captainId;
  late final TextEditingController fee;
  bool paidOk = false, busy = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppStore>();
    final w = widget.web;
    final f = w['delivery'] is num ? (w['delivery'] as num).toDouble() : s.settings.onlineFee;
    fee = TextEditingController(text: qtyText(f).replaceAll(',', ''));
    final av = s.captains.where((c) => c.available).toList();
    if (av.length == 1) captainId = av.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final w = widget.web;
    final pm = Map<String, dynamic>.from((w['payment'] as Map?) ?? {});
    final prepaid = pm['kind'] != null && pm['kind'] != 'cod';
    final tot = s.webSubtotal(w);
    final f = num2(fee.text);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('قبول الطلب وإسناده', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: C.g)),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        value: captainId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'الكابتن', prefixIcon: Icon(Icons.two_wheeler_rounded)),
        items: [for (final c in s.captains.where((c) => c.available)) DropdownMenuItem(value: c.id, child: Text('${c.name} — ${c.phone}', overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() => captainId = v),
      ),
      const SizedBox(height: 12),
      TextField(controller: fee, keyboardType: numType, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'رسوم التوصيل (YER)')),
      if (prepaid) ...[
        const SizedBox(height: 8),
        Text('العميل اختار: ${pm['title']}${'${pm['ref'] ?? ''}'.isEmpty ? '' : ' • المرجع ${pm['ref']}'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeColor: C.g2,
          title: const Text('تأكدت من وصول المبلغ', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('إن لم تفعّله يُسجَّل الطلب "عند الاستلام"', style: TextStyle(fontSize: 11)),
          value: paidOk,
          onChanged: (v) => setState(() => paidOk = v),
        ),
      ],
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: C.gold.withOpacity(.12), borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          Row(children: [const Text('الأصناف'), const Spacer(), Text(money(tot.sub), style: const TextStyle(fontWeight: FontWeight.w900))]),
          Row(children: [const Text('التوصيل'), const Spacer(), Text(money(f), style: const TextStyle(fontWeight: FontWeight.w900))]),
          const Divider(),
          Row(children: [const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.w900)), const Spacer(), Text(money(tot.sub + f), style: const TextStyle(fontWeight: FontWeight.w900, color: C.g, fontSize: 16))]),
        ]),
      ),
      const SizedBox(height: 12),
      LuxButton(busy ? 'جاري الإنشاء...' : 'قبول وإنشاء الطلب', Icons.check_circle_rounded, busy
          ? null
          : () async {
              if (captainId == null) return toast(context, 'اختر الكابتن');
              setState(() => busy = true);
              final r = await s.acceptWebOrder(w, captainId: captainId!, fee: f, paidOk: paidOk);
              if (!mounted) return;
              setState(() => busy = false);
              if (r.error != null) return toast(context, r.error!);
              final o = r.order!;
              Navigator.pop(context);
              toast(context, 'تم إنشاء الطلب #${o.id} ✓');
              final cu = s.customer(o.customerId);
              if (cu != null && context.mounted) {
                final go = await confirmDialog(context, 'إرسال تأكيد للعميل عبر واتساب مع رابط التتبّع؟', yes: 'إرسال');
                if (go && context.mounted) {
                  final link = s.trackLink('${w['_key']}');
                  await sendWa(context, cu.phone,
                      'مرحباً ${cu.name} 🌿\nتم قبول طلبك من ${s.settings.storeName} ✅\nرقم الفاتورة: #${o.id}\nالإجمالي: ${money(o.total)} (شامل التوصيل ${money(o.delivery)})\n${link.isEmpty ? '' : 'تتبّع طلبك: $link\n'}شكراً لثقتك ❤️');
                }
              }
            }),
      const SizedBox(height: 8),
    ]);
  }
}
