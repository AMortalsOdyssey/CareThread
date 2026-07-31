#!/bin/bash

# number|slug|route|mode|shell|presentation|selectedTab|tabBarExpected|featureMarker
CARETHREAD_SCREENSHOT_ROUTES=(
  "01|onboarding|onboarding|standard|RootView|onboarding||false|onboarding.localPrivacy"
  "02|home|home|standard|StandardRootTabView|tab|0|true|m45.home"
  "03|capture-source|capture-source|standard|StandardRootTabView|sheet|0|false|m3.capture.host"
  "04|capture-confirmation|capture-confirmation|standard|StandardRootTabView|sheet|0|false|m3.confirmation"
  "05|records|records|standard|StandardRootTabView|tab|3|true|m3.records.library"
  "06|record-detail|record-detail|standard|StandardRootTabView|push|3|true|m3.detail"
  "07|original-ocr|original-ocr|standard|StandardRootTabView|fullScreen|3|false|m3.viewer"
  "08|medications|medications|standard|StandardRootTabView|push|4|true|m45.medication.list"
  "09|followups|followups|standard|StandardRootTabView|push|4|true|m45.followup.list"
  "10|timeline|timeline|standard|StandardRootTabView|tab|1|true|m6.timeline"
  "11|brief|brief|standard|StandardRootTabView|sheet|0|false|m7.brief"
  "12|manage|manage|standard|StandardRootTabView|tab|4|true|m45.manage"
  "13|backup|backup|standard|StandardRootTabView|push|4|true|m8.backup.screen"
  "14|lock|lock|standard|AppLockGate|gate||false|m8.lock.screen"
  "15|elder-today|elder-today|elder|ElderRootView|tab|0|true|elder.today"
  "16|elder-capture-question|elder-capture-question|elder|ElderRootView|sheet|0|false|elder.capture.typeQuestion"
  "17|elder-records|elder-records|elder|ElderRootView|tab|2|true|elder.records"
  "18|elder-brief|elder-brief|elder|ElderRootView|sheet|0|false|elder.brief"
  "19|member-management|member-management|standard|StandardRootTabView|push|4|true|member.management"
  "20|comparison|comparison|standard|StandardRootTabView|sheet|0|false|m7.compare"
  "21|export|export|standard|StandardRootTabView|sheet|0|false|m7.brief"
  "22|nearby-sync|nearby-sync|standard|StandardRootTabView|sheet|0|false|nearbySync.root"
  "23|more|more|standard|StandardRootTabView|sheet|0|false|m45.more"
)

CARETHREAD_SCREENSHOT_ROUTE_COUNT="${#CARETHREAD_SCREENSHOT_ROUTES[@]}"
CARETHREAD_SCREENSHOT_COUNT=$((CARETHREAD_SCREENSHOT_ROUTE_COUNT * 2))
CARETHREAD_SCREENSHOT_TOTAL_COUNT="$CARETHREAD_SCREENSHOT_COUNT"
CARETHREAD_SCREENSHOT_STANDARD_COUNT=0
CARETHREAD_SCREENSHOT_ELDER_COUNT=0
for carethread_screenshot_entry in "${CARETHREAD_SCREENSHOT_ROUTES[@]}"; do
  IFS='|' read -r _ _ _ carethread_screenshot_mode _ \
    <<<"$carethread_screenshot_entry"
  if [[ "$carethread_screenshot_mode" == "standard" ]]; then
    CARETHREAD_SCREENSHOT_STANDARD_COUNT=$((CARETHREAD_SCREENSHOT_STANDARD_COUNT + 2))
  else
    CARETHREAD_SCREENSHOT_ELDER_COUNT=$((CARETHREAD_SCREENSHOT_ELDER_COUNT + 2))
  fi
done
