import 'auth_route_guard.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/splash/presentation/screens/welcome_screen.dart';
import 'package:flutter/material.dart';
import '../../features/auth/presentation/screens/workspaces_screen.dart';
import '../../features/app_lock/app_lock_settings_screen.dart';
import '../../features/local_ledger/local_ledger_screen.dart';
import '../../features/auth/presentation/screens/account_recovery_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/otp_verification_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/auth/presentation/screens/reset_password_screen.dart';
import '../../features/customer/presentation/screens/customer_home_screen.dart';
import '../../features/merchant/data/models/business_customer_model.dart';
import '../../features/merchant/data/models/dispute_model.dart';
import '../../features/merchant/data/models/statement_model.dart';
import '../../features/merchant/presentation/screens/business_setup_screen.dart';
import '../../features/merchant/presentation/screens/business_profile_edit_screen.dart';
import '../../features/merchant/presentation/screens/customer_ledger_screen.dart';
import '../../features/merchant/presentation/screens/currency_settings_screen.dart';
import '../../features/merchant/presentation/screens/dispute_detail_screen.dart';
import '../../features/merchant/presentation/screens/disputes_list_screen.dart';
import '../../features/merchant/presentation/screens/merchant_home_screen.dart';
import '../../features/merchant/presentation/screens/merchant_profile_screen.dart';
import '../../features/merchant/presentation/screens/statement_preview_screen.dart';
import '../../features/splash/presentation/screens/splash_screen.dart';
import '../../features/sync/presentation/rejected_operations_screen.dart';
import '../../features/support/presentation/darai_chat_screen.dart';

/// مسارات التنقل المعتمدة في تطبيق «مُثبَت | MUTHBAT»
class AppRoutes {
  AppRoutes._();

  static const String splash = '/';
  static const String welcome = '/welcome';
  static const String login = '/login';
  static const String localLedger = '/local-ledger';
  static const String workspaces = '/workspaces';
  static const String register = '/register';
  static const String otp = '/otp';
  static const String recovery = '/recovery';
  static const String businessSetup = '/business-setup';
  static const String merchantHome = '/merchant-home';
  static const String customerHome = '/customer-home';
  static const String customerLedger = '/customer-ledger';
  static const String disputesList = '/disputes-list';
  static const String disputeDetail = '/dispute-detail';
  static const String statementPreview = '/statement-preview';
  static const String merchantProfile = '/merchant-profile';
  static const String currencySettings = '/currency-settings';
  static const String businessProfileEdit = '/business-profile-edit';
  static const String resetPassword = '/reset-password';
  static const String appLockSettings = '/app-lock-settings';
  static const String rejectedOperations = '/rejected-operations';
  static const String daraiChat = '/darai-chat';
  static const String notifications = '/notifications';

  static Route<dynamic> _errorRoute(String message) {
    return MaterialPageRoute(
      builder: (_) => Scaffold(body: Center(child: Text(message))),
    );
  }

  static MaterialPageRoute<dynamic> _guardedRoute({
    required WidgetBuilder builder,
    required RouteSettings settings,
  }) => MaterialPageRoute(
    settings: settings,
    builder: (_) => AuthRouteGuard(settings: settings, builder: builder),
  );

