# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

helper_path = File.expand_path('../fastlane/archive_storage.rb', __dir__)
unless File.exist?(helper_path)
  warn 'FAIL: fastlane/archive_storage.rb is missing'
  exit 1
end

require helper_path

unless ArchiveStorage.respond_to?(:upload_dsyms)
  warn 'FAIL: ArchiveStorage.upload_dsyms is missing'
  exit 1
end

Dir.mktmpdir do |root|
  archive = File.join(root, 'FamilyFoqos.xcarchive')
  source = File.join(archive, 'dSYMs')
  destination = File.join(root, 'FamilyFoqos-dSYMs.zip')
  FileUtils.mkdir_p(source)
  File.write(File.join(source, 'FamilyFoqos.app.dSYM'), 'symbols')

  observed = nil
  result = ArchiveStorage.create_dsym_zip(archive: archive, destination: destination) do |from, to|
    observed = [from, to]
    File.write(to, 'zip-bytes')
  end

  unless observed == [source, destination]
    warn 'FAIL: zipper did not receive the archive dSYMs and exact destination'
    exit 1
  end
  unless result == destination && File.file?(destination)
    warn 'FAIL: successful dSYM preparation did not return the created zip'
    exit 1
  end

  begin
    ArchiveStorage.create_dsym_zip(
      archive: File.join(root, 'Missing.xcarchive'),
      destination: destination
    ) { |_from, _to| raise 'zipper should not run' }
    warn 'FAIL: missing archive dSYMs should raise'
    exit 1
  rescue ArgumentError
    # Expected: no zipper may run without the archive dSYMs directory.
  end

  File.write(destination, 'stale-zip')
  begin
    ArchiveStorage.create_dsym_zip(archive: archive, destination: destination) do |_from, _to|
      raise IOError, 'zip failed'
    end
    warn 'FAIL: zipper failure should propagate'
    exit 1
  rescue IOError => e
    raise unless e.message == 'zip failed'
  end
  if File.exist?(destination)
    warn 'FAIL: zipper failure left a stale destination that could be published'
    exit 1
  end

  begin
    ArchiveStorage.create_dsym_zip(archive: archive, destination: destination) do |_from, _to|
      nil
    end
    warn 'FAIL: missing zipper output should raise'
    exit 1
  rescue RuntimeError => e
    raise unless e.message.include?('dSYM zip was not created')
  end
end

create_calls = []
ArchiveStorage.upload_dsyms(
  tag: 'build/12',
  prerelease: true,
  title: 'Title with spaces',
  notes: "Notes with an apostrophe: family's archive",
  asset: '/tmp/path with spaces/dSYMs.zip'
) { |args| create_calls << args }

unless create_calls == [[
  'gh', 'release', 'create', 'build/12', '--prerelease',
  '--title', 'Title with spaces',
  '--notes', "Notes with an apostrophe: family's archive",
  '/tmp/path with spaces/dSYMs.zip'
]]
  warn 'FAIL: release creation arguments were not preserved'
  exit 1
end

retry_calls = []
ArchiveStorage.upload_dsyms(
  tag: 'v2.0.0',
  prerelease: false,
  title: 'FamilyFoqos',
  notes: 'Retry',
  asset: '/tmp/dSYMs.zip'
) do |args|
  retry_calls << args
  raise 'release exists' if retry_calls.length == 1
end

unless retry_calls == [
  [
    'gh', 'release', 'create', 'v2.0.0',
    '--title', 'FamilyFoqos',
    '--notes', 'Retry',
    '/tmp/dSYMs.zip'
  ],
  ['gh', 'release', 'upload', 'v2.0.0', '/tmp/dSYMs.zip', '--clobber']
]
  warn 'FAIL: existing release did not fall back to upload --clobber'
  exit 1
end

puts 'PASS: direct dSYM preparation and GitHub retry are recoverable'
