#ifndef AMS_SERVICE_H
#define AMS_SERVICE_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "nimble/nimble/host/include/host/ble_gatt.h"
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "nimble/nimble/host/include/host/ble_uuid.h"
#include "nimble/porting/nimble/include/os/os_mbuf.h"
#include "display_ui.h"

// Apple Media Service UUID: 89D3502B-0F36-433A-8EF4-C502AD55F8DC
// Little-endian byte order for NimBLE ble_uuid128_t:
static const ble_uuid128_t amsServiceUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0xDC, 0xF8, 0x55, 0xAD, 0x02, 0xC5, 0xF4, 0x8E, 0x3A, 0x43, 0x36, 0x0F, 0x2B, 0x50, 0xD3, 0x89 }
};

// AMS Entity Update Characteristic: 2F7CABCE-808D-411F-9A0C-BB92BA96C102
static const ble_uuid128_t amsEntityUpdateUUID = {
  .u = { .type = BLE_UUID_TYPE_128 },
  .value = { 0x02, 0xC1, 0x96, 0xBA, 0x92, 0xBB, 0x0C, 0x9A, 0x1F, 0x41, 0x8D, 0x80, 0xCE, 0xAB, 0x7C, 0x2F }
};

// Solicitation data for advertising (AD Type 0x15: 128-bit Service Solicitation)
static const uint8_t amsSolicitData[] = {
  0x11, 0x15,
  0xDC, 0xF8, 0x55, 0xAD, 0x02, 0xC5, 0xF4, 0x8E,
  0x3A, 0x43, 0x36, 0x0F, 0x2B, 0x50, 0xD3, 0x89
};

extern DisplayManager display;

class AppleMediaService {
public:
  static uint16_t entityUpdateValHandle;
  static uint16_t connHandle;
  static bool isSubscribed;
  static unsigned long lastCheckTime;
  static char currentTitle[64];
  static char currentArtist[64];

  static void init() {
    entityUpdateValHandle = 0;
    connHandle = 0;
    isSubscribed = false;
    lastCheckTime = 0;
    currentTitle[0] = '\0';
    currentArtist[0] = '\0';
  }

  static void checkPeriodic() {
    if (connHandle != 0 && !isSubscribed) {
      if (millis() - lastCheckTime > 3000) {
        lastCheckTime = millis();
        Serial.printf("[AMS] Periodic check: discovering AMS on conn=%d...\n", connHandle);
        ble_gattc_disc_svc_by_uuid(connHandle, &amsServiceUUID.u, amsSvcDiscCb, NULL);
      }
    }
  }

  static void onEncrypted(uint16_t conn_hdl) {
    connHandle = conn_hdl;
    entityUpdateValHandle = 0;
    isSubscribed = false;
    Serial.printf("[AMS] Secure link established (conn=%d). Discovering Apple Media Service...\n", conn_hdl);
    int rc = ble_gattc_disc_svc_by_uuid(conn_hdl, &amsServiceUUID.u, amsSvcDiscCb, NULL);
    if (rc != 0) {
      Serial.printf("[AMS] ble_gattc_disc_svc_by_uuid failed rc=%d\n", rc);
    }
  }

  static void onDisconnected() {
    entityUpdateValHandle = 0;
    connHandle = 0;
    isSubscribed = false;
    currentTitle[0] = '\0';
    currentArtist[0] = '\0';
    Serial.println("[AMS] Device disconnected. Resetting media state.");
  }

