import 'package:flutter/material.dart';

class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;

  static const EdgeInsets p4 = EdgeInsets.all(xs);
  static const EdgeInsets p8 = EdgeInsets.all(sm);
  static const EdgeInsets p12 = EdgeInsets.all(md);
  static const EdgeInsets p16 = EdgeInsets.all(lg);
  static const EdgeInsets p20 = EdgeInsets.all(xl);
  static const EdgeInsets p24 = EdgeInsets.all(xxl);

  static const EdgeInsets ph16pv12 = EdgeInsets.symmetric(horizontal: lg, vertical: md);
  static const EdgeInsets ph16pv8 = EdgeInsets.symmetric(horizontal: lg, vertical: sm);
  static const EdgeInsets ph12pv8 = EdgeInsets.symmetric(horizontal: md, vertical: sm);
  static const EdgeInsets ph20pv16 = EdgeInsets.symmetric(horizontal: xl, vertical: lg);
}
