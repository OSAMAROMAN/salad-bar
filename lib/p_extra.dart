part of 'main.dart';

// ====================================================================
//  صفحات إضافية: التقارير، الإقفال اليومي، حساب العميل، الجرد
// ====================================================================

String _csv(List<List<String>> rows) => rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');

Future<void> _shareCsv(BuildContext c, List<List<String>> rows, String name) async {
  try {
    await shareBytesFile(Uint8List.fromList(utf8.encode('\uFEFF${_csv(rows)}')), name, 'text/csv');
  } catch (_) {
    if (c.mounted) toast(c, 'تعذّر تصدير الملف');
  }
}

// ---------------- التقارير ----------------

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String preset = 'today';
  DateTimeRange? custom;

  static const _names = {
    'today': 'اليوم',
    'yesterday': 'أمس',
    'week': 'آخر 7 أيام',
    'month': 'هذا الشهر',
    'custom': 'فترة محددة',
    'all': 'الكل',
  };

  (DateTime?, DateTime?) _range() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    switch (preset) {
      case 'today':
        return (today, today);
      case 'yesterday':
        final y = today.subtract(const Duration(days: 1));
        return (y, y);
      case 'week':
        return (today.subtract(const Duration(days: 6)), today);
      case 'month':
        return (DateTime(n.year, n.month, 1), today);
      case 'custom':
        return custom == null ? (today, today) : (custom!.start, custom!.end);
      default:
        return (null, null);
    }
  }

  bool _in(DateTime d, DateTime? a, DateTime? b) {
    final x = DateTime(d.year, d.month, d.day);
    return (a == null || !x.isBefore(a)) && (b == null || !x.isAfter(b));
  }

  String _label(DateTime? a, DateTime? b) => a == null ? 'الكل' : (dayKey(a) == dayKey(b!) ? dayKey(a) : '${dayKey(a)} إلى ${dayKey(b)}');

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final (from, to) = _range();
    final valid = s.orders.where((o) => o.status != 'cancel' && _in(o.date, from, to)).toList();
    final sales = valid.fold<double>(0, (a, o) => a + o.total);
    final goods = valid.fold<double>(0, (a, o) => a + o.goodsTotal);
    final delivery = valid.fold<double>(0, (a, o) => a + o.delivery);
    final discount = valid.fold<double>(0, (a, o) => a + o.discount);
    final credit = valid.fold<double>(0, (a, o) => a + o.debt);
    final unfinished = valid.where((o) => o.status != 'done').length;
    final cashOnCaptains = s.captains.fold<double>(0, (a, c) => a + s.balances(c.id).cashDue);
    final buys = s.purchases.where((p) => p.closed && _in(p.date, from, to)).fold<double>(0, (a, p) => a + p.actual);
    final debts = s.customers.fold<double>(0, (a, c) => a + max(0, s.customerDebt(c.id)));

    final itemV = <String, double>{};
    final itemQ = <String, double>{};
    final capN = <int, int>{}, capDone = <int, int>{};
    final capFee = <int, double>{}, capCollect = <int, double>{};
    for (final o in valid) {
      for (final i in o.items) {
        itemV[i.name] = (itemV[i.name] ?? 0) + i.lineTotal;
        itemQ[i.name] = (itemQ[i.name] ?? 0) + i.qty;
      }
      capN[o.captainId] = (capN[o.captainId] ?? 0) + 1;
      capFee[o.captainId] = (capFee[o.captainId] ?? 0) + o.delivery;
      if (o.status == 'done') {
        capDone[o.captainId] = (capDone[o.captainId] ?? 0) + 1;
        capCollect[o.captainId] = (capCollect[o.captainId] ?? 0) + o.customerDue;
      }
    }
    final ranked = itemV.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxV = ranked.isEmpty ? 1.0 : ranked.first.value;
    final w = MediaQuery.of(context).size.width;

    return ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 100), children: [
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final e in _names.entries)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text(e.value),
                selected: preset == e.key,
                selectedColor: C.g,
                showCheckmark: false,
                labelStyle: TextStyle(color: preset == e.key ? Colors.white : C.text, fontWeight: FontWeight.w800, fontSize: 12),
                onSelected: (_) async {
                  if (e.key == 'custom') {
                    final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                      initialDateRange: custom,
                    );
                    if (r == null) return;
                    setState(() {
                      custom = r;
                      preset = 'custom';
                    });
                  } else {
                    setState(() => preset = e.key);
                  }
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Text('الفترة: ${_label(from, to)}', style: const TextStyle(color: C.muted, fontWeight: FontWeight.w800, fontSize: 12)),
      const SizedBox(height: 10),
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
          StatTile('الخصومات', money(discount), Icons.sell_rounded, C.orange),
          StatTile('مبيعات آجلة', money(credit), Icons.menu_book_rounded, C.red),
          StatTile('مشتريات خارجية', money(buys), Icons.shopping_cart_checkout_rounded, C.blue),
          StatTile('طلبات غير مكتملة', '$unfinished', Icons.hourglass_bottom_rounded, C.orange),
          StatTile('عند الكباتن للمحل', money(cashOnCaptains), Icons.account_balance_wallet_rounded, C.red),
          StatTile('ديون العملاء', money(debts), Icons.people_alt_rounded, C.red),
        ],
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: LuxButton('إقفال يوم', Icons.lock_clock_rounded, () => Navigator.push(context, MaterialPageRoute(builder: (_) => ClosePage(day: to ?? DateTime.now()))),
              colors: const [Color(0xFFB68B24), C.gold], fg: C.dark),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _shareCsv(context, [
              ['رقم الطلب', 'التاريخ', 'العميل', 'الهاتف', 'الكابتن', 'الحالة', 'الدفع', 'الأصناف', 'الخصم', 'التوصيل', 'الإجمالي', 'المدفوع', 'المطلوب عند الاستلام'],
              for (final o in valid.reversed)
                [
                  '${o.id}',
                  dateText(o.date),
                  s.customer(o.customerId)?.name ?? '',
                  s.customer(o.customerId)?.phone ?? '',
                  s.captain(o.captainId)?.name ?? '',
                  statusLabel(o.status),
                  paymentLabel(o.method),
                  o.items.map((i) => '${i.name}×${qtyText(i.qty)}').join(' | '),
                  qtyText(o.discount),
                  qtyText(o.delivery),
                  qtyText(o.total),
                  qtyText(o.paidAmount),
                  qtyText(o.customerDue),
                ],
            ], 'orders-${_label(from, to).replaceAll(' ', '_')}.csv'),
            icon: const Icon(Icons.table_view_rounded),
            label: const Text('تصدير الطلبات (Excel)'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _shareCsv(context, [
              ['الصنف', 'الكمية', 'المبيعات'],
              for (final e in ranked) [e.key, qtyText(itemQ[e.key] ?? 0), qtyText(e.value)],
            ], 'items-${_label(from, to).replaceAll(' ', '_')}.csv'),
            icon: const Icon(Icons.table_chart_rounded),
            label: const Text('تصدير الأصناف'),
          ),
        ),
      ]),
      const SizedBox(height: 18),
      const PageHead('حسب الكابتن'),
      if (capN.isEmpty) const LuxCard(child: Empty('لا توجد بيانات', icon: Icons.two_wheeler_rounded)),
      for (final id in capN.keys)
        LuxCard(
          accent: C.purple,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.captain(id)?.name ?? 'كابتن #$id', style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('الطلبات: ${capN[id]} • المسلَّمة: ${capDone[id] ?? 0}', style: const TextStyle(fontSize: 12)),
            Text('أجور التوصيل: ${money(capFee[id] ?? 0)}', style: const TextStyle(fontSize: 12)),
            Text('محصَّل من العملاء (مسلَّم): ${money(capCollect[id] ?? 0)}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
      const SizedBox(height: 10),
      const PageHead('الأكثر مبيعاً'),
      if (ranked.isEmpty) const LuxCard(child: Empty('لا توجد بيانات', icon: Icons.bar_chart)),
      for (final e in ranked.take(15))
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
            Text('الكمية: ${qtyText(itemQ[e.key] ?? 0)}', style: const TextStyle(color: C.muted, fontSize: 11)),
          ]),
        ),
    ]);
  }
}

