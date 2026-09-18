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

// Data Source: 22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB (Notify)
static const ble_uuid128_t ancsDataSourceUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0xFB, 0x7B, 0x7C, 0xCE, 0x6A, 0xB3, 0x44, 0xBE, 0xB5, 0x4B, 0xD6, 0x24, 0xE9, 0xC6, 0xEA, 0x22 }
};

// Solicitation data for ANCS advertising (AD Type 0x15: 128-bit Service Solicitation)
static const uint8_t ancsSolicitData[] = {
  0x11, 0x15,
  0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4, 0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79
};

extern DisplayManager display;

class AppleNotificationService {
public:
  static uint16_t notifSourceValHandle;
  static uint16_t notifSourceCccdHandle;
  static uint16_t controlPointValHandle;
  static uint16_t dataSourceValHandle;
  static uint16_t dataSourceCccdHandle;
  static uint16_t connHandle;
  static bool isSubscribed;
  static bool isDiscovering;
  static unsigned long lastCheckTime;

  static uint16_t svcStartHandle;
  static uint16_t svcEndHandle;

  // Pending notification context
  static uint32_t pendingUID;
  static uint8_t pendingCategoryID;
  static char currentTitle[64];
  static char currentMessage[128];
  static char currentAppId[64];

  // ANCS Data Source multi-packet stream accumulator
  static uint8_t dsStreamBuf[512];
  static uint16_t dsStreamLen;
  static uint32_t dsStreamUid;
  static unsigned long dsLastRxTime;
  static bool dsStreamActive;

  // Pending attribute request queue
  static uint32_t pendingAttrUid;
  static bool pendingAttrActive;
  static unsigned long pendingAttrLastTry;

  static void init() {
    notifSourceValHandle = 0;
    notifSourceCccdHandle = 0;
    controlPointValHandle = 0;
    dataSourceValHandle = 0;
    dataSourceCccdHandle = 0;
    connHandle = 0;
    isSubscribed = false;
    isDiscovering = false;
    lastCheckTime = 0;
    svcStartHandle = 0;
    svcEndHandle = 0;
    pendingUID = 0;
    pendingCategoryID = 0;
    currentTitle[0] = '\0';
    currentMessage[0] = '\0';
    currentAppId[0] = '\0';
    dsStreamLen = 0;
    dsStreamUid = 0;
    dsLastRxTime = 0;
    dsStreamActive = false;
    pendingAttrUid = 0;
    pendingAttrActive = false;
    pendingAttrLastTry = 0;
  }

  static void startDiscovery(uint16_t conn_hdl) {
    if (isSubscribed) return;
    if (isDiscovering) return;
    connHandle = conn_hdl;
    isDiscovering = true;
    notifSourceValHandle = 0;
    notifSourceCccdHandle = 0;
    controlPointValHandle = 0;
    dataSourceValHandle = 0;
    dataSourceCccdHandle = 0;
    svcStartHandle = 0;
    svcEndHandle = 0;
    Serial.printf("[ANCS] Discovering ANCS service on conn=%d...\n", conn_hdl);
    int rc = ble_gattc_disc_svc_by_uuid(conn_hdl, &ancsServiceUUID.u, ancsSvcDiscCb, NULL);
    if (rc != 0) {
      Serial.printf("[ANCS] ble_gattc_disc_svc_by_uuid failed rc=%d\n", rc);
      isDiscovering = false;
    }
  }

  static void onEncrypted(uint16_t conn_hdl) {
    connHandle = conn_hdl;
    startDiscovery(conn_hdl);
  }

  static void onDisconnected() {
    init();
    Serial.println("[ANCS] Device disconnected. Resetting ANCS state.");
  }

