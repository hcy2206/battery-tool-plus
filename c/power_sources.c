#include "power_sources.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>

static const char kAppleSmartBattery[] = "AppleSmartBattery";

// AppleSmartBattery dictionary keys
static const char kCurrentCapacityKey[] = "AppleRawCurrentCapacity";
static const char kMaxCapacityKey[] = "NominalChargeCapacity";
static const char kDesignCapacityKey[] = "DesignCapacity";
static const char kCycleCountKey[] = "CycleCount";
static const char kIsChargingKey[] = "IsCharging";
static const char kExternalConnectedKey[] = "ExternalConnected";

// Newer firmware (macOS 27 and the 15.8 / 26.7 firmware updates) moves the
// capacity figures into this nested dictionary and renames the raw current
// capacity, so each integer is looked up at the top level first and then here.
static const char kBatteryDataKey[] = "BatteryData";
static const char kNestedCurrentCapacityKey[] = "RemainingCapacity";

static bool GetDictInt(CFDictionaryRef dict, const char* key, void* out,
                       CFNumberType type) {
  CFStringRef cf_key =
      CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFNumberRef ref = CFDictionaryGetValue(dict, cf_key);
  CFRelease(cf_key);
  if (ref == NULL || CFGetTypeID(ref) != CFNumberGetTypeID()) {
    return false;
  }
  return CFNumberGetValue(ref, type, out);
}

static CFDictionaryRef GetBatteryData(CFDictionaryRef dict) {
  CFStringRef cf_key =
      CFStringCreateWithCString(NULL, kBatteryDataKey, kCFStringEncodingUTF8);
  CFDictionaryRef nested = CFDictionaryGetValue(dict, cf_key);
  CFRelease(cf_key);
  if (nested == NULL || CFGetTypeID(nested) != CFDictionaryGetTypeID()) {
    return NULL;
  }
  return nested;
}

static bool GetBatteryInt(CFDictionaryRef dict, const char* key,
                          const char* nested_key, void* out) {
  if (GetDictInt(dict, key, out, kCFNumberIntType)) {
    return true;
  }
  CFDictionaryRef nested = GetBatteryData(dict);
  return nested != NULL &&
         GetDictInt(nested, nested_key, out, kCFNumberIntType);
}

static bool GetDictBool(CFDictionaryRef dict, const char* key, bool* out) {
  CFStringRef cf_key =
      CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFBooleanRef ref = CFDictionaryGetValue(dict, cf_key);
  CFRelease(cf_key);
  if (ref == NULL) {
    return false;
  }
  *out = CFBooleanGetValue(ref);
  return true;
}

BatteryInfo FetchBatteryInfo(void) {
  BatteryInfo info = {0};

  io_service_t entry = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching(kAppleSmartBattery));
  if (entry == IO_OBJECT_NULL) {
    return info;
  }

  CFMutableDictionaryRef properties;
  kern_return_t result = IORegistryEntryCreateCFProperties(
      entry, &properties, kCFAllocatorDefault, 0);
  IOObjectRelease(entry);
  if (result != kIOReturnSuccess) {
    return info;
  }

  if (!GetBatteryInt(properties, kCurrentCapacityKey, kNestedCurrentCapacityKey,
                     &info.current_capacity))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kCurrentCapacityKey);
  if (!GetBatteryInt(properties, kMaxCapacityKey, kMaxCapacityKey,
                     &info.max_capacity))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kMaxCapacityKey);
  if (!GetBatteryInt(properties, kDesignCapacityKey, kDesignCapacityKey,
                     &info.design_capacity))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kDesignCapacityKey);
  if (!GetDictInt(properties, kCycleCountKey, &info.cycle_count,
                  kCFNumberIntType))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kCycleCountKey);
  if (!GetDictBool(properties, kIsChargingKey, &info.is_charging))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kIsChargingKey);
  if (!GetDictBool(properties, kExternalConnectedKey, &info.is_plugged_in))
    fprintf(stderr, "batterytool: failed to read IOKit key '%s'\n",
            kExternalConnectedKey);

  CFRelease(properties);
  return info;
}
