# frozen_string_literal: true

require 'fastlane'
require 'gym'

Fastlane.load_actions

repo_root = File.expand_path('..', __dir__)
captured_options = nil

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

puts 'PASS: pinned Gym accepts the archive lane export method'
