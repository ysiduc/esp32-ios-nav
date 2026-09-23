import 'package:flutter/material.dart';
import '../../models/route_model.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_typography.dart';
import 'primary_action_button.dart';

class SavedPlaceDialog extends StatefulWidget {
  final MapPlace place;
  final bool isEditing;
  final void Function(String customName) onSave;

  const SavedPlaceDialog({
    super.key,
    required this.place,
    required this.onSave,
    this.isEditing = false,
  });

  static Future<void> show({
    required BuildContext context,
    required MapPlace place,
    required void Function(String customName) onSave,
    bool isEditing = false,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SavedPlaceDialog(
        place: place,
        onSave: onSave,
        isEditing: isEditing,
      ),
    );
  }

  @override
  State<SavedPlaceDialog> createState() => _SavedPlaceDialogState();
}

class _SavedPlaceDialogState extends State<SavedPlaceDialog> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.place.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final text = _nameController.text.trim();
    final name = text.isNotEmpty ? text : widget.place.name;
    widget.onSave(name);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset + 20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.sheetTop,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4.5,
              decoration: BoxDecoration(
                color: AppColors.handleBar,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.isEditing ? 'Sửa tên địa điểm' : 'Lưu địa điểm',
                style: AppTypography.title2,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Tên địa điểm', style: AppTypography.footnote),
          const SizedBox(height: 6),
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Nhập tên (ví dụ: Nhà, Cơ quan, Quán quen...)',
              filled: true,
              fillColor: AppColors.canvas,
              contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: AppRadius.roundedMd,
                borderSide: BorderSide(color: AppColors.border, width: 0.8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.roundedMd,
                borderSide: BorderSide(color: AppColors.border, width: 0.8),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AppRadius.roundedMd,
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.place.displayName,
            style: AppTypography.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 20),
          PrimaryActionButton(
            label: widget.isEditing ? 'Cập nhật' : 'Lưu vào Danh sách',
            icon: Icons.bookmark_added_rounded,
            onPressed: _handleSave,
          ),
        ],
      ),
    );
  }
}
