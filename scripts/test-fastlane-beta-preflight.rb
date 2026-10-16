# frozen_string_literal: true

require 'fastlane'
require 'spaceship'

Fastlane.load_actions
repo_root = File.expand_path('..', __dir__)
fastfile = Fastlane::FastFile.new(File.join(repo_root, 'fastlane/Fastfile'))
abort 'FAIL: beta preflight helpers are missing' unless fastfile.respond_to?(:beta_release_notes) &&
                                                        fastfile.respond_to?(:assert_external_test_group)

def expect_failure(error_class, message)
  yield
rescue error_class => e
  raise unless e.message.include?(message)
else
  raise "Expected #{error_class}: #{message}"
end

notes_path = File.join(repo_root, 'fastlane/metadata/en-GB/release_notes.txt')
original_read = File.method(:read)
notes = nil
File.singleton_class.define_method(:read) do |path, *args, **options|
  next original_read.call(path, *args, **options) unless path == notes_path

  raise Errno::ENOENT, path if notes.nil?

  notes
end
expect_failure(Errno::ENOENT, 'release_notes.txt') { fastfile.beta_release_notes }
['', " \n\t"].each do |blank|
  notes = blank
  expect_failure(FastlaneCore::Interface::FastlaneError, 'release notes must not be blank') do
    fastfile.beta_release_notes
  end
end
notes = "Release notes\n"
raise 'Release notes were changed' unless fastfile.beta_release_notes == notes

group = Struct.new(:name, :is_internal_group)
external = group.new('external test group', false)
groups = [external]
app = Object.new
app.define_singleton_method(:get_beta_groups) { groups }
original_find = Spaceship::ConnectAPI::App.method(:find)
Spaceship::ConnectAPI::App.singleton_class.define_method(:find) do |identifier|
  raise 'Wrong app identifier' unless identifier == 'com.cynexia.family-foqos'

  app
end
fastfile.assert_external_test_group
[
  [], [group.new('External Test Group', false)], [group.new('external test group', true)],
  [group.new('external test group', nil)], [external, external],
  [external, group.new('external test group', true)]
].each do |invalid_groups|
  groups = invalid_groups
  expect_failure(FastlaneCore::Interface::FastlaneError, "external TestFlight group named 'external test group'") do
    fastfile.assert_external_test_group
  end
end
app = nil
expect_failure(FastlaneCore::Interface::FastlaneError, 'App Store Connect app was not found') do
  fastfile.assert_external_test_group
end
Spaceship::ConnectAPI::App.singleton_class.define_method(:find, original_find)
File.singleton_class.define_method(:read, original_read)

puts 'PASS: beta release notes and exact external group validation (offline; no beta lane execution)'
