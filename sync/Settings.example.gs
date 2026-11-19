// SPDX-License-Identifier: GPL-3.0-or-later
// Your settings. Copy to Settings.gs in the Apps Script project. They override the defaults in Code.gs
// because this file loads last (keep it at the bottom of the file list).
// Never commit the real file: private ICS links work like passwords.

var sourceCalendars = [
  ["<private ICS link of calendar 1>", "<target calendar, e.g. you@example.com>"],   // e.g. work Google calendar
  ["<public ICS link of an iCloud calendar>", "<target calendar>"],                  // e.g. iCloud Personal
  ["<public ICS link of another iCloud calendar>", "<target calendar>"]              // e.g. iCloud Work
];
var howFrequent = 5;                       // every 5 minutes
var addAlerts = "no";                      // no second set of reminders: the original calendars already alert you
var removePastEventsFromCalendar = true;   // copies are a rolling window from 30 days back; originals are never touched
var filters = [
  { parameter: "dtstart", type: "include", comparison: ">", offset: -30 }  // only from 30 days back (dtstart, since some events have no end)
];

// Optional: share the target calendar with another account of yours (e.g. the one your Claude
// connectors use), so it can read the merged calendar. Fill in the address, then run once.
var shareWith = "";   // e.g. "you@company.com"

// Run once: shares the calendar (if shareWith is set) and installs the timer.
function setup() {
  if (shareWith) {
    Calendar.Acl.insert({ role: "writer", scope: { type: "user", value: shareWith } }, "primary", { sendNotifications: false });
  }
  install();
}

// Check without changing anything.
function check() {
  var p = Calendar.CalendarList.get("primary");
  Logger.log("Target: " + (p.summaryOverride || p.summary) + " | sources: " + sourceCalendars.length + " | every " + howFrequent + " min | filters: " + filters.length);
}
