# frozen_string_literal: true

module SimulatorGate
  class GateError < StandardError; end

  REQUIRED_ENV = %w[
    IOS_SIM_GATE_PROJECT
    IOS_SIM_GATE_AGENT
    IOS_SIM_GATE_UDID
    IOS_SIM_GATE_DESTINATION
    IOS_SIM_GATE_DERIVED_DATA_PATH
    IOS_SIM_GATE_DEVICE_NAME
    IOS_SIM_GATE_RUNTIME_VERSION
  ].freeze
  UUID_PATTERN = /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/
  XCODEBUILD_ARGUMENTS = '-parallel-testing-enabled NO ' \
                         '-disable-concurrent-destination-testing'

  def self.snapshot_configuration(env = ENV)
    missing = REQUIRED_ENV.select { |key| env[key].to_s.empty? }
    raise GateError, "Missing simulator gate environment: #{missing.join(', ')}" unless missing.empty?

    uuid = env.fetch('IOS_SIM_GATE_UDID')
    raise GateError, 'Invalid simulator gate UUID' unless uuid.match?(UUID_PATTERN)
    raise GateError, 'Unexpected simulator gate project' unless env.fetch('IOS_SIM_GATE_PROJECT') == 'family-foqos'

    destination = env.fetch('IOS_SIM_GATE_DESTINATION')
    unless destination == "platform=iOS Simulator,id=#{uuid}"
      raise GateError, 'Simulator gate destination does not match its UUID'
    end

    derived_data_path = env.fetch('IOS_SIM_GATE_DERIVED_DATA_PATH')
    raise GateError, 'Simulator gate DerivedData path must be absolute' unless derived_data_path.start_with?('/')

    {
      uuid: uuid,
      device_name: env.fetch('IOS_SIM_GATE_DEVICE_NAME'),
      runtime_version: env.fetch('IOS_SIM_GATE_RUNTIME_VERSION'),
      derived_data_path: derived_data_path,
      xcargs: XCODEBUILD_ARGUMENTS
    }
  end

  def self.assert_registered_device!(simulators, env: ENV)
    config = snapshot_configuration(env)
    matching_devices = simulators.select do |simulator|
      simulator.name.strip == config.fetch(:device_name).strip &&
        simulator.os_version == config.fetch(:runtime_version)
    end
    unless matching_devices.one?
      raise GateError, 'Fastlane simulator lookup must resolve exactly one name/runtime match'
    end
    return true if matching_devices.first.udid == config.fetch(:uuid)

    raise GateError, 'Fastlane simulator lookup does not resolve to the gate-owned UUID'
  end
end
