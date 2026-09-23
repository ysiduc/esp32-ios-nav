import 'package:flutter/material.dart';
import '../../models/route_model.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_typography.dart';

class SavedPlaceTile extends StatelessWidget {
  final MapPlace place;
  final VoidCallback onTap;
  final VoidCallback onRoute;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const SavedPlaceTile({
    super.key,
    required this.place,
    required this.onTap,
    required this.onRoute,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.roundedMd,
        border: Border.all(color: AppColors.border, width: 0.8),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.roundedMd,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.bookmark_rounded, color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        place.name,
                        style: AppTypography.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        place.displayName,
                        style: AppTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Đổi tên',
                  onPressed: onRename,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                ),
                IconButton(
                  icon: const Icon(Icons.directions_rounded, size: 22, color: AppColors.primary),
                  tooltip: 'Chỉ đường',
                  onPressed: onRoute,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.danger),
                  tooltip: 'Xóa',
                  onPressed: onDelete,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