// ---------------- الإقفال اليومي ----------------

class ClosePage extends StatefulWidget {
  final DateTime day;
  const ClosePage({super.key, required this.day});
  @override
  State<ClosePage> createState() => _ClosePageState();
}

class _ClosePageState extends State<ClosePage> {
  late DateTime day = widget.day;
  final counted = TextEditingController();
  final note = TextEditingController();
  String? loadedFor;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final key = dayKey(day);
    final valid = s.orders.where((o) => o.status != 'cancel' && dayKey(o.date) == key).toList();
    final sales = valid.fold<double>(0, (a, o) => a + o.total);
    final direct = valid.where((o) => o.method == 'prepaid' || o.method == 'partial').fold<double>(0, (a, o) => a + o.paidAmount);
    final capIn = s.settlements.where((x) => dayKey(x.date) == key && x.type == 'captain_paid').fold<double>(0, (a, x) => a + x.amount);
    final capOut = s.settlements.where((x) => dayKey(x.date) == key && x.type == 'owner_paid').fold<double>(0, (a, x) => a + x.amount);
    final custPay = s.customerPayments.where((x) => dayKey(x.date) == key).fold<double>(0, (a, x) => a + x.amount);
    final given = s.purchases.where((x) => dayKey(x.date) == key).fold<double>(0, (a, x) => a + x.given);
    final expected = direct + capIn + custPay - capOut - given;
    final prev = s.closes.where((c) => c.day == key).firstOrNull;
    if (loadedFor != key) {
      loadedFor = key;
      counted.text = prev == null ? '' : qtyText(prev.actual).replaceAll(',', '');
      note.text = prev?.note ?? '';
    }
    final actual = num2(counted.text);
    final diff = actual - expected;
    final unfinished = valid.where((o) => o.status != 'done').length;
    final caps = <int>{for (final o in valid) o.captainId};

