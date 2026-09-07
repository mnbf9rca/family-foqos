# frozen_string_literal: true

require 'base64'
require 'fastlane'
require 'openssl'

Fastlane.load_actions
repo_root = File.expand_path('..', __dir__)
ENV.delete('FOQOS_PREFLIGHT_ALLOW_BRANCH')
ENV['ASC_KEY_ID'] = 'TESTKEY123'
ENV['ASC_ISSUER_ID'] = '11111111-2222-3333-4444-555555555555'
ENV['ASC_KEY_CONTENT_BASE64'] = Base64.strict_encode64(OpenSSL::PKey::EC.generate('prime256v1').to_pem)
api_key = { key_id: 'TESTKEY123', key: 'offline-test-key' }
events = []
scenario = nil
original_glob = Dir.method(:glob)
screenshot_pattern = File.join(repo_root, 'fastlane/screenshots/en-GB/*_framed.png')
Dir.singleton_class.define_method(:glob) do |pattern, *args, **options|
  next original_glob.call(pattern, *args, **options) unless pattern == screenshot_pattern

  events << :screenshots
  names = %w[01-home-active 02-profile-triggers 03-child-locked 04-parent-dashboard 05-location-restrictions]
  names.pop if scenario == :missing_screenshot
  names.map { |name| "#{name}_framed.png" }
end

fastfile = Fastlane::FastFile.new(File.join(repo_root, 'fastlane/Fastfile'))
%i[success dirty_tree wrong_branch missing_screenshot].each do |current_scenario|
  scenario = current_scenario
  events.clear
  # Intercept every action boundary: any archive, shell, or unexpected action fails closed.
  fastfile.runner.define_singleton_method(:execute_action) do |name, _action, arguments, **_options|
    case name
    when :ensure_git_status_clean
      events << :clean
      raise 'dirty tree' if scenario == :dirty_tree
    when :git_branch
      events << :branch
      scenario == :wrong_branch ? 'feature/unapproved' : 'main'
    when :ensure_git_branch
      events << :main
      raise 'wrong branch' if scenario == :wrong_branch
      raise 'main guard changed' unless arguments.first == { branch: 'main' }
    when :app_store_connect_api_key
      events << :key
      api_key
    when :deliver
      events << :deliver
      expected = {
        api_key: api_key,
        skip_binary_upload: true,
        skip_metadata: true,
        skip_app_version_update: true,
        overwrite_screenshots: true,
        submit_for_review: false,
        screenshots_path: './fastlane/screenshots'
      }
      raise 'unsafe deliver options' unless arguments == [expected]
    else
      raise "unexpected action: #{name}"
    end
  end

  expected_error, expected_events = {
    success: [nil, %i[clean branch main screenshots key deliver]],
    dirty_tree: ['dirty tree', [:clean]],
    wrong_branch: ['wrong branch', %i[clean branch main]],
    missing_screenshot: ['Expected 5 framed en-GB screenshots', %i[clean branch main screenshots]]
  }.fetch(scenario)
  begin
    Dir.chdir(repo_root) { fastfile.runner.execute(:update_screenshots, :ios, {}) }
    raise "#{scenario} should have failed" if expected_error
  rescue StandardError => e
    raise unless expected_error && e.message.include?(expected_error)
  end
  raise "#{scenario}: unexpected events #{events.inspect}" unless events == expected_events
end

puts 'PASS: screenshot-only upload flags, ordered guards, guard failures, and archive exclusion (offline)'
