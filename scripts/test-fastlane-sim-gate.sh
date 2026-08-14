#!/bin/bash
set -euo pipefail

# Keep this list in sync whenever the suite starts invoking another external tool.
required_commands=(cat dirname grep mktemp rm ruby)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

cat >"$TEST_ROOT/test.rb" <<'RUBY'
# frozen_string_literal: true

require File.expand_path('fastlane/simulator_gate', ENV.fetch('REPO_ROOT'))

UUID = '11111111-1111-1111-1111-111111111111'
ENV['IOS_SIM_GATE_PROJECT'] = 'family-foqos'
ENV['IOS_SIM_GATE_AGENT'] = 'build2'
ENV['IOS_SIM_GATE_SESSION'] = 'screenshots'
ENV['IOS_SIM_GATE_UDID'] = UUID
ENV['IOS_SIM_GATE_DESTINATION'] = "platform=iOS Simulator,id=#{UUID}"
ENV['IOS_SIM_GATE_DERIVED_DATA_PATH'] = '/tmp/gate-derived-data'
ENV['IOS_SIM_GATE_DEVICE_NAME'] = 'Family Foqos - build2 - screenshots'
ENV['IOS_SIM_GATE_RUNTIME_VERSION'] = '26.0'

config = SimulatorGate.snapshot_configuration
raise 'wrong device' unless config.fetch(:device_name) == ENV.fetch('IOS_SIM_GATE_DEVICE_NAME')
raise 'wrong runtime' unless config.fetch(:runtime_version) == '26.0'
raise 'wrong DerivedData' unless config.fetch(:derived_data_path) == '/tmp/gate-derived-data'
expected_xcargs = '-parallel-testing-enabled NO -disable-concurrent-destination-testing'
raise 'wrong xcargs' unless config.fetch(:xcargs) == expected_xcargs

device = Struct.new(:name, :os_version, :udid)
matching = device.new(ENV.fetch('IOS_SIM_GATE_DEVICE_NAME'), '26.0', UUID)
SimulatorGate.assert_registered_device!([matching])

wrong = device.new(ENV.fetch('IOS_SIM_GATE_DEVICE_NAME'), '26.0',
                   '22222222-2222-2222-2222-222222222222')
begin
  SimulatorGate.assert_registered_device!([matching, wrong])
  raise 'ambiguous name/runtime lookup was accepted'
rescue SimulatorGate::GateError
  # Expected.
end

begin
  SimulatorGate.assert_registered_device!([wrong])
  raise 'wrong UUID was accepted'
rescue SimulatorGate::GateError
  # Expected.
end

saved = ENV.to_h
SimulatorGate::REQUIRED_ENV.each { |key| ENV.delete(key) }
begin
  SimulatorGate.snapshot_configuration
  raise 'missing gate environment was accepted'
rescue SimulatorGate::GateError
  # Expected.
ensure
  saved.each { |key, value| ENV[key] = value }
end

captured = {}
receiver = TOPLEVEL_BINDING.receiver
%i[
  devices languages scheme project app_identifier output_directory clear_previous_screenshots
  override_status_bar stop_after_first_error concurrent_simulators reinstall_app
  xcodebuild_formatter ios_version derived_data_path xcargs
].each do |name|
  receiver.singleton_class.define_method(name) do |value|
    captured[name] = value
  end
end
snapfile_path = File.expand_path('fastlane/Snapfile', ENV.fetch('REPO_ROOT'))
Dir.chdir(ENV.fetch('REPO_ROOT')) do
  TOPLEVEL_BINDING.eval(File.read(snapfile_path, encoding: 'utf-8'))
end

raise 'Snapfile device mismatch' unless captured.fetch(:devices) == [config.fetch(:device_name)]
raise 'Snapfile runtime mismatch' unless captured.fetch(:ios_version) == config.fetch(:runtime_version)
unless captured.fetch(:derived_data_path) == config.fetch(:derived_data_path)
  raise 'Snapfile DerivedData mismatch'
end
raise 'Snapfile xcargs mismatch' unless captured.fetch(:xcargs) == expected_xcargs
unless captured.fetch(:xcodebuild_formatter) == 'xcbeautify'
  raise 'Snapfile formatter mismatch'
end

puts 'PASS: Fastlane simulator gate environment and exact UUID lookup'
RUBY

REPO_ROOT="$REPO_ROOT" ruby "$TEST_ROOT/test.rb"

if grep -nE 'XCTEST_DEVICES_DIR|created\.each|simctl.*--set|Clone [[:digit:]]' \
  "$REPO_ROOT/fastlane/Fastfile"; then
  echo "FAIL: Fastfile still contains run-created XCTestDevices cleanup" >&2
  exit 1
else
  grep_status=$?
  if [[ "$grep_status" -ne 1 ]]; then
    echo "FAIL: could not inspect fastlane/Fastfile (grep exit $grep_status)" >&2
    exit "$grep_status"
  fi
fi

grep -nE 'SimulatorGate\.assert_registered_device!' "$REPO_ROOT/fastlane/Fastfile" >/dev/null || {
  echo "FAIL: screenshots lane does not assert exact registered simulator lookup" >&2
  exit 1
}

echo "PASS: Fastlane screenshot lane has no clone cleanup"
