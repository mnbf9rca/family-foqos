# frozen_string_literal: true

# Runs under macOS system Ruby (/usr/bin/ruby, currently 2.6): use only 2.6-compatible APIs.
# RuboCop targets Ruby 4.0 and will not catch violations; the dual-interpreter fixture suite is the
# only guard, so run it under /usr/bin/ruby.

require 'fileutils'
require 'open3'
# Ruby 2.6 does not preload Pathname when it launches the fixture harness.
# rubocop:disable Lint/RedundantRequireStatement
require 'pathname'
# rubocop:enable Lint/RedundantRequireStatement
require 'tmpdir'

SYSTEM_RUBY = '/usr/bin/ruby'
ANALYZER_ENVIRONMENT = {
  'LANG' => nil,
  'LC_ALL' => nil,
  'LC_CTYPE' => nil
}.freeze
REPO_ROOT = Pathname(__dir__).parent.freeze
ANALYZER = REPO_ROOT.join('scripts/check-log-privacy.rb').freeze
FIXTURE_ROOT = REPO_ROOT.join('scripts/fixtures/log-privacy').freeze
PRODUCTION_ROOTS = %w[
  Foqos
  FoqosWidget
  FoqosDeviceMonitor
  FoqosShieldConfig
  Packages/FoqosShared/Sources
].freeze
FACADE_PATH = 'Packages/FoqosShared/Sources/FoqosShared/Log.swift'

Case = Struct.new(
  :name,
  :fixture,
  :status,
  :diagnostic,
  :site_floor,
  :annotation_count,
  :diagnostic_count,
  keyword_init: true
)

