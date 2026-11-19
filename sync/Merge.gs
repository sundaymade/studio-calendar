// SPDX-License-Identifier: GPL-3.0-or-later
// Add-on for GAS-ICS-Sync (github.com/derekantrican/GAS-ICS-Sync): merge several calendars into one
// without duplicates, and never wipe copies when a feed fails to load.
//
// A source event is NOT copied when
//  1) the same event (same UID) is already directly in the target calendar,
//  2) the same UID already came from another source,
//  3) an event with almost the same title starts at the same time
//     (punctuation ignored, 80 % of the words match, e.g. "Talk: X" and "Talk with X ...").
// Recurring events are left to GAS-ICS-Sync.

var _originalFilterResults = filterResults;
filterResults = function(events) {
  return removeDuplicates(_originalFilterResults(events));
};

function normTitle(t) {
  return String(t || "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, " ").trim();
}

function similar(a, b) {
  if (a === b) return true;
  var A = a.split(" ").filter(Boolean), B = b.split(" ").filter(Boolean);
  if (!A.length || !B.length) return false;
  var small = A.length <= B.length ? A : B, large = small === A ? B : A;
  if (small.length < 2) return false;
  var set = {};
  large.forEach(function(w) { set[w] = true; });
  var hits = small.filter(function(w) { return set[w]; }).length;
  return hits / small.length >= 0.8;
}

function icsStart(ev) {
  var p = ev.getFirstProperty("dtstart");
  if (!p) return null;
  var v = p.getFirstValue();
  if (v.isDate) return "D:" + v.toString();
  return v.toJSDate().toISOString();
}

function alreadyThere(index, start, title) {
  var list = index[start] || [];
  for (var i = 0; i < list.length; i++) if (similar(list[i], title)) return true;
  return false;
}

function removeDuplicates(events) {
  var index = {}, ownIds = {};
  try {
    var min = new Date(Date.now() - 31 * 86400000).toISOString();
    var max = new Date(Date.now() + 400 * 86400000).toISOString();
    var token;
    do {
      var r = Calendar.Events.list(targetCalendarId, { timeMin: min, timeMax: max, singleEvents: true, showDeleted: false, maxResults: 2500, pageToken: token });
      (r.items || []).forEach(function(e) {
        var fromScript = e.extendedProperties && e.extendedProperties.private && e.extendedProperties.private.fromGAS == "true";
        if (fromScript || !e.start) return;
        if (e.iCalUID) ownIds[e.iCalUID] = true;
        var s = e.start.dateTime ? new Date(e.start.dateTime).toISOString() : "D:" + e.start.date;
        (index[s] = index[s] || []).push(normTitle(e.summary));
      });
      token = r.nextPageToken;
    } while (token);
  } catch (err) {
    Logger.log("Duplicate check: cannot read the target calendar: " + err);
  }
  var seenIds = {}, n = { id: 0, source: 0, title: 0 };
  var result = events.filter(function(ev) {
    var uid = ev.hasProperty("uid") ? String(ev.getFirstPropertyValue("uid")) : null;
    if (uid) {
      if (ownIds[uid]) { n.id++; return false; }
      var rid = ev.hasProperty("recurrence-id") ? String(ev.getFirstPropertyValue("recurrence-id")) : "master";
      if (seenIds[uid + "|" + rid]) { n.source++; return false; }
      seenIds[uid + "|" + rid] = true;
    }
    if (ev.hasProperty("rrule") || ev.hasProperty("rdate") || ev.hasProperty("recurrence-id")) return true;
    var s;
    try { s = icsStart(ev); } catch (e) { return true; }
    if (!s) return true;
    var t = normTitle(ev.getFirstPropertyValue("summary"));
    if (alreadyThere(index, s, t)) { n.title++; return false; }
    (index[s] = index[s] || []).push(t);
    return true;
  });
  Logger.log("Duplicate check: skipped " + (events.length - result.length) + " (already in target: " + n.id + ", same UID from 2 sources: " + n.source + ", same title and time: " + n.title + ")");
  return result;
}

// Run once if older runs created duplicate copies (same event id): deletes the extra copies,
// then syncs. Only touches copies the script made itself.
function cleanUp() {
  var seen = {}, deleted = 0, token;
  do {
    var r = Calendar.Events.list(targetCalendarId || "primary", { privateExtendedProperty: "fromGAS=true", showDeleted: false, maxResults: 2500, pageToken: token });
    (r.items || []).forEach(function(e) {
      var p = e.extendedProperties.private;
      var key = p["rec-id"] || p["id"];
      if (!key) return;
      if (seen[key]) {
        Calendar.Events.remove(targetCalendarId || "primary", e.id);
        deleted++;
      } else {
        seen[key] = true;
      }
    });
    token = r.nextPageToken;
  } while (token);
  Logger.log("Clean-up: deleted " + deleted + " duplicate copies");
  startSync();
}

// Safety: if a feed (e.g. iCloud) does not load, delete nothing in this run.
// Otherwise every copy from that feed would be deleted and created again 5 minutes later.
var _originalFetch = fetchSourceCalendars;
fetchSourceCalendars = function(urls) {
  var r = _originalFetch(urls);
  if (r.length < urls.length) {
    removeEventsFromCalendar = false;
    Logger.log("Only " + r.length + " of " + urls.length + " sources loaded, deleting nothing this run");
  }
  return r;
};
