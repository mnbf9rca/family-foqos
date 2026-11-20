# frozen_string_literal: true

require 'base64'
require 'fastlane'
require 'openssl'
require 'shellwords'

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

[nil, 'agent-safehouse'].each do |container_id|
  if container_id
    ENV['APP_SANDBOX_CONTAINER_ID'] = container_id
  else
    ENV.delete('APP_SANDBOX_CONTAINER_ID')
  end
  captured_builds.clear
  Dir.chdir(repo_root) { fastfile.runner.execute(:verify_export, :ios, {}) }
  raise "Expected one archive/export, got #{captured_builds.length}" unless captured_builds.length == 1

  options = captured_builds.first
  raise 'Wrong export method' unless options.fetch(:export_method) == 'app-store'
  raise 'Wrong build formatter' unless options.fetch(:xcodebuild_formatter) == 'xcbeautify'

  actual = Shellwords.split(options.fetch(:xcargs))
  signing_key_path = actual[3]
  expected = [
    'CURRENT_PROJECT_VERSION=123', '-allowProvisioningUpdates',
    '-authenticationKeyPath', signing_key_path,
    '-authenticationKeyID', 'TESTKEY123',
    '-authenticationKeyIssuerID', '11111111-2222-3333-4444-555555555555'
  ]
  raise 'Missing signing key path' if signing_key_path.to_s.empty?

  if container_id
    expected.push('-IDEPackageSupportDisableManifestSandbox=1', 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
    raise 'Safehouse must skip the standalone package resolution' unless options[:skip_package_dependencies_resolution]
    raise 'Expected FamilyFoqos IPA and archive naming in Safehouse' unless options[:output_name] == 'FamilyFoqos'
  elsif options[:skip_package_dependencies_resolution] || options[:output_name]
    raise 'Host archive options changed'
  end
  raise "Wrong archive arguments for #{container_id || 'host'}" unless actual == expected
end

puts 'PASS: host and Safehouse verify_export each archive once and cannot reach upload actions'