CASES = [
  Case.new(
    name: 'multiline display name',
    fixture: 'fail/multiline_display_name.swift',
    status: 1,
    diagnostic: 'sensitive display name',
    site_floor: 3,
    annotation_count: 0,
    diagnostic_count: 3
  ),
  Case.new(
    name: 'laundered participant identity',
    fixture: 'fail/laundered_display_info.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'same-line and line-separated reassignment',
    fixture: 'fail/reassignment.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 2,
    annotation_count: 0,
    diagnostic_count: 2
  ),
  Case.new(
    name: 'bare error',
    fixture: 'fail/bare_error.swift',
    status: 1,
    diagnostic: 'whole Error',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'raw URL',
    fixture: 'fail/raw_url.swift',
    status: 1,
    diagnostic: 'raw URL',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'coordinates',
    fixture: 'fail/coordinates.swift',
    status: 1,
    diagnostic: 'coordinate',
    site_floor: 3,
    annotation_count: 0
  ),
  Case.new(
    name: 'replayable NFC identifier',
    fixture: 'fail/nfc_identifier.swift',
    status: 1,
    diagnostic: 'replayable NFC',
    site_floor: 2,
    annotation_count: 0,
    diagnostic_count: 2
  ),
  Case.new(
    name: 'replayable QR identifier',
    fixture: 'fail/qr_identifier.swift',
    status: 1,
    diagnostic: 'replayable QR',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'participant contact properties',
    fixture: 'fail/participant_contact.swift',
    status: 1,
    diagnostic: 'participant contact',
    site_floor: 3,
    annotation_count: 0
  ),
  Case.new(
    name: 'whole member object',
    fixture: 'fail/whole_member.swift',
    status: 1,
    diagnostic: 'whole object',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'described member object',
    fixture: 'fail/string_describing_member.swift',
    status: 1,
    diagnostic: 'whole object',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'direct Logger sink',
    fixture: 'fail/logger.swift',
    status: 1,
    diagnostic: 'use the shared Log facade',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'direct os_log sink',
    fixture: 'fail/os_log.swift',
    status: 1,
    diagnostic: 'use the shared Log facade',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'direct NSLog sink',
    fixture: 'fail/nslog.swift',
    status: 1,
    diagnostic: 'use the shared Log facade',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'message variable',
    fixture: 'fail/message_variable.swift',
    status: 2,
    diagnostic: 'message must be an analyzable literal',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'unresolved suspicious origin',
    fixture: 'fail/unresolved_origin.swift',
    status: 2,
    diagnostic: 'cannot resolve suspicious origin',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'name-keyed status cannot hide participant contact',
    fixture: 'fail/name_keyed_status.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'unbalanced call',
    fixture: 'fail/unbalanced_call.swift.txt',
    status: 2,
    diagnostic: 'unbalanced Log call',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'redacted contrast',
    fixture: 'pass/redacted_contrast.swift',
    status: 0,
    diagnostic: 'sites_analyzed=3 annotations=0',
    site_floor: 3,
    annotation_count: 0
  ),
  Case.new(
    name: 'semantic allowlist',
    fixture: 'pass/semantic_allowlist.swift',
    status: 0,
    diagnostic: 'sites_analyzed=3 annotations=0',
    site_floor: 3,
    annotation_count: 0
  ),
  Case.new(
    name: 'literal-assigned locals',
    fixture: 'pass/literal_assigned_locals.swift',
    status: 0,
    diagnostic: 'sites_analyzed=4 annotations=0',
    site_floor: 4,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed literal-assigned locals',
    fixture: 'pass/renamed/literal_assigned_locals.swift',
    status: 0,
    diagnostic: 'sites_analyzed=4 annotations=0',
    site_floor: 4,
    annotation_count: 0
  ),
  Case.new(
    name: 'presentation display-name domains',
    fixture: 'pass/presentation_display_names.swift',
    status: 0,
    diagnostic: 'sites_analyzed=6 annotations=0',
    site_floor: 6,
    annotation_count: 0
  ),
  Case.new(
    name: 'literal concatenated with safe expression',
    fixture: 'pass/literal_plus_safe_expression.swift',
    status: 0,
    diagnostic: 'sites_analyzed=1 annotations=0',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'pre-redacted local identifier',
    fixture: 'pass/redacted_local.swift',
    status: 0,
    diagnostic: 'sites_analyzed=1 annotations=0',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'display name outside a sink',
    fixture: 'pass/roster_display_name.swift',
    status: 0,
    diagnostic: 'sites_analyzed=0 annotations=0',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'facade os_log sink',
    fixture: 'pass/facade_os_log.swift',
    status: 0,
    diagnostic: 'sites_analyzed=0 annotations=0',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'static previews remain covered',
    fixture: 'pass/static_previews.swift',
    status: 0,
    diagnostic: 'sites_analyzed=4 annotations=0',
    site_floor: 4,
    annotation_count: 0
  ),
  Case.new(
    name: 'lexer skips comments and string contents',
    fixture: 'pass/lexer_boundaries.swift',
    status: 0,
    diagnostic: 'sites_analyzed=2 annotations=0',
    site_floor: 2,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed multiline display name',
    fixture: 'fail/renamed/multiline_display_name.swift',
    status: 1,
    diagnostic: 'sensitive display name',
    site_floor: 3,
    annotation_count: 0,
    diagnostic_count: 3
  ),
  Case.new(
    name: 'renamed laundered participant identity',
    fixture: 'fail/renamed/laundered_display_info.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed same-line and line-separated reassignment',
    fixture: 'fail/renamed/reassignment.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 2,
    annotation_count: 0,
    diagnostic_count: 2
  ),
  Case.new(
    name: 'renamed bare error',
    fixture: 'fail/renamed/bare_error.swift',
    status: 1,
    diagnostic: 'whole Error',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed raw URL',
    fixture: 'fail/renamed/raw_url.swift',
    status: 1,
    diagnostic: 'raw URL',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed coordinates',
    fixture: 'fail/renamed/coordinates.swift',
    status: 1,
    diagnostic: 'coordinate',
    site_floor: 3,
    annotation_count: 0,
    diagnostic_count: 3
  ),
  Case.new(
    name: 'renamed replayable NFC identifier',
    fixture: 'fail/renamed/nfc_identifier.swift',
    status: 1,
    diagnostic: 'replayable NFC',
    site_floor: 2,
    annotation_count: 0,
    diagnostic_count: 2
  ),
  Case.new(
    name: 'renamed replayable QR identifier',
    fixture: 'fail/renamed/qr_identifier.swift',
    status: 1,
    diagnostic: 'replayable QR',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed participant contact properties',
    fixture: 'fail/renamed/participant_contact.swift',
    status: 1,
    diagnostic: 'participant contact',
    site_floor: 3,
    annotation_count: 0,
    diagnostic_count: 3
  ),
  Case.new(
    name: 'renamed whole member object',
    fixture: 'fail/renamed/whole_member.swift',
    status: 1,
    diagnostic: 'whole object',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed described member object',
    fixture: 'fail/renamed/string_describing_member.swift',
    status: 1,
    diagnostic: 'whole object',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed direct Logger sink',
    fixture: 'fail/renamed/logger.swift',
    status: 1,
    diagnostic: 'use the shared Log facade',
    site_floor: 0,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed message variable',
    fixture: 'fail/renamed/message_variable.swift',
    status: 2,
    diagnostic: 'message must be an analyzable literal',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed unresolved origin',
    fixture: 'fail/renamed/unresolved_origin.swift',
    status: 2,
    diagnostic: 'cannot resolve',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed local cannot hide participant contact',
    fixture: 'fail/renamed/name_keyed_status.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed valid annotation',
    fixture: 'fail/renamed/valid_annotation.swift',
    status: 2,
    diagnostic: 'annotation count changed from 0 to 1',
    site_floor: 1,
    annotation_count: 0
  ),
  Case.new(
    name: 'renamed multihop participant identity',
    fixture: 'fail/renamed/multihop_participant_identity.swift',
    status: 1,
    diagnostic: 'sensitive local origin',
    site_floor: 1,
    annotation_count: 0
  )
].freeze