  static void checkPeriodic() {
    // 1. If stream is active and no new chunk arrived for 100ms, dispatch what we have collected!
    if (dsStreamActive && (millis() - dsLastRxTime > 100)) {
      dsStreamActive = false;
      dispatchNotification();
    }

    // 2. If attribute request was queued (GATT busy or link establishing), retry it every 250ms
    if (pendingAttrActive && controlPointValHandle != 0 && connHandle != 0 && (millis() - pendingAttrLastTry > 250)) {
      pendingAttrLastTry = millis();
      if (sendNotificationAttributeRequest(pendingAttrUid)) {
        pendingAttrActive = false;
        Serial.printf("[ANCS] Pending attribute request dispatched for UID=%lu\n", (unsigned long)pendingAttrUid);
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

  static bool sendNotificationAttributeRequest(uint32_t uid) {
    if (controlPointValHandle == 0 || connHandle == 0) return false;

    uint8_t cmd[15];
    cmd[0] = 0x00; // CommandIDGetNotificationAttributes
    cmd[1] = (uint8_t)(uid & 0xFF);
    cmd[2] = (uint8_t)((uid >> 8) & 0xFF);
    cmd[3] = (uint8_t)((uid >> 16) & 0xFF);
    cmd[4] = (uint8_t)((uid >> 24) & 0xFF);
    cmd[5] = 0x00; // Attr 0: AppIdentifier (no length param)
    cmd[6] = 0x01; // Attr 1: Title
    cmd[7] = 64; cmd[8] = 0; // max 64 bytes
    cmd[9] = 0x02; // Attr 2: Subtitle
    cmd[10] = 32; cmd[11] = 0; // max 32 bytes
    cmd[12] = 0x03; // Attr 3: Message
    cmd[13] = 128; cmd[14] = 0; // max 128 bytes

    int rc = ble_gattc_write_flat(connHandle, controlPointValHandle, cmd, sizeof(cmd), ancsCpWriteCb, NULL);
    Serial.printf("[ANCS] Sent GetNotificationAttributes for UID=%lu (rc=%d)\n", (unsigned long)uid, rc);
    return (rc == 0);
  }

private:
  static int ancsCpWriteCb(uint16_t conn_hdl, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status != 0) {
      Serial.printf("[ANCS] Control Point write error status=%d\n", error->status);
    } else {
      Serial.println("[ANCS] Control Point write ACK received from iPhone.");
    }
    return 0;
  }

  static int ancsNotifCccdWriteCb(uint16_t conn_hdl, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    isDiscovering = false;
    if (error->status == 0) {
      isSubscribed = true;
      Serial.println("[ANCS] BOTH Notification Source & Data Source CCCDs enabled! ANCS fully active.");
    } else {
      Serial.printf("[ANCS] Notification Source CCCD write error status=%d\n", error->status);
    }
    return 0;
  }

  static void subscribeNotificationSource(uint16_t conn_hdl) {
    if (notifSourceCccdHandle != 0) {
      Serial.printf("[ANCS] Step 2/2: Subscribing to Notification Source CCCD handle %d...\n", notifSourceCccdHandle);
      static uint8_t cccdVal[2] = {0x01, 0x00};
      int rc = ble_gattc_write_flat(conn_hdl, notifSourceCccdHandle, cccdVal, 2, ancsNotifCccdWriteCb, NULL);
      if (rc != 0) {
        Serial.printf("[ANCS] Failed to write Notif CCCD, rc=%d\n", rc);
        isDiscovering = false;
      }
    } else {
      Serial.println("[ANCS] Notification Source CCCD not found.");
      isDiscovering = false;
    }
  }

  static int ancsDataCccdWriteCb(uint16_t conn_hdl, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status == 0) {
      Serial.println("[ANCS] Data Source CCCD enabled successfully.");
    } else {
      Serial.printf("[ANCS] Data Source CCCD write error status=%d\n", error->status);
    }
    // Now subscribe to Notification Source CCCD
    subscribeNotificationSource(conn_hdl);
    return 0;
  }

  static void subscribeDataAndNotifSource(uint16_t conn_hdl) {
    if (dataSourceCccdHandle != 0) {
      Serial.printf("[ANCS] Step 1/2: Subscribing to Data Source CCCD handle %d...\n", dataSourceCccdHandle);
      static uint8_t cccdVal[2] = {0x01, 0x00};
      int rc = ble_gattc_write_flat(conn_hdl, dataSourceCccdHandle, cccdVal, 2, ancsDataCccdWriteCb, NULL);
      if (rc != 0) {
        Serial.printf("[ANCS] Failed to write Data Source CCCD, rc=%d. Proceeding to Notif CCCD...\n", rc);
        subscribeNotificationSource(conn_hdl);
      }
    } else {
      subscribeNotificationSource(conn_hdl);
    }
  }

  static int ancsDscDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, uint16_t chr_val_hdl, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0 && dsc != nullptr) {
      if (ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        Serial.printf("[ANCS] Found CCCD (0x2902) handle: %d\n", dsc->handle);
        if (dsc->handle > notifSourceValHandle && (controlPointValHandle == 0 || dsc->handle < controlPointValHandle)) {
          notifSourceCccdHandle = dsc->handle;
          Serial.printf("[ANCS] Identified Notification Source CCCD: %d\n", notifSourceCccdHandle);
        } else if (dsc->handle > dataSourceValHandle && dsc->handle <= svcEndHandle) {
          dataSourceCccdHandle = dsc->handle;
          Serial.printf("[ANCS] Identified Data Source CCCD: %d\n", dataSourceCccdHandle);
        }
      }
    } else if (error->status == BLE_HS_EDONE || dsc == nullptr) {
      // Guaranteed fallbacks: CCCD descriptor is always at val_handle + 1 in standard GATT
      if (notifSourceCccdHandle == 0 && notifSourceValHandle != 0) {
        notifSourceCccdHandle = notifSourceValHandle + 1;
        Serial.printf("[ANCS] Fallback Notif Source CCCD handle: %d\n", notifSourceCccdHandle);
      }
      if (dataSourceCccdHandle == 0 && dataSourceValHandle != 0) {
        dataSourceCccdHandle = dataSourceValHandle + 1;
        Serial.printf("[ANCS] Fallback Data Source CCCD handle: %d\n", dataSourceCccdHandle);
      }

      Serial.printf("[ANCS] Descriptor discovery complete. NotifCCCD=%d, DataCCCD=%d\n",
                    notifSourceCccdHandle, dataSourceCccdHandle);
      subscribeDataAndNotifSource(conn_hdl);
    }
    return 0;
  }

  static int ancsChrDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr != nullptr) {
      if (ble_uuid_cmp(&chr->uuid.u, &ancsNotifSourceUUID.u) == 0) {
        Serial.printf("[ANCS] Found Notification Source: handle=%d\n", chr->val_handle);
        notifSourceValHandle = chr->val_handle;
      } else if (ble_uuid_cmp(&chr->uuid.u, &ancsControlPointUUID.u) == 0) {
        Serial.printf("[ANCS] Found Control Point: handle=%d\n", chr->val_handle);
        controlPointValHandle = chr->val_handle;
      } else if (ble_uuid_cmp(&chr->uuid.u, &ancsDataSourceUUID.u) == 0) {
        Serial.printf("[ANCS] Found Data Source: handle=%d\n", chr->val_handle);
        dataSourceValHandle = chr->val_handle;
      }
    } else if (error->status == BLE_HS_EDONE || chr == nullptr) {
      Serial.printf("[ANCS] Chrs discovered: Notif=%d, Ctrl=%d, Data=%d\n",
                    notifSourceValHandle, controlPointValHandle, dataSourceValHandle);
      if (notifSourceValHandle != 0 && svcStartHandle != 0 && svcEndHandle != 0) {
        // Discover all descriptors across the whole ANCS service in a single range [svcStartHandle, svcEndHandle]
        Serial.printf("[ANCS] Discovering all descriptors in ANCS range %d-%d...\n", svcStartHandle, svcEndHandle);
        int rc = ble_gattc_disc_all_dscs(conn_hdl, svcStartHandle, svcEndHandle, ancsDscDiscCb, NULL);
        if (rc != 0) {
          Serial.printf("[ANCS] ble_gattc_disc_all_dscs failed rc=%d\n", rc);
          // Apply fallback immediately if discovery cannot be queued
          notifSourceCccdHandle = notifSourceValHandle + 1;
          dataSourceCccdHandle = (dataSourceValHandle != 0) ? (dataSourceValHandle + 1) : 0;
          subscribeDataAndNotifSource(conn_hdl);
        }
      } else {
        Serial.println("[ANCS] Required characteristics or service range missing.");
        isDiscovering = false;
      }
    }
    return 0;
  }

  static int ancsSvcDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg) {
    if (error->status == 0 && service != nullptr) {
      Serial.printf("[ANCS] Apple Notification Center Service found! (handles %d - %d)\n", service->start_handle, service->end_handle);
      svcStartHandle = service->start_handle;
      svcEndHandle = service->end_handle;
    } else if (error->status == BLE_HS_EDONE || service == nullptr) {
      if (svcStartHandle != 0) {
        int rc = ble_gattc_disc_all_chrs(conn_hdl, svcStartHandle, svcEndHandle, ancsChrDiscCb, NULL);
        if (rc != 0) {
          Serial.printf("[ANCS] ble_gattc_disc_all_chrs failed rc=%d\n", rc);
          isDiscovering = false;
        }
      } else {
        Serial.println("[ANCS] ANCS Service not found on this connection.");
        isDiscovering = false;
      }
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

    // Event 0: Notification Added, Event 1: Notification Modified
    if (eventId == 0 || eventId == 1) {
      pendingUID = uid;
      pendingCategoryID = categoryId;
      currentTitle[0] = '\0';
      currentMessage[0] = '\0';
      currentAppId[0] = '\0';

      // Reset stream accumulator for this notification
      dsStreamLen = 0;
      dsStreamUid = uid;
      dsStreamActive = true;
      dsLastRxTime = millis();

      // For incoming calls, pop up immediately with generic status so display responds in <5ms!
      // When Data Source stream finishes parsing caller name, it updates seamlessly.
      if (categoryId == 1) {
        display.showCallAlert("Cuộc gọi đến", "đang gọi đến...", APP_SOURCE_SIM);
      }

      // Request attributes: AppID (Attr 0), Title (Attr 1), Subtitle (Attr 2), Message (Attr 3)
      bool sent = sendNotificationAttributeRequest(uid);
      if (!sent) {
        pendingAttrUid = uid;
        pendingAttrActive = true;
        pendingAttrLastTry = millis();
        Serial.printf("[ANCS] Attribute request queued for UID=%lu (waiting for link ready)\n", (unsigned long)uid);
      }
    }
    // Event 2: Notification Removed (Call ended / dismissed on phone)
    else if (eventId == 2) {
      Serial.printf("[ANCS] Notification removed: Category=%d, UID=%lu\n", categoryId, (unsigned long)uid);
      if (categoryId == 1 || categoryId == 2 || (display.isCallActive() && uid == pendingUID) || display.isCallActive()) {
        Serial.println("[ANCS] Call notification dismissed or call ended on phone, clearing alert immediately.");
        display.dismissAlert();
      }
    }
  }

  static void handleDataSource(struct os_mbuf *om) {
    uint16_t pktLen = OS_MBUF_PKTLEN(om);
    if (pktLen == 0) return;

    uint8_t chunk[256];
    size_t copyLen = pktLen < sizeof(chunk) ? pktLen : sizeof(chunk);
    os_mbuf_copydata(om, 0, copyLen, chunk);

    // If chunk starts with CommandID 0x00 and length >= 5, this is the first packet of a response
    if (copyLen >= 5 && chunk[0] == 0x00) {
      uint32_t uid = (uint32_t)chunk[1] | ((uint32_t)chunk[2] << 8) | ((uint32_t)chunk[3] << 16) | ((uint32_t)chunk[4] << 24);
      dsStreamUid = uid;
      dsStreamLen = 0;
      dsStreamActive = true;
      currentTitle[0] = '\0';
      currentMessage[0] = '\0';
      currentAppId[0] = '\0';
    }

    if (!dsStreamActive) return;

    // Append chunk to stream buffer
    if (dsStreamLen + copyLen <= sizeof(dsStreamBuf)) {
      memcpy(dsStreamBuf + dsStreamLen, chunk, copyLen);
      dsStreamLen += copyLen;
    } else {
      size_t rem = sizeof(dsStreamBuf) - dsStreamLen;
      if (rem > 0) {
        memcpy(dsStreamBuf + dsStreamLen, chunk, rem);
        dsStreamLen += rem;
      }
    }
    dsLastRxTime = millis();

    // Parse attributes received so far
    parseDataSourceStream();
  }

  static void parseDataSourceStream() {
    if (!dsStreamActive || dsStreamLen < 5) return;
    if (dsStreamBuf[0] != 0x00) return;

    size_t offset = 5; // Skip CommandID (1) + UID (4)
    bool hasTitle = false;
    bool hasMessage = false;

    while (offset + 3 <= dsStreamLen) {
      uint8_t attrId = dsStreamBuf[offset];
      uint16_t attrLen = (uint16_t)dsStreamBuf[offset + 1] | ((uint16_t)dsStreamBuf[offset + 2] << 8);

      if (offset + 3 + attrLen > dsStreamLen) {
        // Attribute is split across BLE packets; wait for continuation packets
        return;
      }

      const uint8_t* valPtr = &dsStreamBuf[offset + 3];
      if (attrId == 0) { // AppIdentifier
        size_t safeLen = attrLen < sizeof(currentAppId) - 1 ? attrLen : sizeof(currentAppId) - 1;
        memcpy(currentAppId, valPtr, safeLen);
        currentAppId[safeLen] = '\0';
      } else if (attrId == 1) { // Title (Caller name or Message sender)
        size_t safeLen = attrLen < sizeof(currentTitle) - 1 ? attrLen : sizeof(currentTitle) - 1;
        memcpy(currentTitle, valPtr, safeLen);
        currentTitle[safeLen] = '\0';
        hasTitle = true;
      } else if (attrId == 2) { // Subtitle
        if (currentTitle[0] == '\0') {
          size_t safeLen = attrLen < sizeof(currentTitle) - 1 ? attrLen : sizeof(currentTitle) - 1;
          memcpy(currentTitle, valPtr, safeLen);
          currentTitle[safeLen] = '\0';
          hasTitle = true;
        }
      } else if (attrId == 3) { // Message (Phone number or Message text)
        size_t safeLen = attrLen < sizeof(currentMessage) - 1 ? attrLen : sizeof(currentMessage) - 1;
        memcpy(currentMessage, valPtr, safeLen);
        currentMessage[safeLen] = '\0';
        hasMessage = true;
      }

      offset += 3 + attrLen;
    }

    // Complete if we have both Title and Message, or for Call if we have Title, or if offset reaches end
    if ((pendingCategoryID == 1 && hasTitle) || (hasTitle && hasMessage) || (offset >= dsStreamLen && (hasTitle || hasMessage))) {
      dsStreamActive = false;
      dispatchNotification();
    }
  }

  static void dispatchNotification() {
    AppSourceType appType = APP_SOURCE_OTHER;
    String appIdLower = String(currentAppId);
    appIdLower.toLowerCase();

    if (appIdLower.indexOf("zalo") >= 0) {
      appType = APP_SOURCE_ZALO;
    } else if (appIdLower.indexOf("messenger") >= 0 || appIdLower.indexOf("orca") >= 0) {
      appType = APP_SOURCE_MESSENGER;
    } else if (appIdLower.indexOf("mobilesms") >= 0 || appIdLower.indexOf("sms") >= 0 || appIdLower.indexOf("messages") >= 0) {
      appType = APP_SOURCE_SMS;
    } else if (appIdLower.indexOf("mobilephone") >= 0 || appIdLower.indexOf("phone") >= 0 || appIdLower.indexOf("facetime") >= 0 || appIdLower.indexOf("telephony") >= 0) {
      appType = APP_SOURCE_SIM;
    } else if (pendingCategoryID == 1 || pendingCategoryID == 2) {
      appType = APP_SOURCE_SIM;
    } else {
      appType = APP_SOURCE_SMS;
    }

    Serial.printf("[ANCS] Dispatched -> Cat=%d, App: '%s' (type=%d), Title: '%s', Msg: '%s'\n",
                  pendingCategoryID, currentAppId, (int)appType, currentTitle, currentMessage);

    if (pendingCategoryID == 1) { // Incoming Call
      const char* name = currentTitle[0] != '\0' ? currentTitle : "Cuộc gọi đến";
      const char* phone = currentMessage[0] != '\0' ? currentMessage : "đang gọi đến...";
      if (display.isCallActive()) {
        display.updatePopupDetails(name, phone, appType);
      } else {
        display.showCallAlert(name, phone, appType);
      }
    } else if (pendingCategoryID == 2) { // Missed Call
      const char* name = currentTitle[0] != '\0' ? currentTitle : "Cuộc gọi nhỡ";
      display.showCallAlert("Cuộc gọi nhỡ", name, appType);
    } else { // Messages & Social Notifications (Category 0, 4, 6, etc.)
      const char* sender = currentTitle[0] != '\0' ? currentTitle : "Tin nhắn";
      const char* content = currentMessage[0] != '\0' ? currentMessage : "Thông báo mới";
      display.showSmsAlert(sender, content, appType);
    }
  }
};