  static int handleGapEvent(ble_gap_event *event, void *arg) {
    switch (event->type) {
      case BLE_GAP_EVENT_ENC_CHANGE:
        if (event->enc_change.status == 0) {
          onEncrypted(event->enc_change.conn_handle);
        } else {
          Serial.printf("[AMS] Encryption status=%d\n", event->enc_change.status);
        }
        break;

      case BLE_GAP_EVENT_NOTIFY_RX:
        if (entityUpdateValHandle != 0 && event->notify_rx.attr_handle == entityUpdateValHandle) {
          handleNotification(event->notify_rx.om);
        }
        break;

      default:
        break;
    }
    return 0;
  }

private:
  static int amsDscDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, uint16_t chr_val_hdl, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0 && dsc != nullptr) {
      if (ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        Serial.printf("[AMS] Found Entity Update CCCD handle: %d. Enabling notifications...\n", dsc->handle);
        uint8_t cccdVal[2] = {0x01, 0x00};
        ble_gattc_write_flat(conn_hdl, dsc->handle, cccdVal, 2, NULL, NULL);

        // Subscribe to Track Title (2) and Artist (0)
        // EntityID: 2 (Track), AttributeID: 2 (Title), AttributeID: 0 (Artist)
        uint8_t trackSubCmd[] = { 0x02, 0x02, 0x00 };
        ble_gattc_write_flat(conn_hdl, entityUpdateValHandle, trackSubCmd, sizeof(trackSubCmd), NULL, NULL);

        isSubscribed = true;
        Serial.println("[AMS] Subscribed to Track Title & Artist successfully!");
      }
    }
    return 0;
  }

  static int amsChrDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr != nullptr) {
      if (ble_uuid_cmp(&chr->uuid.u, &amsEntityUpdateUUID.u) == 0) {
        Serial.printf("[AMS] Found Entity Update characteristic! Value handle = %d\n", chr->val_handle);
        entityUpdateValHandle = chr->val_handle;
        ble_gattc_disc_all_dscs(conn_hdl, chr->val_handle, chr->val_handle + 2, amsDscDiscCb, NULL);
      }
    }
    return 0;
  }

  static int amsSvcDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg) {
    if (error->status == 0 && service != nullptr) {
      Serial.printf("[AMS] Apple Media Service found! (handles %d - %d)\n", service->start_handle, service->end_handle);
      ble_gattc_disc_all_chrs(conn_hdl, service->start_handle, service->end_handle, amsChrDiscCb, NULL);
    } else if (error->status == BLE_HS_EDONE) {
      Serial.println("[AMS] Service discovery finished.");
    }
    return 0;
  }

  static void handleNotification(struct os_mbuf *om) {
    uint16_t pktLen = OS_MBUF_PKTLEN(om);
    if (pktLen < 3) return;

    uint8_t buf[128];
    size_t copyLen = pktLen < sizeof(buf) - 1 ? pktLen : sizeof(buf) - 1;
    os_mbuf_copydata(om, 0, copyLen, buf);
    buf[copyLen] = '\0';

    uint8_t entityId = buf[0];
    uint8_t attrId = buf[1];
    const char* valStr = (const char*)(buf + 3);

    // Entity 2 = Track
    if (entityId == 2) {
      if (attrId == 2) { // Title
        strncpy(currentTitle, valStr, sizeof(currentTitle) - 1);
        currentTitle[sizeof(currentTitle) - 1] = '\0';
        Serial.printf("[AMS] Track Title: %s\n", currentTitle);
        display.setSongInfo(currentTitle, currentArtist);
      } else if (attrId == 0) { // Artist
        strncpy(currentArtist, valStr, sizeof(currentArtist) - 1);
        currentArtist[sizeof(currentArtist) - 1] = '\0';
        Serial.printf("[AMS] Track Artist: %s\n", currentArtist);
        display.setSongInfo(currentTitle, currentArtist);
      }
    }
  }
};

uint16_t AppleMediaService::entityUpdateValHandle = 0;
uint16_t AppleMediaService::connHandle = 0;
bool AppleMediaService::isSubscribed = false;
unsigned long AppleMediaService::lastCheckTime = 0;
char AppleMediaService::currentTitle[64] = "";
char AppleMediaService::currentArtist[64] = "";

#endif // AMS_SERVICE_H
