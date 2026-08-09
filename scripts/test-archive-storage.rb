require "fileutils"
require "tmpdir"

helper_path = File.expand_path("../fastlane/archive_storage.rb", __dir__)
unless File.exist?(helper_path)
  warn "FAIL: fastlane/archive_storage.rb is missing"
  exit 1
end

require helper_path

unless ArchiveStorage.respond_to?(:upload_dsyms)
  warn "FAIL: ArchiveStorage.upload_dsyms is missing"
  exit 1
end

Dir.mktmpdir do |root|
  source = File.join(root, "source.xcarchive")
  destination = File.join(root, "stored.xcarchive")
  FileUtils.mkdir_p(source)
  FileUtils.mkdir_p(destination)
  File.write(File.join(source, "marker"), "new")
  File.write(File.join(destination, "marker"), "old")

  ArchiveStorage.replace_directory(source: source, destination: destination)

  unless File.read(File.join(destination, "marker")) == "new"
    warn "FAIL: completed copy did not replace the destination"
    exit 1
  end
  unless Dir.glob("#{destination}.{tmp,backup}-*").empty?
    warn "FAIL: successful replacement left temporary or backup directories"
    exit 1
  end

  File.write(File.join(destination, "marker"), "known-good")
  begin
    ArchiveStorage.replace_directory(
      source: File.join(root, "missing.xcarchive"),
      destination: destination
    )
    warn "FAIL: missing source should raise"
    exit 1
  rescue Errno::ENOENT
    # Expected: copying fails before the known-good destination is moved.
  end

  unless File.read(File.join(destination, "marker")) == "known-good"
    warn "FAIL: failed replacement damaged the known-good destination"
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
    warn "FAIL: simulated swap failure should raise"
    exit 1
  rescue Errno::EIO
    # Expected: the completed temporary copy fails to swap after backup creation.
  ensure
    File.define_singleton_method(:rename, rename)
  end

  unless File.read(File.join(destination, "marker")) == "known-good"
    warn "FAIL: swap failure did not restore the known-good backup"
    exit 1
  end
end

create_calls = []
ArchiveStorage.upload_dsyms(
  tag: "build/12",
  prerelease: true,
  title: "Title with spaces",
  notes: "Notes with an apostrophe: family's archive",
  asset: "/tmp/path with spaces/dSYMs.zip"
) { |args| create_calls << args }

unless create_calls == [[
  "gh", "release", "create", "build/12", "--prerelease",
  "--title", "Title with spaces",
  "--notes", "Notes with an apostrophe: family's archive",
  "/tmp/path with spaces/dSYMs.zip",
]]
  warn "FAIL: release creation arguments were not preserved"
  exit 1
end

retry_calls = []
ArchiveStorage.upload_dsyms(
  tag: "v2.0.0",
  prerelease: false,
  title: "FamilyFoqos",
  notes: "Retry",
  asset: "/tmp/dSYMs.zip"
) do |args|
  retry_calls << args
  raise "release exists" if retry_calls.length == 1
end

unless retry_calls == [
  [
    "gh", "release", "create", "v2.0.0",
    "--title", "FamilyFoqos",
    "--notes", "Retry",
    "/tmp/dSYMs.zip",
  ],
  ["gh", "release", "upload", "v2.0.0", "/tmp/dSYMs.zip", "--clobber"],
]
  warn "FAIL: existing release did not fall back to upload --clobber"
  exit 1
end

puts "PASS: archive replacement and GitHub retry are recoverable"