def with_fixture_root(fixture:, site_floor:, annotation_count:)
  Dir.mktmpdir('log-privacy-test-') do |directory|
    root = Pathname(directory)
    PRODUCTION_ROOTS.each { |path| FileUtils.mkdir_p(root.join(path)) }
    FileUtils.mkdir_p(root.join('scripts'))

    source = FIXTURE_ROOT.join(fixture)
    destination =
      if fixture == 'pass/facade_os_log.swift'
        root.join(FACADE_PATH)
      else
        root.join('Foqos/Fixture.swift')
      end
    FileUtils.mkdir_p(destination.dirname)
    FileUtils.cp(source, destination)
    root.join('scripts/log-privacy-baseline.txt').write("#{site_floor}\n")
    root.join('scripts/log-privacy-annotation-baseline.txt').write("#{annotation_count}\n")
    yield root, destination
  end
end

def run_analyzer(root)
  Open3.capture3(
    ANALYZER_ENVIRONMENT,
    SYSTEM_RUBY,
    ANALYZER.to_s,
    '--root',
    root.to_s
  )
end

def result_matches?(
  name:, expected_status:, diagnostic:, stdout:, stderr:, process_status:,
  diagnostic_count: nil
)
  output = stdout + stderr
  matches_diagnostic = output.include?(diagnostic)
  matches_count = diagnostic_count.nil? || output.scan(diagnostic).length == diagnostic_count
  return true if process_status.exitstatus == expected_status && matches_diagnostic && matches_count

  warn "FAIL: #{name}"
  warn "  expected status: #{expected_status}"
  warn "  actual status:   #{process_status.exitstatus}"
  warn "  expected output: #{diagnostic.inspect}"
  warn "  expected count:  #{diagnostic_count}" if diagnostic_count
  warn output.lines.map { |line| "  #{line}" }.join
  false
end

