import 'package:flutter/material.dart';
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
import '../../features/merchant/presentation/screens/team_screen.dart';
import '../../features/splash/presentation/screens/splash_screen.dart';

/// مسارات التنقل المعتمدة في تطبيق «مُثبَت | MUTHBAT»
class AppRoutes {
  AppRoutes._();

  static const String splash = '/';
  static const String login = '/login';
  static const String localLedger = '/local-ledger';
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
  static const String team = '/team';
  static const String merchantProfile = '/merchant-profile';
  static const String currencySettings = '/currency-settings';
  static const String businessProfileEdit = '/business-profile-edit';
  static const String resetPassword = '/reset-password';

  static Route<dynamic> _errorRoute(String message) {
    return MaterialPageRoute(
      builder: (_) => Scaffold(body: Center(child: Text(message))),
    );
  }

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case localLedger:
        return MaterialPageRoute(
          builder: (_) => const LocalLedgerScreen(),
          settings: settings,
        );
      case businessSetup:
        return MaterialPageRoute(
          builder: (_) => const BusinessSetupScreen(),
          settings: settings,
        );
      case login:
        return MaterialPageRoute(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );
      case register:
        return MaterialPageRoute(
          builder: (_) => const RegisterScreen(),
          settings: settings,
        );
      case otp:
        return MaterialPageRoute(
          builder: (_) => const OtpVerificationScreen(),
          settings: settings,
        );
      case recovery:
        return MaterialPageRoute(
          builder: (_) => const AccountRecoveryScreen(),
          settings: settings,
        );
      case merchantHome:
        final initialTab = settings.arguments is int
            ? settings.arguments as int
            : 0;
        return MaterialPageRoute(
          builder: (_) => MerchantHomeScreen(initialTab: initialTab),
          settings: settings,
        );
      case customerHome:
        return MaterialPageRoute(
          builder: (_) => const CustomerHomeScreen(),
          settings: settings,
        );
      case customerLedger:
        final customer = settings.arguments;
        if (customer is! BusinessCustomerModel) {
          return _errorRoute('customerLedger requires BusinessCustomerModel');
        }
        return MaterialPageRoute(
          builder: (_) => CustomerLedgerScreen(customer: customer),
          settings: settings,
        );
      case disputesList:
        return MaterialPageRoute(
          builder: (_) => const DisputesListScreen(),
          settings: settings,
        );
      case disputeDetail:
        final dispute = settings.arguments;
        if (dispute is! DisputeModel) {
          return _errorRoute('disputeDetail requires DisputeModel');
        }
        return MaterialPageRoute(
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
        return MaterialPageRoute(
          builder: (_) =>
              StatementPreviewScreen(statement: statement, customer: customer),
          settings: settings,
        );
      case team:
        return MaterialPageRoute(
          builder: (_) => const TeamScreen(),
          settings: settings,
        );
      case merchantProfile:
        return MaterialPageRoute(
          builder: (_) => const MerchantProfileScreen(),
          settings: settings,
        );
      case currencySettings:
        return MaterialPageRoute(
          builder: (_) => const CurrencySettingsScreen(),
          settings: settings,
        );
      case businessProfileEdit:
        return MaterialPageRoute(
          builder: (_) => const BusinessProfileEditScreen(),
          settings: settings,
        );
      case resetPassword:
        return MaterialPageRoute(
          builder: (_) => const ResetPasswordScreen(),
          settings: settings,
        );
      case splash:
      default:
        return MaterialPageRoute(
          builder: (_) => const SplashScreen(),
          settings: settings,
        );
    }
  }
}
