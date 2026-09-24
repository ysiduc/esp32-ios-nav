# P6.9 — RESTORE EXACT LIQUID GLASS MATERIAL FROM RUN 35895237697

## 1. Context & User Direct Reference
- **User Reference**: User attached field screenshot from workflow run `35895237697` (Head SHA: `52cee9d3dc7e9b58a98f1060c0cc9b9d1a2954b6`), circling the right-side vertical toolbar with a red box, stating:
  > *"vẫn rất đục , tôi muốn hiệu ứng liquid glass như phần khoanh trong ảnh trên ( https://github.com/ysiduc/esp32-ios-nav/actions/runs/35895237697 )"*
- **Root Cause of Visual Discrepancy**:
  In subsequent iterations (P6.6 to P6.8), custom simulated multi-layer gradient stacks (`Positioned.fill` containers, simulated highlights, and ultra-low opacities of 0.022) were introduced. On real iOS retina screens, this multi-layer composition lost the authentic frosted white glow of Apple Maps and appeared murky/dull.
  The user explicitly confirmed that the exact visual effect in workflow run `35895237697` is the true target liquid glass.

---

## 2. Restored Golden Reference Implementation

### A. Right-side Vertical Toolbar (`_buildRightSideGlassStack`)
Restored directly to the architecture from commit `52cee9d` (run 35895237697):
- **Width**: `48`
- **Border Radius**: `24` (full capsule)
- **Background Fill**: `Colors.white.withOpacity(0.85)`
- **Specular Border**: `Border.all(color: Colors.white.withOpacity(0.70), width: 0.8)`
- **Diffused Shadow**: `BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: Offset(0, 4))`
- **Backdrop Blur**: `ImageFilter.blur(sigmaX: 20, sigmaY: 20)`
- **Dividers**: `width: 26, height: 0.5, color: Colors.black.withOpacity(0.08)`
- **Recenter Circle**: `width: 40, height: 40, color: _isAutoCentering ? Color(0xFF007AFF).withOpacity(0.12) : Colors.transparent`

### B. Bottom Search Capsule (`_buildAppleBottomSearchCapsule`)
- **Height**: `50`
- **Border Radius**: `25`
- **Background Fill**: `Colors.white.withOpacity(0.88)`
- **Specular Border**: `Border.all(color: Colors.white.withOpacity(0.70), width: 0.8)`
- **Diffused Shadow**: `BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16, offset: Offset(0, 4))`
- **Backdrop Blur**: `ImageFilter.blur(sigmaX: 20, sigmaY: 20)`

### C. Drawer & Sheets (`home_screen.dart`, `map_screen.dart`)
- **Drawer Root**: `fill: isDark ? Colors.white.withOpacity(0.78) : Colors.white.withOpacity(0.85)`, right border `white 0.70 / 0.8`, blur `20.0`.
- **Search Sheet**: `fill: Color(0xFFF2F2F7).withOpacity(0.80)`, blur `20.0`, top border `white 0.60 / 0.5`.
- **Route Directions Sheet**: `fill: Colors.white.withOpacity(0.80)`, blur `20.0`.

---

## 3. Automated Verification & Status
- **Test Suites**:
  - `mobile_app/test/liquid_glass_p68_test.dart`: **7/7 passed**.
  - All 6 liquid glass suites (P6.8, P6.7, P6.6, P6.5, P6.4, P6.2): **35/35 passed**.
  - Full mobile test suite: **257/257 passed** (100%).
- **Static Analyzer**: `flutter analyze` completed with **0 issues**.
- **Firmware Compilation**: PlatformIO build esp32-s3 **SUCCESS** (RAM: 41.3%, Flash: 35.9%).
