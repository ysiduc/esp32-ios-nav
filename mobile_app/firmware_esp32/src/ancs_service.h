#ifndef ANCS_SERVICE_H
#define ANCS_SERVICE_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "nimble/nimble/host/include/host/ble_gatt.h"
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "nimble/nimble/host/include/host/ble_uuid.h"
#include "nimble/porting/nimble/include/os/os_mbuf.h"
#include "display_ui.h"

// Apple Notification Center Service (ANCS) UUID: 7905F431-B5CE-4E99-A40F-4B1E122D00D0
// Little-endian byte order:
static const ble_uuid128_t ancsServiceUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4, 0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79 }
};

// Notification Source: 9FBF120D-6301-42D9-8C58-25E699A21DBD (Notify)
static const ble_uuid128_t ancsNotifSourceUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0xBD, 0x1D, 0xA2, 0x99, 0xE6, 0x25, 0x58, 0x8C, 0xD9, 0x42, 0x01, 0x63, 0x0D, 0x12, 0xBF, 0x9F }
};

// Control Point: 69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9 (Write)
static const ble_uuid128_t ancsControlPointUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0xD9, 0xD9, 0xAA, 0xFD, 0xBD, 0x9B, 0x21, 0x98, 0xA8, 0x49, 0xE1, 0x45, 0xF3, 0xD8, 0xD1, 0x69 }
};

// Data Source: 22EAC6E9-24D6-4BB5-BE44-44BE24487841 (Notify)
static const ble_uuid128_t ancsDataSourceUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0x41, 0x78, 0x48, 0x24, 0xBE, 0x44, 0x44, 0xBE, 0xB5, 0x4B, 0xD6, 0x24, 0xE9, 0xC6, 0xEA, 0x22 }
};

extern DisplayManager display;

class AppleNotificationService {
public:
  static uint16_t notifSourceValHandle;
  static uint16_t controlPointValHandle;
  static uint16_t dataSourceValHandle;
  static uint16_t connHandle;
  static bool isSubscribed;
  static unsigned long lastCheckTime;

  // Pending notification context
  static uint32_t pendingUID;
  static uint8_t pendingCategoryID;
  static char currentTitle[64];
  static char currentMessage[128];

  static void init() {
    notifSourceValHandle = 0;
    controlPointValHandle = 0;
    dataSourceValHandle = 0;
    connHandle = 0;
    isSubscribed = false;
    lastCheckTime = 0;
    pendingUID = 0;
    pendingCategoryID = 0;
    currentTitle[0] = '\0';
    currentMessage[0] = '\0';
  }

  static void onEncrypted(uint16_t conn_hdl) {
    connHandle = conn_hdl;
    notifSourceValHandle = 0;
    controlPointValHandle = 0;
    dataSourceValHandle = 0;
    isSubscribed = false;
    Serial.printf("[ANCS] Secure link established (conn=%d). Discovering ANCS...\n", conn_hdl);
    ble_gattc_disc_svc_by_uuid(conn_hdl, &ancsServiceUUID.u, ancsSvcDiscCb, NULL);
  }

  static void onDisconnected() {
    init();
    Serial.println("[ANCS] Device disconnected. Resetting ANCS state.");
  }

  static void checkPeriodic() {
    if (connHandle != 0 && !isSubscribed) {
      if (millis() - lastCheckTime > 5000) {
        lastCheckTime = millis();
        Serial.printf("[ANCS] Periodic check: discovering ANCS on conn=%d...\n", connHandle);
        ble_gattc_disc_svc_by_uuid(connHandle, &ancsServiceUUID.u, ancsSvcDiscCb, NULL);
      }
    }
  }

