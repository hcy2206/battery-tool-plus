#ifndef POWER_SOURCES_H
#define POWER_SOURCES_H

#include <stdbool.h>

typedef int MilliampHours;

typedef struct {
  MilliampHours current_capacity;
  MilliampHours max_capacity;
  MilliampHours design_capacity;
  int cycle_count;
  /* Gauge state of charge, 0-100, as shown by macOS; -1 when unavailable. */
  int state_of_charge;
  bool is_charging;
  bool is_plugged_in;
} BatteryInfo;

BatteryInfo FetchBatteryInfo(void);

#endif
