func report(sink: Logger) {
  sink.info("Direct sink")
}

let sink2 = Logger(subsystem: "fixture", category: "fixture")
