func processEntry(_ entry: LogEntry) {
  os_log("%{private}@", log: osLog, type: entry.level.osLogType, entry.formattedString)
}
