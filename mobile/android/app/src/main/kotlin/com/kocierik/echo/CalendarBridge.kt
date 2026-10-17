package com.kocierik.echo

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract.Attendees
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar
import java.util.TimeZone
import java.util.concurrent.Executors

/**
 * The phone's calendar for Echo, on the same "echo/eventkit" channel as the iPhone's
 * EventKitBridge.swift (lib/services/phone/phone_calendar.dart), so the Dart side is one.
 * Android has no system Reminders app: reminders are "unavailable".
 *
 * Dates cross the channel as epoch milliseconds; an all-day event as the local midnight of
 * its first and last day, as on the iPhone. Failures are errors with code "eventkit".
 */
class CalendarBridge(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val REQUEST_CODE = 4207
        private const val ASKED_KEY = "calendar_asked"
        private val PERMISSIONS =
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        private const val DAY_MS = 24 * 60 * 60 * 1000L
    }

    /** The screen that asks for the permission; null while Echo has none. */
    var activity: Activity? = null

    private var pendingRequest: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences("echo_calendar", Context.MODE_PRIVATE)

    init {
        MethodChannel(messenger, "echo/eventkit").setMethodCallHandler { call, result ->
            val calendar = call.argument<String>("app") == "calendar"
            when (call.method) {
                "access" -> result.success(if (calendar) access() else "unavailable")
                "requestAccess" -> if (calendar) requestAccess(result) else result.success(false)
                "createEvent" -> work(result) { createEvent(call) }
                "events" -> work(result) { events(call) }
                "createReminder", "openReminders" ->
                    result.error("eventkit", "Reminders are not available on Android", null)
                else -> result.notImplemented()
            }
        }
    }

    // Access

    private fun granted(): Boolean = PERMISSIONS.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    /** Once refused, only Android settings give it back, as on the iPhone. */
    private fun access(): String = when {
        granted() -> "granted"
        preferences.getBoolean(ASKED_KEY, false) -> "denied"
        else -> "notAsked"
    }

    private fun requestAccess(result: MethodChannel.Result) {
        val screen = activity
        if (granted()) return result.success(true)
        if (screen == null || pendingRequest != null) return result.success(false)
        preferences.edit().putBoolean(ASKED_KEY, true).apply()
        pendingRequest = result
        screen.requestPermissions(PERMISSIONS, REQUEST_CODE)
    }

    fun onPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        val result = pendingRequest ?: return
        pendingRequest = null
        result.success(
            grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        )
    }

    // Calendar

    private fun createEvent(call: MethodCall): Map<String, Any> {
        val title = required(call, "title")
        val start = call.argument<Number>("start")?.toLong()
        val end = call.argument<Number>("end")?.toLong()
        if (start == null || end == null) throw BridgeError("start and end are required")
        val allDay = call.argument<Boolean>("allDay") ?: false
        val location = optional(call, "location")
        val notes = optional(call, "notes")
        val (calendarId, calendarName) = calendarFor(optional(call, "calendar"))

        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, calendarId)
            put(Events.TITLE, title)
            location?.let { put(Events.EVENT_LOCATION, it) }
            notes?.let { put(Events.DESCRIPTION, it) }
            if (allDay) {
                // Android stores all-day events as UTC midnights, the end excluded
                val first = utcMidnight(start)
                put(Events.ALL_DAY, 1)
                put(Events.EVENT_TIMEZONE, "UTC")
                put(Events.DTSTART, first)
                put(Events.DTEND, maxOf(utcMidnight(end), first) + DAY_MS)
            } else {
                put(Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                put(Events.DTSTART, start)
                put(Events.DTEND, maxOf(end, start))
            }
        }
        val uri = context.contentResolver.insert(Events.CONTENT_URI, values)
            ?: throw BridgeError("The calendar did not save the event")

        val item = mutableMapOf<String, Any>(
            "id" to ContentUris.parseId(uri).toString(),
            "title" to title,
            "start" to start,
            "end" to maxOf(end, start),
            "allDay" to allDay,
            "calendar" to calendarName,
            "attendees" to emptyList<Map<String, String>>(),
        )
        location?.let { item["location"] = it }
        notes?.let { item["notes"] = it }
        return item
    }

    private fun events(call: MethodCall): List<Map<String, Any>> {
        val start = call.argument<Number>("start")?.toLong()
        val end = call.argument<Number>("end")?.toLong()
        if (start == null || end == null) throw BridgeError("start and end are required")
        val projection = arrayOf(
            Instances.EVENT_ID,
            Instances.TITLE,
            Instances.BEGIN,
            Instances.END,
            Instances.ALL_DAY,
            Instances.CALENDAR_DISPLAY_NAME,
            Instances.EVENT_LOCATION,
            Instances.DESCRIPTION,
            Instances.OWNER_ACCOUNT,
        )
        val uri = Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, start)
            ContentUris.appendId(it, end)
        }.build()
        val items = mutableListOf<Map<String, Any>>()
        context.contentResolver.query(
            uri, projection, "${Instances.VISIBLE} = 1", null, "${Instances.BEGIN} ASC"
        )?.use { rows ->
            while (rows.moveToNext()) {
                val eventId = rows.getLong(0)
                val allDay = rows.getInt(4) == 1
                var begin = rows.getLong(2)
                var finish = rows.getLong(3)
                if (allDay) {
                    // UTC midnights, the end excluded: the local first and last day
                    begin = localMidnight(begin)
                    finish = maxOf(localMidnight(finish - DAY_MS), begin)
                }
                val item = mutableMapOf<String, Any>(
                    "id" to eventId.toString(),
                    "title" to (rows.getString(1) ?: ""),
                    "start" to begin,
                    "end" to finish,
                    "allDay" to allDay,
                    "calendar" to (rows.getString(5) ?: ""),
                    "attendees" to attendees(eventId, rows.getString(8)),
                )
                rows.getString(6)?.takeIf { it.isNotBlank() }?.let { item["location"] = it }
                rows.getString(7)?.takeIf { it.isNotBlank() }?.let { item["notes"] = it }
                items.add(item)
            }
        }
        return items
    }

    /** The guests, without the calendar's owner (the user), as the iPhone leaves them out. */
    private fun attendees(eventId: Long, owner: String?): List<Map<String, String>> {
        val guests = mutableListOf<Map<String, String>>()
        Attendees.query(
            context.contentResolver,
            eventId,
            arrayOf(Attendees.ATTENDEE_NAME, Attendees.ATTENDEE_EMAIL),
        )?.use { rows ->
            while (rows.moveToNext()) {
                val email = rows.getString(1) ?: ""
                if (owner != null && email.equals(owner, ignoreCase = true)) continue
                guests.add(mapOf("name" to (rows.getString(0) ?: ""), "email" to email))
            }
        }
        return guests
    }

    /** A writable, visible calendar by name; else the primary one; else the first. */
    private fun calendarFor(name: String?): Pair<Long, String> {
        val writable = mutableListOf<Triple<Long, String, Boolean>>()
        context.contentResolver.query(
            Calendars.CONTENT_URI,
            arrayOf(Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME, Calendars.IS_PRIMARY),
            "${Calendars.VISIBLE} = 1 AND ${Calendars.CALENDAR_ACCESS_LEVEL} >= ?",
            arrayOf(Calendars.CAL_ACCESS_CONTRIBUTOR.toString()),
            null,
        )?.use { rows ->
            while (rows.moveToNext()) {
                writable.add(Triple(rows.getLong(0), rows.getString(1) ?: "", rows.getInt(2) == 1))
            }
        }
        val chosen = name?.let { wanted -> writable.firstOrNull { it.second.equals(wanted, true) } }
            ?: writable.firstOrNull { it.third }
            ?: writable.firstOrNull()
            ?: throw BridgeError("There is no calendar to add to")
        return chosen.first to chosen.second
    }

    // Helpers

    private fun work(result: MethodChannel.Result, body: () -> Any) {
        worker.execute {
            try {
                val value = body()
                main.post { result.success(value) }
            } catch (error: BridgeError) {
                main.post { result.error("eventkit", error.message, null) }
            } catch (error: SecurityException) {
                main.post { result.error("eventkit", "Echo is not allowed to use Calendar", null) }
            } catch (error: Exception) {
                main.post { result.error("eventkit", error.message ?: "Calendar failed", null) }
            }
        }
    }

    private fun required(call: MethodCall, key: String): String =
        optional(call, key) ?: throw BridgeError("$key is required")

    private fun optional(call: MethodCall, key: String): String? =
        call.argument<String>(key)?.trim()?.takeIf { it.isNotEmpty() }

    /** The UTC midnight of the local day of [ms]. */
    private fun utcMidnight(ms: Long): Long {
        val local = Calendar.getInstance().apply { timeInMillis = ms }
        return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
        }.timeInMillis
    }

    /** The local midnight of the UTC day of [ms]. */
    private fun localMidnight(ms: Long): Long {
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = ms }
        return Calendar.getInstance().apply {
            clear()
            set(utc.get(Calendar.YEAR), utc.get(Calendar.MONTH), utc.get(Calendar.DAY_OF_MONTH))
        }.timeInMillis
    }

    private class BridgeError(message: String) : Exception(message)
}
