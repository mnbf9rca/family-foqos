# frozen_string_literal: true

require 'base64'
require 'fastlane'
require 'openssl'

Fastlane.load_actions

repo_root = File.expand_path('..', __dir__)
raw_pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem
ENV['ASC_KEY_ID'] = 'TESTKEY123'
ENV['ASC_ISSUER_ID'] = '11111111-2222-3333-4444-555555555555'
ENV['ASC_KEY_CONTENT_BASE64'] = Base64.strict_encode64(raw_pem)

captured_builds = []
Fastlane::Actions::AppStoreConnectApiKeyAction.singleton_class.define_method(:run) do |_options|
  {
    key: raw_pem,
    key_id: 'TESTKEY123',
    issuer_id: '11111111-2222-3333-4444-555555555555'
  }
end
Fastlane::Actions.singleton_class.define_method(:sh_control_output) do |*_command, **_options|
  "123\n"
end
Fastlane::Actions::BuildAppAction.singleton_class.define_method(:run) do |options|
  captured_builds << options
  nil
end
[Fastlane::Actions::PilotAction, Fastlane::Actions::DeliverAction].each do |action|
  action.singleton_class.define_method(:run) { |_options| raise 'upload path reached' }
end

fastfile = Fastlane::FastFile.new(File.join(repo_root, 'fastlane', 'Fastfile'))
ArchiveStorage.singleton_class.define_method(:upload_dsyms) do |**_options|
  raise 'dSYM publication path reached'
end

Dir.chdir(repo_root) { fastfile.runner.execute(:verify_export, :ios, {}) }

unless captured_builds.length == 1
  warn "FAIL: verify_export built #{captured_builds.length} times instead of once"
  exit 1
end

options = captured_builds.fetch(0)
unless options.fetch(:export_method) == 'app-store'
  warn "FAIL: verify_export export method was #{options.fetch(:export_method).inspect}"
  exit 1
end
unless options.fetch(:xcodebuild_formatter) == 'xcbeautify'
  warn "FAIL: verify_export formatter was #{options.fetch(:xcodebuild_formatter).inspect}"
  exit 1
end
unless options.fetch(:xcargs).include?('CURRENT_PROJECT_VERSION=123')
  actual_build = options.fetch(:xcargs)[/CURRENT_PROJECT_VERSION=\S+/]
  warn "FAIL: verify_export did not propagate derived build 123: #{actual_build.inspect}"
  exit 1
end

puts 'PASS: verify_export performs one archive/export and cannot reach upload actions'