def run_case?(test_case)
  with_fixture_root(
    fixture: test_case.fixture,
    site_floor: test_case.site_floor,
    annotation_count: test_case.annotation_count
  ) do |root, _destination|
    stdout, stderr, process_status = run_analyzer(root)
    return result_matches?(
      name: test_case.name,
      expected_status: test_case.status,
      diagnostic: test_case.diagnostic,
      stdout: stdout,
      stderr: stderr,
      process_status: process_status,
      diagnostic_count: test_case.diagnostic_count
    )
  end
  true
end

unless ANALYZER.file?
  warn "FAIL: analyzer is missing: #{ANALYZER}"
  exit 1
end

failures = CASES.count { |test_case| run_case?(test_case) == false }

with_fixture_root(fixture: 'pass/roster_display_name.swift', site_floor: 0, annotation_count: 0) do |root, _|
  FileUtils.rm_rf(root.join('FoqosWidget'))
  stdout, stderr, status = run_analyzer(root)
  failures += 1 unless result_matches?(
    name: 'missing production root',
    expected_status: 2,
    diagnostic: 'missing production root',
    stdout: stdout,
    stderr: stderr,
    process_status: status
  )
end

with_fixture_root(fixture: 'pass/roster_display_name.swift', site_floor: 0, annotation_count: 0) do |root, _|
  FileUtils.cp(
    FIXTURE_ROOT.join('baselines/malformed.txt'),
    root.join('scripts/log-privacy-baseline.txt')
  )
  stdout, stderr, status = run_analyzer(root)
  failures += 1 unless result_matches?(
    name: 'malformed site baseline',
    expected_status: 2,
    diagnostic: 'malformed site baseline',
    stdout: stdout,
    stderr: stderr,
    process_status: status
  )
end

with_fixture_root(fixture: 'pass/roster_display_name.swift', site_floor: 0, annotation_count: 0) do |root, _|
  FileUtils.cp(
    FIXTURE_ROOT.join('baselines/malformed.txt'),
    root.join('scripts/log-privacy-annotation-baseline.txt')
  )
  stdout, stderr, status = run_analyzer(root)
  failures += 1 unless result_matches?(
    name: 'malformed annotation baseline',
    expected_status: 2,
    diagnostic: 'malformed annotation baseline',
    stdout: stdout,
    stderr: stderr,
    process_status: status
  )
end

with_fixture_root(fixture: 'pass/redacted_contrast.swift', site_floor: 4, annotation_count: 0) do |root, _|
  stdout, stderr, status = run_analyzer(root)
  failures += 1 unless result_matches?(
    name: 'site coverage floor',
    expected_status: 2,
    diagnostic: 'coverage shrank from 4 to 3',
    stdout: stdout,
    stderr: stderr,
    process_status: status
  )
end

with_fixture_root(fixture: 'fail/valid_annotation.swift', site_floor: 1, annotation_count: 0) do |root, _|
  stdout, stderr, status = run_analyzer(root)
  failures += 1 unless result_matches?(
    name: 'annotation exact count',
    expected_status: 2,
    diagnostic: 'annotation count changed from 0 to 1',
    stdout: stdout,
    stderr: stderr,
    process_status: status
  )
end

with_fixture_root(fixture: 'pass/roster_display_name.swift', site_floor: 0, annotation_count: 0) do |root, destination|
  destination.chmod(0o000)
  begin
    stdout, stderr, status = run_analyzer(root)
    failures += 1 unless result_matches?(
      name: 'unreadable discovered file',
      expected_status: 2,
      diagnostic: 'numeric baselines cannot repair file coverage',
      stdout: stdout,
      stderr: stderr,
      process_status: status
    )
  ensure
    destination.chmod(0o600)
  end
end

if failures.positive?
  warn "FAIL: #{failures} log privacy lint test(s) failed"
  exit 1
end

puts "PASS: #{CASES.length + 6} log privacy lint cases"
