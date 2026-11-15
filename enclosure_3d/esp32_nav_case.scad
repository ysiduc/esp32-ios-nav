// =========================================================================
// Parametric 3D Enclosure for ESP32-S3 N16R8 + 2.4" TFT Touch SPI + Charger
// Units: millimeters (mm). Measure your clone PCB with calipers before printing!
// =========================================================================

// Choose part to export: "assembled", "exploded", "top", "bottom"
PART_MODE = "exploded"; // ["assembled", "exploded", "top", "bottom"]
// Battery configuration: "603450" (84x49x23mm) or "180mah" (84x49x17mm)
BATTERY_MODE = "603450"; // ["603450", "180mah"]

// --- Outer Shell Parameters ---
outer_w = 84.0;
outer_h = 49.0;
wall    = 2.0;
floor_t = 1.8;
bezel_t = 1.8;
corner_r = 3.5;

total_z = (BATTERY_MODE == "603450") ? 23.0 : 17.0;
split_z = total_z - 8.0; // Top bezel shell stays 8.0mm tall (+1.4mm snap groove)
snap_h  = 1.4;
tol     = 0.15;

// --- 2.4" TFT (MSP2402 / TJCTM24024-SPI) Parameters ---
tft_pcb_w = 77.18;
tft_pcb_h = 42.72;
win_w     = 49.6;   // Active area 48.96 + 0.64 clearance
win_h     = 37.4;   // Active area 36.72 + 0.68 clearance
win_cx    = -1.5;   // Asymmetric offset matching PCB header/SD margins

// --- Bottom Edge Cutouts (Y = -outer_h/2) ---
sw_w   = 4.4;   sw_h   = 2.6;  sw_cx   = -12.0; // SS-12D00 toggle slot
usbc_w = 9.6;   usbc_h = 3.8;  usbc_cx =  10.5; // MH-CD42 / LX-LCBST Type-C port

$fn = 36;

module rrect_extrude(w, h, r, z0, height) {
    translate([0, 0, z0])
    linear_extrude(height = height)
        offset(r = r)
            square([w - 2*r, h - 2*r], center = true);
}

module top_bezel_shell() {
    difference() {
        union() {
            rrect_extrude(outer_w, outer_h, corner_r, split_z - snap_h, 8.0 + snap_h);
        }
        // Hollow interior + snap groove matching bottom shell tongue
        rrect_extrude(outer_w - wall, outer_h - wall, max(0.5, corner_r - wall*0.5),
                      split_z - snap_h - 0.1, snap_h + 0.15);
        rrect_extrude(outer_w - 2*wall, outer_h - 2*wall, max(0.5, corner_r - wall),
                      split_z - 0.05, 8.0 - bezel_t + 0.05);
        // Active screen window cutout
        translate([win_cx, 0, total_z - bezel_t - 0.2])
            rrect_extrude(win_w, win_h, 0.8, 0, bezel_t + 0.5);
    }
}

module bottom_shell() {
    port_base_z = (BATTERY_MODE == "603450") ? 9.2 : 2.2;
    difference() {
        union() {
            rrect_extrude(outer_w, outer_h, corner_r, 0, split_z - snap_h);
            // Snap-fit tongue rim
            rrect_extrude(outer_w - wall - 2*tol, outer_h - wall - 2*tol,
                          max(0.5, corner_r - wall*0.5), split_z - snap_h, snap_h);
        }
        // Inner electronics cavity
        rrect_extrude(outer_w - 2*wall, outer_h - 2*wall, max(0.5, corner_r - wall),
                      floor_t, split_z + 0.2);
        // SS-12D00 mini slide switch slot on bottom edge
        translate([sw_cx, -outer_h/2 + wall/2, port_base_z + 0.3 + sw_h/2])
            cube([sw_w, wall + 1.0, sw_h], center = true);
        // USB Type-C charging cutout on bottom edge
        translate([usbc_cx, -outer_h/2 + wall/2, port_base_z + usbc_h/2])
            cube([usbc_w, wall + 1.0, usbc_h], center = true);
    }
}

module internal_components_preview() {
    // 1. 2.4" TFT Screen PCB (Red)
    color("crimson") translate([0, 0, split_z + 3.0])
        cube([tft_pcb_w, tft_pcb_h, 1.6], center = true);
    color("black") translate([win_cx, 0, split_z + 4.9])
        cube([48.96, 36.72, 2.2], center = true);
    // 2. ESP32-S3 N16R8 (Antenna at +X clear of battery)
    esp_z = (BATTERY_MODE == "603450") ? 9.0 : 1.8;
    color("dimgray") translate([10.1, 8.5, esp_z + 2.6])
        cube([57.2, 28.0, 5.2], center = true);
    // 3. MH-CD42 / LX-LCBST Charger + SS-12D00 Switch
    color("teal") translate([usbc_cx, -14.5, esp_z + 2.0])
        cube([25.0, 16.0, 4.0], center = true);
    color("gold") translate([sw_cx, -20.5, esp_z + 1.9])
        cube([8.0, 4.0, 3.8], center = true);
    // 4. LiPo Battery
    if (BATTERY_MODE == "603450") {
        color("silver") translate([-13.5, 0, 1.8 + 3.0])
            cube([50.0, 34.0, 6.0], center = true);
    } else {
        color("silver") translate([-29.5, 7.5, 1.8 + 2.0])
            cube([20.0, 30.0, 4.0], center = true);
    }
}

if (PART_MODE == "top") {
    rotate([180, 0, 0]) translate([0, 0, -total_z]) top_bezel_shell();
} else if (PART_MODE == "bottom") {
    bottom_shell();
} else if (PART_MODE == "assembled") {
    color("steelblue", 0.35) top_bezel_shell();
    color("slategray", 0.35) bottom_shell();
    internal_components_preview();
} else {
    translate([0, 0, 14]) color("steelblue", 0.4) top_bezel_shell();
    color("slategray", 0.4) bottom_shell();
    translate([0, 0, 6]) internal_components_preview();
}

