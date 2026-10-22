import '../../app/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../../app/theme/app_colors.dart';
import 'local_ledger_store.dart';
import 'local_customer_screen.dart';

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
  late List customers = List.of(widget.document['customers'] as List);
  late final customerSearch = TextEditingController(
    text:
        customers
            .where((c) => c['id'] == widget.customerId)
            .firstOrNull?['name'] ??
        '',
  );
  String customerQuery = '';
  final customerFocus = FocusNode();
  final amount = TextEditingController();
  final notes = TextEditingController();
  late String type = widget.initialType;
  late String? customer = widget.customerId;
  bool saving = false;
  String? error;
  final requestId = const Uuid().v4();
  DateTime occurredAt = DateTime.now();
  String category = 'عام';

  Future<void> addCustomer() async {
    if (saving) return;
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalCustomerScreen(store: widget.store),
      ),
    );
    if (!mounted || id == null) return;
    final document = await widget.store.current();
    if (!mounted || document == null) return;
    setState(() {
      customers = List.of(document['customers'] as List);
      customer = id;
      customerSearch.text = customers.firstWhere((c) => c['id'] == id)['name'];
      customerQuery = '';
    });
  }

  Future<void> pickCustomer() async {
    String query = '';
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) {
          final matches = customers
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
                      prefixIcon: Icon(AppIcons.search),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(sheetContext, ''),
                    icon: const Icon(AppIcons.customers),
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
    if (result.isEmpty) {
      await addCustomer();
    } else {
      setState(() => customer = result);
    }
  }

  @override
  void dispose() {
    amount.dispose();
    customerFocus.dispose();
    customerSearch.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    if (customer == null) {
      setState(() => error = 'اختر العميل أولًا أو أضفه من شاشة إضافة عميل.');
      return;
    }
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
        type: type,
        amount: amount.text,
        description: notes.text.trim(),
        occurredAt: occurredAt,
        category: category,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
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
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.transactionColor(type);
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        backgroundColor: AppColors.backgroundLight,
        appBar: AppBar(
          toolbarHeight: 56,
          centerTitle: false,
          titleSpacing: 0,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: AppColors.backgroundLight,
          foregroundColor: AppColors.textPrimary,
          systemOverlayStyle: SystemUiOverlayStyle.dark.copyWith(
            statusBarColor: AppColors.transparent,
          ),
          shape: const Border(bottom: BorderSide(color: AppColors.borderLight)),
          title: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(AppIcons.transaction(type), color: color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type == 'debt'
                          ? 'تسجيل دين'
                          : type == 'payment'
                          ? 'تسجيل دفعة'
                          : 'تسجيل خصم',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const Text(
                      'دفتر الجهاز • حفظ محلي',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          leading: IconButton(
            tooltip: 'رجوع',
            onPressed: saving ? null : () => Navigator.pop(context),
            icon: const Icon(AppIcons.chevronStart, size: 20),
          ),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: TextButton.icon(
                onPressed: saving ? null : addCustomer,
                icon: const Icon(AppIcons.customers, size: 17),
                label: const Text(
                  'إضافة عميل',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: saving ? null : save,
              icon: Icon(saving ? Icons.hourglass_top : Icons.check),
              label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ على الجهاز'),
            ),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerSoft,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        for (final option in [
                          ('debt', 'دين'),
                          ('payment', 'دفعة'),
                          ('discount', 'خصم'),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: Material(
                                color: type == option.$1
                                    ? AppColors.transactionColor(option.$1)
                                    : AppColors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: saving
                                      ? null
                                      : () => setState(() {
                                          type = option.$1;
                                          error = null;
                                        }),
                                  child: Semantics(
                                    selected: type == option.$1,
                                    button: true,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 12,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            AppIcons.transaction(option.$1),
                                            size: 16,
                                            color: type == option.$1
                                                ? AppColors.white
                                                : AppColors.transactionColor(
                                                    option.$1,
                                                  ),
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              option.$2,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: type == option.$1
                                                    ? AppColors.white
                                                    : AppColors.transactionColor(
                                                        option.$1,
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) => RawAutocomplete<Map>(
                      textEditingController: customerSearch,
                      focusNode: customerFocus,
                      displayStringForOption: (c) => c['name'].toString(),
                      optionsBuilder: (value) {
                        if (saving || value.text.trim().isEmpty) {
                          return const Iterable<Map>.empty();
                        }
                        return customers
                            .where(
                              (c) => LocalLedgerStore.matchesCustomer(
                                c,
                                value.text,
                              ),
                            )
                            .cast<Map>();
                      },
                      onSelected: (c) {
                        setState(() {
                          customer = c['id'];
                          customerQuery = '';
                          error = null;
                        });
                        customerFocus.unfocus();
                      },
                      fieldViewBuilder: (context, controller, focus, submit) =>
                          TextField(
                            controller: controller,
                            focusNode: focus,
                            enabled: !saving,
                            onSubmitted: (_) => submit(),
                            onChanged: (value) => setState(() {
                              customerQuery = value;
                              customer = null;
                              error = null;
                            }),
                            decoration: InputDecoration(
                              labelText: 'اسم العميل أو رقم الهاتف',
                              prefixIcon: const Icon(AppIcons.search, size: 18),
                              suffixIcon: customer == null
                                  ? null
                                  : const Icon(
                                      AppIcons.check,
                                      color: AppColors.primary,
                                      size: 18,
                                    ),
                            ),
                          ),
                      optionsViewBuilder: (context, select, options) {
                        final matches = options.toList();
                        return Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Material(
                              elevation: 6,
                              color: AppColors.surfaceLight,
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: SizedBox(
                                width: constraints.maxWidth,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 220,
                                  ),
                                  child: ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    shrinkWrap: true,
                                    itemCount: matches.length,
                                    itemBuilder: (context, index) {
                                      final c = matches[index];
                                      final highlighted =
                                          AutocompleteHighlightedOption.of(
                                            context,
                                          ) ==
                                          index;
                                      return ListTile(
                                        dense: true,
                                        selected: highlighted,
                                        selectedTileColor:
                                            AppColors.primaryContainer,
                                        leading: const Icon(
                                          AppIcons.singleCustomer,
                                          size: 18,
                                        ),
                                        title: Text(
                                          c['name'].toString(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: c['phone'] == null
                                            ? null
                                            : Text(
                                                c['phone'].toString(),
                                                textDirection:
                                                    TextDirection.ltr,
                                              ),
                                        onTap: () => select(c),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
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
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final dateField = TextFormField(
                        key: ValueKey(occurredAt.toIso8601String()),
                        initialValue:
                            '${occurredAt.year}/${occurredAt.month.toString().padLeft(2, '0')}/${occurredAt.day.toString().padLeft(2, '0')}',
                        readOnly: true,
                        enabled: !saving,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'تاريخ العملية',
                          prefixIcon: Icon(AppIcons.calendar, size: 18),
                          suffixIcon: Icon(AppIcons.chevronDown, size: 16),
                        ),
                        onTap: saving
                            ? null
                            : () async {
                                final chosen = await showDatePicker(
                                  context: context,
                                  initialDate: occurredAt,
                                  firstDate: DateTime(1900),
                                  lastDate: DateTime.now(),
                                );
                                if (chosen != null && mounted) {
                                  setState(
                                    () => occurredAt = DateTime(
                                      chosen.year,
                                      chosen.month,
                                      chosen.day,
                                      occurredAt.hour,
                                      occurredAt.minute,
                                    ),
                                  );
                                }
                              },
                      );
                      final categoryField = DropdownButtonFormField<String>(
                        initialValue: category,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'التصنيف'),
                        items:
                            ['عام', 'مشتريات', 'إيجار', 'قرض', 'خدمات', 'أخرى']
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(c),
                                  ),
                                )
                                .toList(),
                        onChanged: saving
                            ? null
                            : (value) => setState(() => category = value!),
                      );
                      if (constraints.maxWidth < 340) {
                        return Column(
                          children: [
                            dateField,
                            const SizedBox(height: 12),
                            categoryField,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: dateField),
                          const SizedBox(width: 12),
                          Expanded(child: categoryField),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: notes,
                    enabled: !saving,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'وصف العملية (مطلوب)',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
