import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../data/models/member_model.dart';
import '../controllers/merchant_controller.dart';
import '../widgets/invite_member_sheet.dart';

class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});

  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  List<MemberModel> _members = [];
  List<MemberInviteModel> _invites = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTeamData();
  }

  Future<void> _loadTeamData() async {
    setState(() => _isLoading = true);
    final bizId = ref.read(merchantControllerProvider).businessId;
    final repo = ref.read(merchantRepositoryProvider);

    final members = await repo.getMembers(bizId);
    final invites = await repo.getMemberInvites(bizId);

    if (mounted) {
      setState(() {
        _members = members;
        _invites = invites;
        _isLoading = false;
      });
    }
  }

  void _openInviteSheet() async {
    final bizId = ref.read(merchantControllerProvider).businessId;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => InviteMemberSheet(businessId: bizId),
    );

    if (result == true) {
      await _loadTeamData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bizName = ref.watch(merchantControllerProvider).businessName;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('فريق العمل والصلاحيات', style: AppTypography.titleMedium(color: Colors.white)),
            Text(bizName, style: AppTypography.caption(color: AppColors.accentGold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: _loadTeamData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : RefreshIndicator(
              onRefresh: _loadTeamData,
              color: AppColors.primary,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 80),
                children: [
                  // بطاقة معلومات الصلاحيات
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.primaryLight.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('الأدوار والصلاحيات', style: AppTypography.titleSmall(color: AppColors.primary)),
                              const SizedBox(height: 2),
                              Text(
                                'يمكنك إضافة موظفين وتفويضهم بصلاحيات تسجيل القيود أو التحصيل وفق أدوار محددة.',
                                style: AppTypography.caption(color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // قسم الأعضاء الحاليين
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('أعضاء الفريق (${_members.length})', style: AppTypography.titleSmall(color: AppColors.textPrimary)),
                      TextButton.icon(
                        onPressed: _openInviteSheet,
                        icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                        label: const Text('دعوة موظف'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  ..._members.map((member) => _buildMemberCard(member)),

                  // قسم الدعوات المعلقة (إذا وجدت)
                  if (_invites.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('الدعوات المعلقة (${_invites.length})', style: AppTypography.titleSmall(color: AppColors.textPrimary)),
                    const SizedBox(height: 10),
                    ..._invites.map((invite) => _buildInviteCard(invite)),
                  ],
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openInviteSheet,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('دعوة موظف جديد', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildMemberCard(MemberModel member) {
    Color roleColor;
    switch (member.role) {
      case 'owner':
        roleColor = AppColors.accentGoldDark;
        break;
      case 'admin':
        roleColor = AppColors.primary;
        break;
      case 'accountant':
        roleColor = AppColors.secondary;
        break;
      case 'collector':
        roleColor = AppColors.paymentGreen;
        break;
      default:
        roleColor = AppColors.textSecondary;
    }

    final name = member.displayName ?? 'عضو فريق';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: roleColor.withValues(alpha: 0.12),
            child: Text(
              name.isNotEmpty ? name[0] : 'م',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: roleColor),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: AppTypography.titleSmall(color: AppColors.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        member.roleLocalized,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: roleColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  member.roleDescription,
                  style: AppTypography.caption(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 150.ms);
  }

  Widget _buildInviteCard(MemberInviteModel invite) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mail_outline_rounded, size: 20, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'دعوة دور: ${invite.roleLocalized}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        invite.statusLocalized,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.warning),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'تنتهي في: ${DateFormat('yyyy/MM/dd').format(DateTime.parse(invite.expiresAt))}',
                  style: AppTypography.caption(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
