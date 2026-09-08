import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';
import 'package:muthbat/features/customer/presentation/controllers/customer_controller.dart';

class FakeCustomerRepository extends CustomerRepository {
  @override
  Future<List<Map<String, dynamic>>> pendingActions() async => [];
  @override
  Future<void> flushOutbox() async {}
  String? owner = 'owner-a';
  final identities = <Completer<String?>>[];
  @override
  String? get userId => owner;
  @override
  Future<String?> resolveCustomerId() {
    final result = Completer<String?>();
    identities.add(result);
    return result.future;
  }

  @override
  Future<List<CustomerBusinessSummary>> fetchBusinessSummaries(
    String id,
  ) async => [];
  @override
  Future<List<CustomerLinkRequestModel>> fetchPendingLinkRequests(
    String id,
  ) async => [];
  @override
  Future<List<CustomerPendingEntry>> fetchPendingEntries(String id) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('latest refresh wins when an earlier request completes late', () async {
    final repo = FakeCustomerRepository();
    final controller = CustomerController(repo);
    final first = controller.load();
    await Future<void>.delayed(Duration.zero);
    final second = controller.load();
    await Future<void>.delayed(Duration.zero);
    repo.identities[1].complete('new');
    await second;
    repo.identities[0].complete('old');
    await first;
    expect(controller.state.customerId, 'new');
    controller.dispose();
  });
  test('disposed account never receives a late response', () async {
    final repo = FakeCustomerRepository();
    final controller = CustomerController(repo);
    final pending = controller.load();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    repo.owner = 'owner-b';
    repo.identities.single.complete('private-a');
    await pending;
  });
}
