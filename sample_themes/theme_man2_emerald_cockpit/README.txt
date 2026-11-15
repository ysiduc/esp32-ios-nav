HƯỚNG DẪN THEME ZIP MÀN 2 (MINIMAP CHỜ ESP32 - 320x240)
- screen: 2 (Bản đồ minimap + Panel đồng hồ/nhạc/thông báo)
- Các khối chính trong theme.json:
  * bgColor, showPanel
  * panel: {x, y, w, h, r, fill, border}
  * minimap: {x, y, w (60..144), h (60..224), r, border}
  * clock: {visible, x, y, fontSize, font, color}
  * date: {visible, x, y, color, format}
  * song: {visible, boxX, boxY, boxW, boxH, bgColor, border, color, durColor}
  * notif: {visible, x, y, w, h, fill, border, titleColor, msgColor}
- Nén bg.jpg + theme.json thành .zip -> tab Màn 2 -> "Nhập file ZIP".
