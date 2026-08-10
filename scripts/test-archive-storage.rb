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
  source = File.join(root, 'source.xcarchive')
  destination = File.join(root, 'stored.xcarchive')
  FileUtils.mkdir_p(source)
  FileUtils.mkdir_p(destination)
  File.write(File.join(source, 'marker'), 'new')
  File.write(File.join(destination, 'marker'), 'old')
  FileUtils.mkdir_p("#{destination}.tmp-stale")
  FileUtils.mkdir_p("#{destination}.backup-stale")

  messages = []
  ArchiveStorage.replace_directory(
    source: source,
    destination: destination,
    logger: ->(message) { messages << message }
  )

  unless File.read(File.join(destination, 'marker')) == 'new'
    warn 'FAIL: completed copy did not replace the destination'
    exit 1
  end
  unless messages.length == 1 && messages.first.include?("#{destination}.backup-")
    warn 'FAIL: archive replacement did not log the created backup path'
    exit 1
  end
  unless Dir.glob("#{destination}.{tmp,backup}-*").empty?
    warn 'FAIL: successful replacement left temporary or backup directories'
    exit 1
  end

  File.write(File.join(destination, 'marker'), 'known-good')
  begin
    ArchiveStorage.replace_directory(
      source: File.join(root, 'missing.xcarchive'),
      destination: destination
    )
    warn 'FAIL: missing source should raise'
    exit 1
  rescue Errno::ENOENT
    # Expected: copying fails before the known-good destination is moved.
  end

  unless File.read(File.join(destination, 'marker')) == 'known-good'
    warn 'FAIL: failed replacement damaged the known-good destination'
    exit 1
  end

  rename = File.method(:rename)
  rename_count = 0
  File.define_singleton_method(:rename) do |source_path, destination_path|
    rename_count += 1
    raise Errno::EIO if rename_count == 2

    rename.call(source_path, destination_path)
  end
  begin
    ArchiveStorage.replace_directory(source: source, destination: destination)
    warn 'FAIL: simulated swap failure should raise'
    exit 1
  rescue Errno::EIO
    # Expected: the completed temporary copy fails to swap after backup creation.
  ensure
    File.define_singleton_method(:rename, rename)
  end

  unless File.read(File.join(destination, 'marker')) == 'known-good'
    warn 'FAIL: swap failure did not restore the known-good backup'
    exit 1
  end

  rename_count = 0
  File.define_singleton_method(:rename) do |source_path, destination_path|
    rename_count += 1
    raise Interrupt if rename_count == 2

    rename.call(source_path, destination_path)
  end
  begin
    ArchiveStorage.replace_directory(source: source, destination: destination)
    warn 'FAIL: simulated interrupt should raise'
    exit 1
  rescue Interrupt
    # Expected: Ctrl-C lands after backup creation but before the new archive swap.
  ensure
    File.define_singleton_method(:rename, rename)
  end

  unless File.exist?(destination) && File.read(File.join(destination, 'marker')) == 'known-good'
    warn 'FAIL: interrupt did not restore the known-good backup to the expected path'
    exit 1
  end

  interrupt_messages = []
  rename_count = 0
  File.define_singleton_method(:rename) do |source_path, destination_path|
    rename_count += 1
    rename.call(source_path, destination_path)
    raise Interrupt if rename_count == 1
  end
  begin
    ArchiveStorage.replace_directory(
      source: source,
      destination: destination,
      logger: ->(message) { interrupt_messages << message }
    )
    warn 'FAIL: interrupt immediately after backup rename should raise'
    exit 1
  rescue Interrupt
    # Expected: Ctrl-C lands after the destination moved but before the call returns.
  ensure
    File.define_singleton_method(:rename, rename)
  end

  unless File.exist?(destination) && File.read(File.join(destination, 'marker')) == 'known-good'
    warn 'FAIL: post-rename interrupt did not restore the known-good backup'
    exit 1
  end
  unless interrupt_messages.any? { |message| message.include?("#{destination}.backup-") }
    warn 'FAIL: post-rename interrupt did not report the backup path'
    exit 1
  end

  FileUtils.rm_rf(destination)
  stale_backup = "#{destination}.backup-stale-recovery"
  FileUtils.mkdir_p(stale_backup)
  File.write(File.join(stale_backup, 'marker'), 'recoverable')
  recovery_messages = []
  begin
    ArchiveStorage.replace_directory(
      source: File.join(root, 'still-missing.xcarchive'),
      destination: destination,
      logger: ->(message) { recovery_messages << message }
    )
    warn 'FAIL: missing replacement source should raise after stale-backup recovery'
    exit 1
  rescue Errno::ENOENT
    # Expected: replacement fails, but the stale known-good backup must survive.
  end

  unless File.exist?(destination) && File.read(File.join(destination, 'marker')) == 'recoverable'
    warn 'FAIL: stale backup was not recovered before the failed replacement'
    exit 1
  end
  unless recovery_messages.any? { |message| message.include?(stale_backup) }
    warn 'FAIL: stale-backup recovery did not report the discovered path'
    exit 1
  end

  copy = FileUtils.method(:cp_r)
  FileUtils.define_singleton_method(:cp_r) do |_source_path, destination_path|
    FileUtils.mkdir_p(destination_path)
    File.write(File.join(destination_path, 'partial'), 'incomplete')
    raise Interrupt
  end
  begin
    ArchiveStorage.replace_directory(source: source, destination: destination)
    warn 'FAIL: interrupt during archive copy should raise'
    exit 1
  rescue Interrupt
    # Expected: a partial temporary copy exists, but no complete copy has moved.
  ensure
    FileUtils.define_singleton_method(:cp_r, copy)
  end

  unless File.read(File.join(source, 'marker')) == 'new' &&
         File.read(File.join(destination, 'marker')) == 'recoverable'
    warn 'FAIL: copy interrupt damaged a complete source or stored archive'
    exit 1
  end
  unless Dir.glob("#{destination}.tmp-*").empty?
    warn 'FAIL: copy interrupt left a partial temporary archive'
    exit 1
  end

  rename_count = 0
  File.define_singleton_method(:rename) do |_source_path, _destination_path|
    rename_count += 1
    raise Interrupt if rename_count == 1
  end
  begin
    ArchiveStorage.replace_directory(source: source, destination: destination)
    warn 'FAIL: interrupt before the first rename should raise'
    exit 1
  rescue Interrupt
    # Expected: the completed temporary copy never displaces the stored archive.
  ensure
    File.define_singleton_method(:rename, rename)
  end

  unless File.read(File.join(source, 'marker')) == 'new' &&
         File.read(File.join(destination, 'marker')) == 'recoverable'
    warn 'FAIL: pre-rename interrupt damaged a complete source or stored archive'
    exit 1
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

puts 'PASS: archive replacement and GitHub retry are recoverable'
