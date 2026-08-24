import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../data/models/dispute_model.dart';
import '../controllers/merchant_controller.dart';

class DisputesListScreen extends ConsumerStatefulWidget {
  const DisputesListScreen({super.key});

  @override
  ConsumerState<DisputesListScreen> createState() => _DisputesListScreenState();
}

class _DisputesListScreenState extends ConsumerState<DisputesListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    Future.microtask(
      () => ref.read(merchantControllerProvider.notifier).loadDisputes(),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(merchantControllerProvider);
    final openDisputes = state.disputes.where((d) => d.isOpen).toList();
    final resolvedDisputes = state.disputes.where((d) => d.isResolved).toList();

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: Text(
          'الاعتراضات والنزاعات',
          style: AppTypography.titleMedium(color: Colors.white),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.accentGold,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'قيد المعالجة',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (openDisputes.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.debtRed,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${openDisputes.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'المكتملة',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (resolvedDisputes.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${resolvedDisputes.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(merchantControllerProvider.notifier).loadDisputes(),
        color: AppColors.primary,
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildDisputesList(openDisputes, isOpenTab: true),
            _buildDisputesList(resolvedDisputes, isOpenTab: false),
          ],
        ),
      ),
    );
  }

  Widget _buildDisputesList(
    List<DisputeModel> list, {
    required bool isOpenTab,
  }) {
    final currency = ref.read(merchantControllerProvider).currency;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isOpenTab
                      ? AppColors.successLight
                      : AppColors.backgroundLight,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isOpenTab
                      ? Icons.verified_user_outlined
                      : Icons.inbox_outlined,
                  size: 48,
                  color: isOpenTab
                      ? AppColors.success
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isOpenTab
                    ? 'لا توجد اعتراضات مفتوحة'
                    : 'لا توجد اعتراضات مكتملة',
                style: AppTypography.titleMedium(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                isOpenTab
                    ? 'جميع القيود المالية متفق عليها ولم يتقدم أي عميل باعتراض حالياً.'
                    : 'سجل النزاعات المعالجة يظهر هنا بمجرد اتخاذ قرار بشأنه.',
                style: AppTypography.caption(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final currencyFormatter = NumberFormat('#,##0.##');

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        final isAwaitingMerchant = item.status == 'awaiting_merchant';

        Color statusColor;
        switch (item.status) {
          case 'awaiting_merchant':
            statusColor = AppColors.debtRed;
            break;
          case 'awaiting_customer':
            statusColor = AppColors.warning;
            break;
          case 'accepted':
            statusColor = AppColors.success;
            break;
          case 'partially_accepted':
            statusColor = AppColors.accentGoldDark;
            break;
          case 'rejected':
            statusColor = AppColors.textSecondary;
            break;
          default:
            statusColor = AppColors.info;
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isAwaitingMerchant
                  ? AppColors.debtRed.withValues(alpha: 0.3)
                  : AppColors.borderLight,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Navigator.pushNamed(
                  context,
                  AppRoutes.disputeDetail,
                  arguments: item,
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ترويسة الاعتراض: العميل + الحالة
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: AppColors.primaryLight
                                    .withValues(alpha: 0.2),
                                child: const Icon(
                                  Icons.person_outline_rounded,
                                  size: 18,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  item.customerDisplayName ?? 'عميل',
                                  style: AppTypography.titleSmall(
                                    color: AppColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            item.statusLocalized,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // سبب الاعتراض
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                                color: AppColors.debtRed,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'السبب: ${item.reasonLocalized}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          if (item.description.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              item.description,
                              style: AppTypography.bodySmall(
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // بيانات القيد المالي الأصلي
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (item.entryAmount != null)
                          Text(
                            'المبلغ المعترض عليه: ${currencyFormatter.format(item.entryAmount)} $currency',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: AppColors.primary,
                            ),
                          )
                        else
                          const SizedBox.shrink(),
                        if (item.createdAt != null)
                          Text(
                            DateFormat(
                              'yyyy/MM/dd',
                            ).format(DateTime.parse(item.createdAt!)),
                            style: AppTypography.caption(
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fadeIn(duration: 150.ms);
      },
    );
  }
}
