import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../app/theme/app_colors.dart';

/// One native editing surface keeps typing, paste and backspace consistent.
class PinCodeFields extends StatefulWidget {
  const PinCodeFields({
    super.key,
    this.length = 6,
    required this.onCompleted,
    this.onChanged,
    this.initialValue,
    this.obscureText = false,
  });
  final int length;
  final ValueChanged<String> onCompleted;
  final ValueChanged<String>? onChanged;
  final String? initialValue;
  final bool obscureText;
  @override
  State<PinCodeFields> createState() => PinCodeFieldsState();
}

class PinCodeFieldsState extends State<PinCodeFields> {
  late final TextEditingController _controller;
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _clean(widget.initialValue ?? ''),
    );
    _focus.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _clean(String value) {
    for (var i = 0; i < 10; i++) {
      value = value
          .replaceAll(String.fromCharCode(0x660 + i), '$i')
          .replaceAll(String.fromCharCode(0x6f0 + i), '$i');
    }
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length > widget.length
        ? digits.substring(0, widget.length)
        : digits;
  }

  void setPin(String value) {
    final pin = _clean(value);
    _controller.value = TextEditingValue(
      text: pin,
      selection: TextSelection.collapsed(offset: pin.length),
    );
    _changed(pin);
  }

  void clear() {
    _controller.clear();
    _changed('');
    _focus.requestFocus();
  }

  void _changed(String pin) {
    setState(() {});
    widget.onChanged?.call(pin);
    if (pin.length == widget.length) widget.onCompleted(pin);
  }

  @override
  void dispose() {
    _focus.removeListener(_refresh);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      height: 54,
      child: Stack(
        children: [
          Positioned.fill(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              keyboardType: TextInputType.number,
              obscureText: widget.obscureText,
              enableSuggestions: false,
              autocorrect: false,
              enableInteractiveSelection: true,
              autofillHints: widget.obscureText
                  ? null
                  : const [AutofillHints.oneTimeCode],
              inputFormatters: [
                TextInputFormatter.withFunction((oldValue, newValue) {
                  final pin = _clean(newValue.text);
                  return TextEditingValue(
                    text: pin,
                    selection: TextSelection.collapsed(offset: pin.length),
                  );
                }),
              ],
              style: const TextStyle(color: AppColors.transparent),
              cursorColor: AppColors.transparent,
              showCursor: false,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                fillColor: AppColors.transparent,
                filled: true,
                counterText: '',
              ),
              onChanged: _changed,
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Row(
                children: List.generate(widget.length, (i) {
                  final text = _controller.text;
                  final active =
                      _focus.hasFocus &&
                      i ==
                          (text.length < widget.length
                              ? text.length
                              : widget.length - 1);
                  return Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: EdgeInsets.only(
                        right: i == widget.length - 1 ? 0 : 7,
                      ),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: active
                              ? AppColors.primary
                              : AppColors.borderLight,
                          width: active ? 2 : 1,
                        ),
                      ),
                      child: Text(
                        i < text.length
                            ? (widget.obscureText ? '\u2022' : text[i])
                            : '',
                        style: const TextStyle(
                          fontSize: 24,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
