#ifndef CTS_SERVICE_H
#define CTS_SERVICE_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "nimble/nimble/host/include/host/ble_gatt.h"
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "nimble/nimble/host/include/host/ble_uuid.h"
#include "nimble/porting/nimble/include/os/os_mbuf.h"
#include "display_ui.h"
#include "ancs_service.h"

// Standard Current Time Service UUID: 0x1805
static const ble_uuid16_t ctsServiceUUID = {
  .u = { .type = BLE_UUID_TYPE_16 },
  .value = 0x1805
};

// Current Time Characteristic UUID: 0x2A2B
static const ble_uuid16_t ctsCurrentTimeUUID = {
  .u = { .type = BLE_UUID_TYPE_16 },
  .value = 0x2A2B
};

extern DisplayManager display;

class AppleCurrentTimeService {
public:
  static uint16_t currentTimeValHandle;
  static uint16_t connHandle;
  static bool isSubscribed;
  static bool isDiscovering;
  static unsigned long lastCheckTime;
  static unsigned long lastReadTime;

  static uint16_t svcStartHdl;
  static uint16_t svcEndHdl;

  static void init() {
    currentTimeValHandle = 0;
    connHandle = 0;
    isSubscribed = false;
    isDiscovering = false;
    lastCheckTime = 0;
    lastReadTime = 0;
    svcStartHdl = 0;
    svcEndHdl = 0;
  }

  static void startDiscovery(uint16_t conn_hdl) {
    if (isSubscribed) {
      AppleNotificationService::startDiscovery(conn_hdl);
      return;
    }
    if (isDiscovering) return;
    connHandle = conn_hdl;
    isDiscovering = true;
    currentTimeValHandle = 0;
    svcStartHdl = 0;
    svcEndHdl = 0;
    Serial.printf("[CTS] Discovering Apple Current Time Service (0x1805) on conn=%d...\n", conn_hdl);
    int rc = ble_gattc_disc_svc_by_uuid(conn_hdl, &ctsServiceUUID.u, ctsSvcDiscCb, NULL);
    if (rc != 0) {
      Serial.printf("[CTS] ble_gattc_disc_svc_by_uuid failed rc=%d\n", rc);
      isDiscovering = false;
      AppleNotificationService::startDiscovery(conn_hdl);
    }
  }

  static void onEncrypted(uint16_t conn_hdl) {
    connHandle = conn_hdl;
    startDiscovery(conn_hdl);
  }

  static void onDisconnected() {
    init();
    Serial.println("[CTS] Device disconnected. Resetting CTS state.");
  }

  static int ctsPeriodicReadCb(uint16_t conn_hdl, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status == 0 && attr != nullptr && attr->om != nullptr) {
      parseTimeBuffer(attr->om);
    }
    return 0;
  }

  static void checkPeriodic() {
    if (connHandle != 0 && currentTimeValHandle != 0 && millis() - lastReadTime > 60000) {
      lastReadTime = millis();
      ble_gattc_read(connHandle, currentTimeValHandle, ctsPeriodicReadCb, NULL);
    }
  }

  static int handleGapEvent(ble_gap_event *event, void *arg) {
    if (event->type == BLE_GAP_EVENT_NOTIFY_RX) {
      if (currentTimeValHandle != 0 && event->notify_rx.attr_handle == currentTimeValHandle) {
        parseTimeBuffer(event->notify_rx.om);
      }
    }
    return 0;
  }