  static int handleGapEvent(ble_gap_event *event, void *arg) {
    if (event->type == BLE_GAP_EVENT_NOTIFY_RX) {
      if (notifSourceValHandle != 0 && event->notify_rx.attr_handle == notifSourceValHandle) {
        handleNotifSource(event->notify_rx.om);
      } else if (dataSourceValHandle != 0 && event->notify_rx.attr_handle == dataSourceValHandle) {
        handleDataSource(event->notify_rx.om);
      }
    }
    return 0;
  }

private:
  static int ancsDscDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, uint16_t chr_val_hdl, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0 && dsc != nullptr) {
      if (ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        uint8_t cccdVal[2] = {0x01, 0x00}; // Enable Notifications
        ble_gattc_write_flat(conn_hdl, dsc->handle, cccdVal, 2, NULL, NULL);
        Serial.printf("[ANCS] Enabled notifications on CCCD handle %d for chr %d\n", dsc->handle, chr_val_hdl);
        isSubscribed = true;
      }
    }
    return 0;
  }

  static int ancsChrDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr != nullptr) {
      if (ble_uuid_cmp(&chr->uuid.u, &ancsNotifSourceUUID.u) == 0) {
        Serial.printf("[ANCS] Found Notification Source: handle=%d\n", chr->val_handle);
        notifSourceValHandle = chr->val_handle;
        ble_gattc_disc_all_dscs(conn_hdl, chr->val_handle, chr->val_handle + 2, ancsDscDiscCb, NULL);
      } else if (ble_uuid_cmp(&chr->uuid.u, &ancsControlPointUUID.u) == 0) {
        Serial.printf("[ANCS] Found Control Point: handle=%d\n", chr->val_handle);
        controlPointValHandle = chr->val_handle;
      } else if (ble_uuid_cmp(&chr->uuid.u, &ancsDataSourceUUID.u) == 0) {
        Serial.printf("[ANCS] Found Data Source: handle=%d\n", chr->val_handle);
        dataSourceValHandle = chr->val_handle;
        ble_gattc_disc_all_dscs(conn_hdl, chr->val_handle, chr->val_handle + 2, ancsDscDiscCb, NULL);
      }
    }
    return 0;
  }

  static int ancsSvcDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg) {
    if (error->status == 0 && service != nullptr) {
      Serial.printf("[ANCS] Apple Notification Center Service found! (handles %d - %d)\n", service->start_handle, service->end_handle);
      ble_gattc_disc_all_chrs(conn_hdl, service->start_handle, service->end_handle, ancsChrDiscCb, NULL);
    }
    return 0;
  }

  static void handleNotifSource(struct os_mbuf *om) {
    uint16_t pktLen = OS_MBUF_PKTLEN(om);
    if (pktLen < 8) return;

    uint8_t buf[8];
    os_mbuf_copydata(om, 0, 8, buf);

    uint8_t eventId = buf[0];
    uint8_t categoryId = buf[2];
    uint32_t uid = (uint32_t)buf[4] | ((uint32_t)buf[5] << 8) | ((uint32_t)buf[6] << 16) | ((uint32_t)buf[7] << 24);

    Serial.printf("[ANCS] Event=%d, Category=%d, UID=%lu\n", eventId, categoryId, (unsigned long)uid);

    // Event 0: Notification Added
    if (eventId == 0) {
      pendingUID = uid;
      pendingCategoryID = categoryId;
      currentTitle[0] = '\0';
      currentMessage[0] = '\0';

      // Request attributes: Title (Attr 1), Subtitle (Attr 2), Message (Attr 3)
      if (controlPointValHandle != 0) {
        uint8_t cmd[14];
        cmd[0] = 0x00; // CommandIDGetNotificationAttributes
        memcpy(&cmd[1], &buf[4], 4); // 4-byte UID
        cmd[5] = 0x01; // Attr 1: Title
        cmd[6] = 32; cmd[7] = 0; // max 32 bytes
        cmd[8] = 0x02; // Attr 2: Subtitle
        cmd[9] = 32; cmd[10] = 0;
        cmd[11] = 0x03; // Attr 3: Message
        cmd[12] = 64; cmd[13] = 0; // max 64 bytes

        ble_gattc_write_flat(connHandle, controlPointValHandle, cmd, sizeof(cmd), NULL, NULL);
        Serial.printf("[ANCS] Sent GetNotificationAttributes for UID=%lu\n", (unsigned long)uid);
      }
    }
    // Event 2: Notification Removed (Call ended / dismissed)
    else if (eventId == 2) {
      if (categoryId == 1) { // Incoming Call ended
        Serial.println("[ANCS] Call ended, clearing alert.");
      }
    }
  }

  static void handleDataSource(struct os_mbuf *om) {
    uint16_t pktLen = OS_MBUF_PKTLEN(om);
    if (pktLen < 5) return;

    uint8_t buf[256];
    size_t copyLen = pktLen < sizeof(buf) - 1 ? pktLen : sizeof(buf) - 1;
    os_mbuf_copydata(om, 0, copyLen, buf);
    buf[copyLen] = '\0';

    if (buf[0] != 0x00) return; // CommandID check

    size_t offset = 5; // Skip CommandID (1) + UID (4)
    while (offset + 3 <= copyLen) {
      uint8_t attrId = buf[offset];
      uint16_t attrLen = (uint16_t)buf[offset + 1] | ((uint16_t)buf[offset + 2] << 8);
      offset += 3;

      if (offset + attrLen > copyLen) {
        attrLen = copyLen - offset;
      }

      char attrStr[128];
      size_t safeLen = attrLen < sizeof(attrStr) - 1 ? attrLen : sizeof(attrStr) - 1;
      memcpy(attrStr, &buf[offset], safeLen);
      attrStr[safeLen] = '\0';
      offset += attrLen;

      if (attrId == 1) { // Title (Caller name or Message sender)
        strncpy(currentTitle, attrStr, sizeof(currentTitle) - 1);
        currentTitle[sizeof(currentTitle) - 1] = '\0';
      } else if (attrId == 2) { // Subtitle
        if (currentTitle[0] == '\0') {
          strncpy(currentTitle, attrStr, sizeof(currentTitle) - 1);
        }
      } else if (attrId == 3) { // Message (Phone number or Message content)
        strncpy(currentMessage, attrStr, sizeof(currentMessage) - 1);
        currentMessage[sizeof(currentMessage) - 1] = '\0';
      }
    }

    Serial.printf("[ANCS] Details -> Cat=%d, Title: '%s', Msg: '%s'\n", pendingCategoryID, currentTitle, currentMessage);

    if (pendingCategoryID == 1) { // Category 1: Incoming Call
      const char* name = currentTitle[0] != '\0' ? currentTitle : "Cuoc goi den";
      const char* phone = currentMessage[0] != '\0' ? currentMessage : "Dang do chuong...";
      display.showCallAlert(name, phone);
    } else if (pendingCategoryID == 2) { // Category 2: Missed Call
      const char* name = currentTitle[0] != '\0' ? currentTitle : "Cuoc goi nho";
      display.showCallAlert("Cuoc goi nho", name);
    } else { // Category 0 (Other/SMS), 4 (Social - Zalo/iMessage), 6 (Email)
      const char* sender = currentTitle[0] != '\0' ? currentTitle : "Tin nhan";
      const char* content = currentMessage[0] != '\0' ? currentMessage : "Thong bao moi";
      display.showSmsAlert(sender, content);
    }
  }
};

uint16_t AppleNotificationService::notifSourceValHandle = 0;
uint16_t AppleNotificationService::controlPointValHandle = 0;
uint16_t AppleNotificationService::dataSourceValHandle = 0;
uint16_t AppleNotificationService::connHandle = 0;
bool AppleNotificationService::isSubscribed = false;
unsigned long AppleNotificationService::lastCheckTime = 0;
uint32_t AppleNotificationService::pendingUID = 0;
uint8_t AppleNotificationService::pendingCategoryID = 0;
char AppleNotificationService::currentTitle[64] = "";
char AppleNotificationService::currentMessage[128] = "";

#endif // ANCS_SERVICE_H
