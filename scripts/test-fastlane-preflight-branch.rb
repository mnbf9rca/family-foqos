# frozen_string_literal: true

require File.expand_path('../fastlane/preflight_branch', __dir__)

cases = [
  { current: nil, allowed: nil, expected: :enforce_main },
  { current: '', allowed: '', expected: :enforce_main },
  { current: 'HEAD', allowed: 'HEAD', expected: :enforce_main },
  { current: 'main', allowed: nil, expected: :enforce_main },
  { current: 'feature/schema', allowed: nil, expected: :enforce_main },
  { current: 'feature/schema', allowed: 'other', expected: :enforce_main },
  { current: 'feature/schema', allowed: 'feature/schema', expected: :verification }
]

cases.each do |test_case|
  actual = PreflightBranch.mode(
    current_branch: test_case.fetch(:current),
    allowed_branch: test_case.fetch(:allowed)
  )
  next if actual == test_case.fetch(:expected)

  warn "FAIL: #{test_case.inspect} produced #{actual.inspect}"
  exit 1
end

puts 'PASS: Fastlane preflight branch override requires an exact current-branch match'
