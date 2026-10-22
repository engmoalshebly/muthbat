import 'package:flutter/material.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../data/models/business_customer_model.dart';

class CustomerSyncNotice extends StatelessWidget {
  const CustomerSyncNotice({
    super.key,
    required this.customer,
    this.compact = false,
  });
  final BusinessCustomerModel customer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (customer.syncStatus != 'dead_letter') return const SizedBox.shrink();
    final text = compact
        ? 'تعذرت مزامنة العميل — مراجعة'
        : 'تعذرت مزامنة بيانات العميل. التغييرات والعمليات التابعة محفوظة محليًا. اضغط لمراجعة السبب وإعادة المحاولة.';
    return InkWell(
      onTap: () => Navigator.pushNamed(context, AppRoutes.rejectedOperations),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: compact ? 4 : 12,
          horizontal: compact ? 0 : 16,
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: compact ? 11 : 13, color: AppColors.error),
        ),
      ),
    );
  }
}