  /// Guard account screens pushed directly with typed constructor arguments.
  static MaterialPageRoute<dynamic> accountPage({
    required WidgetBuilder builder,
  }) => _guardedRoute(
    builder: builder,
    settings: const RouteSettings(name: '/account-screen'),
  );

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case notifications:
        final notificationArgs = settings.arguments;
        final notificationId = notificationArgs is Map
            ? notificationArgs['notificationId'] as String?
            : notificationArgs as String?;
        final notificationWorkspace = notificationArgs is Map
            ? notificationArgs['workspace'] as String? ?? 'auto'
            : 'auto';
        return _guardedRoute(
          settings: settings,
          builder: (_) => NotificationsScreen(
            initialId: notificationId,
            workspace: notificationWorkspace,
          ),
        );
      case welcome:
        return _guardedRoute(
          builder: (_) => const WelcomeScreen(),
          settings: settings,
        );
      case daraiChat:
        return _guardedRoute(
          builder: (_) => const DaraiChatScreen(),
          settings: settings,
        );
      case rejectedOperations:
        return _guardedRoute(
          builder: (_) => const RejectedOperationsScreen(),
          settings: settings,
        );
      case appLockSettings:
        return _guardedRoute(
          builder: (_) => const AppLockSettingsScreen(),
          settings: settings,
        );
      case localLedger:
        return _guardedRoute(
          builder: (_) => const LocalLedgerScreen(),
          settings: settings,
        );
      case workspaces:
        return _guardedRoute(
          builder: (_) => const WorkspacesScreen(),
          settings: settings,
        );
      case businessSetup:
        return _guardedRoute(
          builder: (_) => const BusinessSetupScreen(),
          settings: settings,
        );
      case login:
        return _guardedRoute(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );
      case register:
        return _guardedRoute(
          builder: (_) =>
              RegisterScreen(customerMode: settings.arguments == 'customer'),
          settings: settings,
        );
      case otp:
        return _guardedRoute(
          builder: (_) => const OtpVerificationScreen(),
          settings: settings,
        );
      case recovery:
        return _guardedRoute(
          builder: (_) => const AccountRecoveryScreen(),
          settings: settings,
        );
      case merchantHome:
        final initialTab = settings.arguments is int
            ? settings.arguments as int
            : 0;
        return _guardedRoute(
          builder: (_) => MerchantHomeScreen(initialTab: initialTab),
          settings: settings,
        );
      case customerHome:
        return _guardedRoute(
          builder: (_) => const CustomerHomeScreen(),
          settings: settings,
        );
      case customerLedger:
        final customer = settings.arguments;
        if (customer is! BusinessCustomerModel) {
          return _errorRoute('customerLedger requires BusinessCustomerModel');
        }
        return _guardedRoute(
          builder: (_) => CustomerLedgerScreen(customer: customer),
          settings: settings,
        );
      case disputesList:
        return _guardedRoute(
          builder: (_) => const DisputesListScreen(),
          settings: settings,
        );
      case disputeDetail:
        final dispute = settings.arguments;
        if (dispute is! DisputeModel) {
          return _errorRoute('disputeDetail requires DisputeModel');
        }
        return _guardedRoute(
          builder: (_) => DisputeDetailScreen(dispute: dispute),
          settings: settings,
        );
      case statementPreview:
        final args = settings.arguments;
        if (args is! Map<String, dynamic> ||
            args['statement'] is! StatementModel ||
            args['customer'] is! BusinessCustomerModel) {
          return _errorRoute(
            'statementPreview requires statement and customer',
          );
        }
        final statement = args['statement'] as StatementModel;
        final customer = args['customer'] as BusinessCustomerModel;
        return _guardedRoute(
          builder: (_) =>
              StatementPreviewScreen(statement: statement, customer: customer),
          settings: settings,
        );
      case merchantProfile:
        return _guardedRoute(
          builder: (_) => const MerchantProfileScreen(),
          settings: settings,
        );
      case currencySettings:
        return _guardedRoute(
          builder: (_) => const CurrencySettingsScreen(),
          settings: settings,
        );
      case businessProfileEdit:
        return _guardedRoute(
          builder: (_) => const BusinessProfileEditScreen(),
          settings: settings,
        );
      case resetPassword:
        return _guardedRoute(
          builder: (_) => const ResetPasswordScreen(),
          settings: settings,
        );
      case splash:
        return _guardedRoute(
          builder: (_) => const SplashScreen(),
          settings: settings,
        );
      default:
        return _errorRoute('المسار المطلوب غير موجود.');
    }
  }
}
