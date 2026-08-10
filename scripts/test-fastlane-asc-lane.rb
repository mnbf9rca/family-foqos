# frozen_string_literal: true

require 'base64'
require 'open3'
require 'openssl'

repo_root = File.expand_path('..', __dir__)
raw_pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem
encoded = Base64.strict_encode64(raw_pem)
key_id = 'TSTKEY1234'
issuer_id = '11111111-2222-3333-4444-555555555555'

def redacted(output, secrets)
  secrets.reduce(output) { |text, secret| text.gsub(secret, '[REDACTED]') }
end

env = {
  'ASC_KEY_ID' => key_id,
  'ASC_ISSUER_ID' => issuer_id,
  'ASC_KEY_CONTENT_BASE64' => encoded,
  'FASTLANE_SKIP_UPDATE_CHECK' => '1'
}
stdout, stderr, status = Open3.capture3(
  env,
  'bundle', 'exec', 'fastlane', 'check_asc_key',
  chdir: repo_root
)
output = stdout + stderr
unless status.success?
  warn 'FAIL: namespaced in-memory ASC key did not load'
  warn redacted(output, [raw_pem, encoded, issuer_id])
  exit 1
end

unless output.include?("key_id=#{key_id}") &&
       output.include?('issuer_present=true') &&
       output.include?('key_present=true')
  warn 'FAIL: check_asc_key did not report the approved non-secret facts'
  exit 1
end
if output.include?(raw_pem) || output.include?(encoded) || output.include?(issuer_id)
  warn 'FAIL: check_asc_key output exposed key or issuer material'
  exit 1
end

legacy_env_path = File.join(repo_root, 'fastlane', '.env')
created_legacy_fixture = false
begin
  unless File.exist?(legacy_env_path)
    File.open(legacy_env_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      created_legacy_fixture = true
      file.puts('ASC_KEY_ID=LEGACYTEST')
      file.puts('ASC_ISSUER_ID=legacy-issuer-for-test')
      file.puts('ASC_KEY_PATH=/tmp/deleted-legacy-key.p8')
    end
  end

  bare_env = {
    'ASC_KEY_ID' => nil,
    'ASC_ISSUER_ID' => nil,
    'ASC_KEY_CONTENT_BASE64' => nil,
    'FASTLANE_SKIP_UPDATE_CHECK' => '1'
  }
  bare_stdout, bare_stderr, bare_status = Open3.capture3(
    bare_env,
    'bundle', 'exec', 'fastlane', 'check_asc_key',
    chdir: repo_root
  )
  bare_output = bare_stdout + bare_stderr
ensure
  File.delete(legacy_env_path) if created_legacy_fixture && File.exist?(legacy_env_path)
end

if bare_status.success? || !bare_output.include?('ASC_KEY_CONTENT_BASE64')
  warn 'FAIL: legacy .env must not let bare check_asc_key bypass the namespaced key-content fetch'
  warn redacted(bare_output, [raw_pem, encoded, issuer_id])
  exit 1
end

puts 'PASS: check_asc_key uses namespaced in-memory credentials and fails closed when bare'
