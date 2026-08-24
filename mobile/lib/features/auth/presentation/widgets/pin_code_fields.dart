import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

/// مربعات إدخال رمز التحقق السداسي (6-Digit OTP Field)
class PinCodeFields extends StatefulWidget {
  final int length;
  final ValueChanged<String> onCompleted;
  final ValueChanged<String>? onChanged;
  final String? initialValue;

  const PinCodeFields({
    super.key,
    this.length = 6,
    required this.onCompleted,
    this.onChanged,
    this.initialValue,
  });

  @override
  State<PinCodeFields> createState() => PinCodeFieldsState();
}

class PinCodeFieldsState extends State<PinCodeFields> {
  late List<TextEditingController> _controllers;
  late List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(widget.length, (i) => TextEditingController());
    _focusNodes = List.generate(widget.length, (i) => FocusNode());

    if (widget.initialValue != null && widget.initialValue!.isNotEmpty) {
      setPin(widget.initialValue!);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void setPin(String code) {
    final cleanCode = code.replaceAll(RegExp(r'\D'), '');
    for (int i = 0; i < widget.length; i++) {
      if (i < cleanCode.length) {
        _controllers[i].text = cleanCode[i];
      } else {
        _controllers[i].clear();
      }
    }
    _checkComplete();
  }

  void clear() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes.first.requestFocus();
  }

  void _checkComplete() {
    final pin = _controllers.map((c) => c.text).join();
    widget.onChanged?.call(pin);
    if (pin.length == widget.length) {
      widget.onCompleted(pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(widget.length, (index) {
          final isFirst = index == 0;
          final isLast = index == widget.length - 1;

          return SizedBox(
            width: 48,
            height: 58,
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.backspace &&
                    _controllers[index].text.isEmpty &&
                    !isFirst) {
                  _focusNodes[index - 1].requestFocus();
                  _controllers[index - 1].clear();
                  _checkComplete();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextFormField(
                controller: _controllers[index],
                focusNode: _focusNodes[index],
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                textAlign: TextAlign.center,
                style: AppTypography.financialAmount(
                  fontSize: 22,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.borderLight,
                      width: 1.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: _controllers[index].text.isNotEmpty
                          ? AppColors.secondary
                          : AppColors.borderLight,
                      width: 1.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.accentGold,
                      width: 2.2,
                    ),
                  ),
                ),
                onChanged: (value) {
                  // Allow a six-digit OTP pasted from WhatsApp/SMS.
                  if (value.length > 1) {
                    setPin(value);
                    return;
                  }
                  if (value.isNotEmpty) {
                    if (!isLast) {
                      _focusNodes[index + 1].requestFocus();
                    } else {
                      _focusNodes[index].unfocus();
                    }
                  } else if (!isFirst) {
                    _focusNodes[index - 1].requestFocus();
                  }
                  _checkComplete();
                },
              ),
            ),
          );
        }),
      ),
    );
  }
}