    String summary() => 'إقفال يوم $key — ${s.settings.storeName}\n'
        'المبيعات: ${money(sales)} (${valid.length} طلب)\n'
        'قبض مباشر بالمحل: ${money(direct)}\n'
        'توريد كباتن: ${money(capIn)}\n'
        'دفعات عملاء آجل: ${money(custPay)}\n'
        'مدفوع للكباتن: ${money(capOut)}\n'
        'عهد مشتريات: ${money(given)}\n'
        'المتوقع بالصندوق: ${money(expected)}\n'
        'الفعلي: ${money(actual)}\n'
        'الفرق: ${money(diff)}';

    Widget row(String a, String b, {Color? c, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(a, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w900 : FontWeight.w600))),
            Text(b, style: TextStyle(fontWeight: FontWeight.w900, color: c, fontSize: bold ? 16 : 13)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text('إقفال يوم $key'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: day, firstDate: DateTime(2020), lastDate: DateTime.now());
                if (d != null) setState(() => day = d);
              },
              icon: const Icon(Icons.event),
              label: Text('تغيير اليوم ($key)'),
            ),
            const SizedBox(height: 12),
            LuxCard(
              child: Column(children: [
                const PageHead('ملخص المبيعات'),
                row('عدد الطلبات', '${valid.length}'),
                row('إجمالي المبيعات', money(sales), bold: true),
                row('طلبات غير مكتملة', '$unfinished', c: unfinished > 0 ? C.orange : C.g2),
              ]),
            ),
            LuxCard(
              child: Column(children: [
                const PageHead('حركة النقد المتوقعة'),
                row('قبض مباشر بالمحل (محاسب/دفعة مقدمة)', money(direct), c: C.g2),
                row('+ توريد الكباتن للمحل', money(capIn), c: C.g2),
                row('+ دفعات عملاء الآجل', money(custPay), c: C.g2),
                row('− مدفوع للكباتن', money(capOut), c: C.red),
                row('− عهد مشتريات خارجية', money(given), c: C.red),
                const Divider(),
                row('المتوقع بالصندوق', money(expected), bold: true),
              ]),
            ),
            LuxCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const PageHead('الجرد الفعلي'),
                TextField(controller: counted, keyboardType: numType, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'النقد الفعلي بالصندوق (YER)')),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: (diff == 0 ? C.g2 : (diff > 0 ? C.blue : C.red)).withOpacity(.1), borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    counted.text.trim().isEmpty ? 'أدخل المبلغ الفعلي لمعرفة الفرق' : (diff == 0 ? 'مطابق ✅' : (diff > 0 ? 'زيادة: ${money(diff)}' : 'عجز: ${money(-diff)}')),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظات الإقفال')),
              ]),
            ),
            if (caps.isNotEmpty)
              LuxCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const PageHead('الكباتن'),
                  for (final id in caps)
                    Builder(builder: (_) {
                      final os = valid.where((o) => o.captainId == id).toList();
                      final b = s.balances(id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.captain(id)?.name ?? '#$id', style: const TextStyle(fontWeight: FontWeight.w900)),
                          Text('طلبات: ${os.length} • مسلَّمة: ${os.where((o) => o.status == 'done').length} • أجور: ${money(os.fold<double>(0, (a, o) => a + o.delivery))}',
                              style: const TextStyle(fontSize: 12, color: C.muted)),
                          Text('عليه للمحل: ${money(b.cashDue)} • له: ${money(b.creditDue)}', style: const TextStyle(fontSize: 12)),
                        ]),
                      );
                    }),
                ]),
              ),
            const SizedBox(height: 4),
            LuxButton(prev == null ? 'حفظ الإقفال' : 'تحديث الإقفال', Icons.lock_rounded, () {
              if (counted.text.trim().isEmpty) return toast(context, 'أدخل النقد الفعلي أولاً');
              s.saveClose(DayClose(id: DateTime.now().millisecondsSinceEpoch, day: key, expected: expected, actual: actual, note: note.text.trim(), at: DateTime.now()));
              toast(context, 'تم حفظ إقفال اليوم ✓');
            }),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Share.share(summary()),
              icon: const Icon(Icons.share_rounded),
              label: const Text('مشاركة الملخص'),
            ),
            const SizedBox(height: 16),
            const PageHead('إقفالات سابقة'),
            if (s.closes.isEmpty) const Empty('لا توجد إقفالات', icon: Icons.history_rounded),
            for (final c in (s.closes.toList()..sort((a, b) => b.day.compareTo(a.day))).take(10))
              LuxCard(
                accent: c.diff == 0 ? C.g2 : (c.diff > 0 ? C.blue : C.red),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.day, style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text('متوقع ${money(c.expected)} • فعلي ${money(c.actual)}', style: const TextStyle(fontSize: 11, color: C.muted)),
                    ]),
                  ),
                  Text(c.diff == 0 ? 'مطابق' : (c.diff > 0 ? '+${money(c.diff)}' : '-${money(-c.diff)}'),
                      style: TextStyle(fontWeight: FontWeight.w900, color: c.diff == 0 ? C.g2 : (c.diff > 0 ? C.blue : C.red))),
                ]),
              ),
            const SizedBox(height: 30),
          ]),
        ),
      ),
    );
  }
}

