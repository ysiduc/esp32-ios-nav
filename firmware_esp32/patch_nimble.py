# Pre-build patch: NimBLE terminates the whole BLE link when ANY GATT client procedure
# (ANCS/AMS/CTS discovery or CCCD write toward iOS) gets no answer within 30 s.
# iOS withholds those answers until the user allows notification sharing / pairing, which made the link
# drop + reconnect every ~32 s. Raise the timeout so a slow answer never kills the link.
import glob, os
Import("env")
root = os.path.join(env.subst("$PROJECT_LIBDEPS_DIR"), env.subst("$PIOENV"))
for f in glob.glob(os.path.join(root, "NimBLE-Arduino", "src", "nimble", "nimble", "host", "src", "ble_gattc.c")):
    s = open(f, encoding="utf-8").read()
    new = s.replace("#define BLE_GATTC_UNRESPONSIVE_TIMEOUT_MS       30000 /* ms */",
                    "#define BLE_GATTC_UNRESPONSIVE_TIMEOUT_MS       1800000 /* ms (patched) */")
    if new != s:
        open(f, "w", encoding="utf-8").write(new)
        print("patch_nimble: GATT unresponsive timeout raised to 30 min")
