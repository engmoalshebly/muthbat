import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/merchant/data/models/business_customer_model.dart';
import 'package:muthbat/features/merchant/presentation/controllers/merchant_controller.dart';

class DirectoryRepository extends MerchantRepository {
  DirectoryRepository() : super(requestSync: () {});
  final pending = <String, Completer<List<BusinessCustomerModel>>>{};
  final offsets = <int>[];
  @override
  Future<List<BusinessCustomerModel>> getCustomers(
    String businessId, {
    String? searchQuery,
    int? limit,
    int offset = 0,
  }) {
    offsets.add(offset);
    final completer = Completer<List<BusinessCustomerModel>>();
    pending['$searchQuery:$offset'] = completer;
    return completer.future;
  }
}

void main() {
  test(
    'search keeps totals and dashboard data, ignores stale response and loads another page',
    () async {
      final repo = DirectoryRepository();
      const customer = BusinessCustomerModel(
        id: 'recent',
        businessId: 'business',
        localDisplayName: 'Recent',
      );
      final controller = MerchantController.forTesting(
        repo,
        const MerchantDashboardState(
          businessId: 'business',
          totalReceivables: 500,
          totalPayables: 100,
          totalCustomerCount: 1201,
          dashboardCustomers: [customer],
          customers: [customer],
        ),
      );
      List<BusinessCustomerModel> page(String prefix, int count) =>
          List.generate(
            count,
            (i) => BusinessCustomerModel(
              id: '$prefix-$i',
              businessId: 'business',
              localDisplayName: '$prefix $i',
            ),
          );
      final old = controller.search('old');
      final latest = controller.search('latest');
      repo.pending['latest:0']!.complete(page('latest', 51));
      await latest;
      repo.pending['old:0']!.complete(page('old', 1));
      await old;
      expect(controller.state.customers.first.id, 'latest-0');
      expect(controller.state.customers.length, 50);
      expect(controller.state.hasMoreCustomers, isTrue);
      expect(controller.state.totalReceivables, 500);
      expect(controller.state.totalPayables, 100);
      expect(controller.state.totalCustomerCount, 1201);
      expect(controller.state.dashboardCustomers.single.id, 'recent');
      final more = controller.loadMoreCustomers();
      repo.pending['latest:50']!.complete(page('tail', 2));
      await more;
      expect(controller.state.customers.length, 52);
      expect(controller.state.hasMoreCustomers, isFalse);
      expect(repo.offsets, [0, 0, 50]);
      controller.dispose();
    },
  );
}
