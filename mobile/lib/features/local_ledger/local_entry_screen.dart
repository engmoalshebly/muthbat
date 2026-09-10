import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/theme/app_colors.dart';
import 'local_ledger_store.dart';
import 'local_palette.dart';

class LocalEntryScreen extends StatefulWidget {
  const LocalEntryScreen({
    super.key,
    required this.store,
    required this.document,
    this.customerId,
    this.initialType = 'debt',
  });
  final LocalLedgerStore store;
  final JsonMap document;
  final String? customerId;
  final String initialType;
  @override
  State<LocalEntryScreen> createState() => _LocalEntryScreenState();
}

class _LocalEntryScreenState extends State<LocalEntryScreen> {
  final name = TextEditingController();
  final amount = TextEditingController();
  final notes = TextEditingController();
  late String type = widget.initialType;
  late String? customer = widget.customerId;
  bool saving = false;
  String? error;
  final requestId = const Uuid().v4();
  DateTime occurredAt = DateTime.now();
  String category = 'عام';

  Future<void> pickCustomer() async {
    String query = '';
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final matches = (widget.document['customers'] as List)
              .where(
                (c) => c['name'].toString().toLowerCase().contains(
                  query.trim().toLowerCase(),
                ),
              )
              .toList();
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .48,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (value) => update(() => query = value),
                    decoration: const InputDecoration(
                      labelText: 'ابحث عن عميل',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(sheetContext, ''),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('إضافة عميل جديد'),
                  ),
                  Expanded(
                    child: matches.isEmpty
                        ? const Center(child: Text('لا يوجد عميل مطابق'))
                        : ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (_, index) {
                              final c = matches[index];
                              return ListTile(
                                title: Text(c['name']),
                                trailing: const Icon(Icons.chevron_left),
                                onTap: () =>
                                    Navigator.pop(sheetContext, c['id']),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      customer = result.isEmpty ? null : result;
      if (result.isEmpty) name.text = query.trim();
    });
  }

  @override
  void dispose() {
    name.dispose();
    amount.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    if (LocalLedgerStore.descriptionError(notes.text) != null) {
      setState(() => error = LocalLedgerStore.descriptionError(notes.text));
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final id = await widget.store.record(
        requestId: requestId,
        customerId: customer,
        customerName: name.text,
        type: type,
        amount: amount.text,
        description: notes.text.trim(),
        occurredAt: occurredAt,
        category: category,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted)
        setState(() {
          error = e is FormatException
              ? e.message
              : e is StateError
              ? e.message.toString()
              : 'تعذر الحفظ. بيانات النموذج محفوظة؛ أعد المحاولة.';
          saving = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = type == 'debt'
        ? AppColors.primary
        : type == 'payment'
        ? LocalPalette.teal
        : AppColors.primaryLight;
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text('تسجيل عملية'),
          backgroundColor: Colors.white,
          leading: IconButton(
            tooltip: 'إلغاء',
            onPressed: saving ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in [
                        ('debt', 'دين'),
                        ('payment', 'دفعة'),
                        ('discount', 'خصم'),
                      ])
                        ChoiceChip(
                          label: Text(option.$2),
                          selected: type == option.$1,
                          selectedColor: color,
                          showCheckmark: false,
                          labelStyle: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: type == option.$1
                                ? Colors.white
                                : AppColors.primary,
                          ),
                          onSelected: saving
                              ? null
                              : (_) => setState(() {
                                  type = option.$1;
                                  error = null;
                                }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          type == 'debt'
                              ? Icons.receipt_long
                              : Icons.payments_outlined,
                          color: color,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            type == 'debt'
                                ? 'دين على العميل • يزيد المبلغ المستحق لك'
                                : type == 'payment'
                                ? 'دفعة مستلمة • تخفّض رصيد العميل'
                                : 'خصم ممنوح • يخفض الدين دون استلام مال',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                final chosen = await showDatePicker(
                                  context: context,
                                  initialDate: occurredAt,
                                  firstDate: DateTime(1900),
                                  lastDate: DateTime.now(),
                                );
                                if (chosen != null && mounted)
                                  setState(
                                    () => occurredAt = DateTime(
                                      chosen.year,
                                      chosen.month,
                                      chosen.day,
                                      occurredAt.hour,
                                      occurredAt.minute,
                                    ),
                                  );
                              },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          '${occurredAt.year}/${occurredAt.month}/${occurredAt.day}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'التصنيف'),
                    items: ['عام', 'مشتريات', 'إيجار', 'قرض', 'خدمات', 'أخرى']
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: saving
                        ? null
                        : (value) => setState(() => category = value!),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : pickCustomer,
                          icon: const Icon(Icons.search),
                          label: Text(
                            customer == null
                                ? 'بحث عن عميل'
                                : (widget.document['customers'] as List)
                                      .firstWhere(
                                        (c) => c['id'] == customer,
                                      )['name'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () => setState(() => customer = null),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('عميل جديد'),
                      ),
                    ],
                  ),
                  if (customer == null) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: name,
                      enabled: !saving,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'اسم العميل',
                        counterText: '',
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TextField(
                    controller: amount,
                    enabled: !saving,
                    textDirection: TextDirection.ltr,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                    decoration: InputDecoration(
                      labelText: 'المبلغ',
                      suffixText: widget.document['currency'],
                      hintText: '0.00',
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: notes,
                    enabled: !saving,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'وصف العملية (مطلوب)',
                      counterText: '',
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        error!,
                        style: const TextStyle(color: AppColors.error),
                        semanticsLabel: error,
                      ),
                    ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: color,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: saving ? null : save,
                    icon: Icon(saving ? Icons.hourglass_top : Icons.check),
                    label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ على الجهاز'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'تُحفظ العملية محليًا دون الحاجة إلى الإنترنت.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: LocalPalette.secondaryText,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