// ---------------- حساب العميل (الآجل) ----------------

class CustomerPage extends StatelessWidget {
  final int customerId;
  const CustomerPage({super.key, required this.customerId});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final c = s.customer(customerId);
    if (c == null) return const Scaffold(body: Empty('العميل غير موجود'));
    final debt = s.customerDebt(customerId);
    final os = s.orders.where((o) => o.customerId == customerId).toList()..sort((a, b) => b.date.compareTo(a.date));
    final pays = s.customerPayments.where((x) => x.customerId == customerId).toList()..sort((a, b) => b.date.compareTo(a.date));
    final total = os.where((o) => o.status != 'cancel').fold<double>(0, (a, o) => a + o.total);

    return Scaffold(
      appBar: AppBar(title: Text(c.name), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: C.brandGradient, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.gold.withOpacity(.7))),
              child: Column(children: [
                Text(c.phone, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                const Text('الدَّين المستحق على العميل', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                Text(money(debt), style: const TextStyle(color: Color(0xFFFFE58B), fontSize: 28, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text('${os.where((o) => o.status != 'cancel').length} طلب • إجمالي مشترياته ${money(total)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: C.gold, foregroundColor: C.dark),
                  onPressed: debt <= 0 ? null : () => _pay(context, s, debt),
                  icon: const Icon(Icons.payments_rounded),
                  label: const Text('تسجيل دفعة من العميل'),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            const PageHead('الطلبات'),
            if (os.isEmpty) const Empty('لا توجد طلبات', icon: Icons.receipt_long_outlined),
            for (final o in os)
              LuxCard(
                accent: statusColor(o.status),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePage(orderId: o.id))),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('#${o.id} • ${statusLabel(o.status)}', style: const TextStyle(fontWeight: FontWeight.w900)),
                      Text('${dateText(o.date)} • ${paymentLabel(o.method)}', style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  Text(money(o.total), style: TextStyle(fontWeight: FontWeight.w900, color: o.method == 'credit' ? C.red : C.g)),
                ]),
              ),
            const SizedBox(height: 8),
            const PageHead('الدفعات'),
            if (pays.isEmpty) const Empty('لا توجد دفعات', icon: Icons.history_rounded),
            for (final x in pays)
              LuxCard(
                accent: C.g2,
                child: Row(children: [
                  const Icon(Icons.check_circle, color: C.g2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(dateText(x.date), style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (x.note.isNotEmpty) Text(x.note, style: const TextStyle(color: C.muted, fontSize: 11)),
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

  Future<void> _pay(BuildContext context, AppStore s, double max0) async {
    final amount = TextEditingController(text: qtyText(max0).replaceAll(',', ''));
    final note = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('دفعة من العميل'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amount, keyboardType: numType, decoration: const InputDecoration(labelText: 'المبلغ المستلم')),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final err = s.addCustomerPayment(customerId, num2(amount.text), note.text.trim());
              if (err != null) {
                toast(context, err);
              } else {
                Navigator.pop(ctx);
                toast(context, 'تم تسجيل الدفعة ✓');
              }
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
  }
}

// ---------------- الجرد وسجل المخزون ----------------

String _moveLabel(String t) => switch (t) {
      'sale' => 'بيع',
      'return' => 'مرتجع',
      'manual' => 'تعديل يدوي',
      'count' => 'جرد',
      _ => t,
    };

class StockLogSheet extends StatelessWidget {
  final Product product;
  const StockLogSheet({super.key, required this.product});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final list = s.stockMoves.where((m) => m.productId == product.id).toList().reversed.take(60).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('سجل حركة: ${product.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: C.g)),
      const SizedBox(height: 4),
      Text(product.track ? 'الرصيد الحالي: ${qtyText(product.stock)} ${unitShort(product.unit)}' : 'هذا الصنف بلا تتبّع مخزون', style: const TextStyle(color: C.muted)),
      const SizedBox(height: 10),
      if (list.isEmpty) const Empty('لا توجد حركات مسجّلة', icon: Icons.history_rounded),
      for (final m in list)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(m.delta >= 0 ? Icons.add_circle_rounded : Icons.remove_circle_rounded, color: m.delta >= 0 ? C.g2 : C.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_moveLabel(m.type)}${m.note.isEmpty ? '' : ' — ${m.note}'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                Text(dateText(m.date), style: const TextStyle(color: C.muted, fontSize: 10)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${m.delta >= 0 ? '+' : ''}${qtyText(m.delta)}', style: TextStyle(fontWeight: FontWeight.w900, color: m.delta >= 0 ? C.g2 : C.red)),
              Text('الرصيد ${qtyText(m.balance)}', style: const TextStyle(color: C.muted, fontSize: 10)),
            ]),
          ]),
        ),
    ]);
  }
}

class StocktakePage extends StatefulWidget {
  const StocktakePage({super.key});
  @override
  State<StocktakePage> createState() => _StocktakePageState();
}

class _StocktakePageState extends State<StocktakePage> {
  final ctrl = <int, TextEditingController>{};

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppStore>();
    final list = s.products.where((p) => p.track).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('جرد المخزون'), flexibleSpace: Container(decoration: const BoxDecoration(gradient: C.brandGradient))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(padding: const EdgeInsets.all(14), children: [
            const Text('أدخل الكمية الفعلية الموجودة لكل صنف، ويُسجَّل الفرق في سجل الحركة. الأصناف غير المتتبَّعة لا تظهر هنا.',
                style: TextStyle(color: C.muted, fontSize: 12, height: 1.6)),
            const SizedBox(height: 10),
            if (list.isEmpty) const Empty('لا توجد أصناف بتتبّع مخزون', icon: Icons.inventory_2_outlined),
            for (final p in list)
              LuxCard(
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                      Text('الحالي: ${qtyText(p.stock)} ${unitShort(p.unit)}', style: const TextStyle(color: C.muted, fontSize: 11)),
                    ]),
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: ctrl.putIfAbsent(p.id, () => TextEditingController()),
                      keyboardType: numType,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: 'الفعلي', contentPadding: EdgeInsets.symmetric(vertical: 8)),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            LuxButton('حفظ الجرد', Icons.save_rounded, () {
              var n = 0;
              String? err;
              for (final p in list) {
                final t = ctrl[p.id]?.text.trim() ?? '';
                if (t.isEmpty) continue;
                final v = num2(t);
                if (v == p.stock) continue;
                final e = s.adjustStock(p.id, 'set', v);
                if (e != null) {
                  err = '${p.name}: $e';
                  break;
                }
                n++;
              }
              if (err != null) return toast(context, err);
              toast(context, n == 0 ? 'لا توجد تغييرات' : 'تم تحديث $n صنف ✓');
              if (n > 0) Navigator.pop(context);
            }),
            const SizedBox(height: 30),
          ]),
        ),
      ),
    );
  }
}
