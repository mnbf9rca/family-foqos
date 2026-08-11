func report(logger: Logger) {
  logger.info("Direct sink")
}

let directLogger = Logger(subsystem: "fixture", category: "fixture")
