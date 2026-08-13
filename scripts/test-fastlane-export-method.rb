# frozen_string_literal: true

require 'fastlane'
require 'gym'

Fastlane.load_actions

repo_root = File.expand_path('..', __dir__)
captured_options = nil

unless Gem.loaded_specs.fetch('fastlane').version.to_s == '2.238.0'
  warn 'FAIL: Fastlane is not pinned to 2.238.0'
  exit 1
end

def gym_configuration(export_method)
  FastlaneCore::Configuration.create(
    Gym::Options.available_options,
    { export_method: export_method }
  )
end

gym_configuration('app-store')
begin
  gym_configuration('app-store-connect')
  warn 'FAIL: shipped Gym unexpectedly accepted app-store-connect'
  exit 1
rescue FastlaneCore::Interface::FastlaneError
  # Expected for Fastlane 2.238.0.
end

Fastlane::Actions::BuildAppAction.singleton_class.define_method(:run) do |options|
  captured_options = options
  nil
end

fastfile = Fastlane::FastFile.new(File.join(repo_root, 'fastlane', 'Fastfile'))
archive_lane = fastfile.runner.lanes.fetch(:ios).fetch(:build_app_store_archive)
Dir.chdir(File.join(repo_root, 'fastlane')) do
  archive_lane.call(
    api_key: {
      key: 'test-private-key',
      key_id: 'TESTKEY123',
      issuer_id: '11111111-2222-3333-4444-555555555555'
    },
    build: '123'
  )
end

unless captured_options&.fetch(:export_method) == 'app-store'
  warn 'FAIL: archive lane did not configure Gym for an App Store export'
  exit 1
end
unless captured_options.fetch(:xcodebuild_formatter) == 'xcbeautify'
  warn 'FAIL: archive lane did not configure Gym for xcbeautify'
  exit 1
end

puts 'PASS: pinned Gym validates the archive lane export method and formatter'