private:
  static void parseTimeBuffer(struct os_mbuf *om) {
    uint16_t pktLen = OS_MBUF_PKTLEN(om);
    if (pktLen < 7) return;

    uint8_t buf[10];
    os_mbuf_copydata(om, 0, pktLen < 10 ? pktLen : 10, buf);

    uint16_t year = buf[0] | (buf[1] << 8);
    uint8_t month = buf[2];
    uint8_t day = buf[3];
    uint8_t hours = buf[4];
    uint8_t minutes = buf[5];
    uint8_t seconds = buf[6];

    Serial.printf("[CTS] Current Time from iOS: %02d:%02d:%02d (Day %d/%d/%d)\n",
                  hours, minutes, seconds, day, month, year);

    display.setTime(hours, minutes, seconds);
  }

  static int ctsReadCb(uint16_t conn_hdl, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status == 0 && attr != nullptr && attr->om != nullptr) {
      parseTimeBuffer(attr->om);
    } else {
      Serial.printf("[CTS] Read error status: %d\n", error->status);
    }
    // Now that read is finished, discover CCCD for notifications
    if (currentTimeValHandle != 0) {
      int rc = ble_gattc_disc_all_dscs(conn_hdl, currentTimeValHandle, currentTimeValHandle + 2, ctsDscDiscCb, NULL);
      if (rc != 0) {
        Serial.printf("[CTS] ble_gattc_disc_all_dscs failed rc=%d\n", rc);
        isDiscovering = false;
        isSubscribed = true;
        AppleNotificationService::startDiscovery(conn_hdl);
      }
    } else {
      isDiscovering = false;
      AppleNotificationService::startDiscovery(conn_hdl);
    }
    return 0;
  }

  static int ctsDscDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, uint16_t chr_val_hdl, const struct ble_gatt_dsc *dsc, void *arg) {
    if (error->status == 0 && dsc != nullptr) {
      if (ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        Serial.printf("[CTS] Found Current Time CCCD handle: %d. Enabling notifications...\n", dsc->handle);
        static uint8_t cccdVal[2] = {0x01, 0x00};
        ble_gattc_write_flat(conn_hdl, dsc->handle, cccdVal, 2, NULL, NULL);
        isSubscribed = true;
        isDiscovering = false;
        AppleNotificationService::startDiscovery(conn_hdl);
      }
    } else if (error->status == BLE_HS_EDONE || dsc == nullptr) {
      isDiscovering = false;
      isSubscribed = true;
      AppleNotificationService::startDiscovery(conn_hdl);
    }
    return 0;
  }

  static int ctsChrDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr != nullptr) {
      if (ble_uuid_cmp(&chr->uuid.u, &ctsCurrentTimeUUID.u) == 0) {
        Serial.printf("[CTS] Found Current Time chr! Value handle = %d\n", chr->val_handle);
        currentTimeValHandle = chr->val_handle;
      }
    } else if (error->status == BLE_HS_EDONE || chr == nullptr) {
      if (currentTimeValHandle != 0) {
        lastReadTime = millis();
        int rc = ble_gattc_read(conn_hdl, currentTimeValHandle, ctsReadCb, NULL);
        Serial.printf("[CTS] Initial read triggered (rc=%d)\n", rc);
        if (rc != 0) {
          isDiscovering = false;
          AppleNotificationService::startDiscovery(conn_hdl);
        }
      } else {
        isDiscovering = false;
        AppleNotificationService::startDiscovery(conn_hdl);
      }
    }
    return 0;
  }

  static int ctsSvcDiscCb(uint16_t conn_hdl, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg) {
    if (error->status == 0 && service != nullptr) {
      Serial.printf("[CTS] Apple Current Time Service found! (handles %d - %d)\n", service->start_handle, service->end_handle);
      svcStartHdl = service->start_handle;
      svcEndHdl = service->end_handle;
    } else if (error->status == BLE_HS_EDONE || service == nullptr) {
      if (svcStartHdl != 0) {
        int rc = ble_gattc_disc_all_chrs(conn_hdl, svcStartHdl, svcEndHdl, ctsChrDiscCb, NULL);
        if (rc != 0) {
          Serial.printf("[CTS] ble_gattc_disc_all_chrs failed rc=%d\n", rc);
          isDiscovering = false;
          AppleNotificationService::startDiscovery(conn_hdl);
        }
      } else {
        Serial.println("[CTS] Current Time Service not found on this iPhone connection.");
        isDiscovering = false;
        AppleNotificationService::startDiscovery(conn_hdl);
      }
    }
    return 0;
  }
};

uint16_t AppleCurrentTimeService::currentTimeValHandle = 0;
uint16_t AppleCurrentTimeService::connHandle = 0;
bool AppleCurrentTimeService::isSubscribed = false;
bool AppleCurrentTimeService::isDiscovering = false;
unsigned long AppleCurrentTimeService::lastCheckTime = 0;
unsigned long AppleCurrentTimeService::lastReadTime = 0;
uint16_t AppleCurrentTimeService::svcStartHdl = 0;
uint16_t AppleCurrentTimeService::svcEndHdl = 0;

#endif // CTS_SERVICE_H