uint16_t AppleNotificationService::notifSourceValHandle = 0;
uint16_t AppleNotificationService::notifSourceCccdHandle = 0;
uint16_t AppleNotificationService::controlPointValHandle = 0;
uint16_t AppleNotificationService::dataSourceValHandle = 0;
uint16_t AppleNotificationService::dataSourceCccdHandle = 0;
uint16_t AppleNotificationService::connHandle = 0;
bool AppleNotificationService::isSubscribed = false;
bool AppleNotificationService::isDiscovering = false;
unsigned long AppleNotificationService::lastCheckTime = 0;
uint16_t AppleNotificationService::svcStartHandle = 0;
uint16_t AppleNotificationService::svcEndHandle = 0;
uint32_t AppleNotificationService::pendingUID = 0;
uint8_t AppleNotificationService::pendingCategoryID = 0;
char AppleNotificationService::currentTitle[64] = "";
char AppleNotificationService::currentMessage[128] = "";
char AppleNotificationService::currentAppId[64] = "";
uint8_t AppleNotificationService::dsStreamBuf[512];
uint16_t AppleNotificationService::dsStreamLen = 0;
uint32_t AppleNotificationService::dsStreamUid = 0;
unsigned long AppleNotificationService::dsLastRxTime = 0;
bool AppleNotificationService::dsStreamActive = false;
uint32_t AppleNotificationService::pendingAttrUid = 0;
bool AppleNotificationService::pendingAttrActive = false;
unsigned long AppleNotificationService::pendingAttrLastTry = 0;

#endif // ANCS_SERVICE_H
