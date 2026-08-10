# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'tmpdir'

helper_path = File.expand_path('../fastlane/asc_credentials.rb', __dir__)
unless File.exist?(helper_path)
  warn 'FAIL: fastlane/asc_credentials.rb is missing'
  exit 1
end

require helper_path

def assert(condition, message)
  return if condition

  warn "FAIL: #{message}"
  exit 1
end

def assert_deleted_after_failure
  yielded_path = nil
  begin
    yield(->(path) { yielded_path = path })
    assert(false, 'injected tempfile failure did not propagate')
  rescue RuntimeError => e
    raise unless e.message == 'injected failure'
  end
  assert(!File.exist?(yielded_path), "failed tempfile block left #{yielded_path}")
end

raw_pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem
encoded = Base64.strict_encode64(raw_pem)
assert(ASCCredentials.decode_private_key(encoded) == raw_pem, 'strict decode changed the key')

[
  'not base64!',
  Base64.strict_encode64('decoded, but not a key')
].each do |invalid_value|
  ASCCredentials.decode_private_key(invalid_value)
  assert(false, 'invalid encoded key material must fail closed')
rescue ASCCredentials::CredentialError => e
  assert(!e.message.include?(invalid_value), 'decode error exposed input material')
end

private_path = nil
ASCCredentials.with_private_key_tempfile(raw_pem) do |path|
  private_path = path
  assert(File.exist?(path), 'private-key tempfile was not created')
  assert((File.stat(path).mode & 0o777) == 0o600, 'private-key tempfile mode is not 0600')
  assert(File.binread(path) == raw_pem, 'private-key tempfile content changed')
  assert(
    File.expand_path(path).start_with?("#{File.expand_path(Dir.tmpdir)}/"),
    'private-key tempfile is outside TMPDIR'
  )
end
assert(!File.exist?(private_path), 'successful private-key block left its tempfile')

assert_deleted_after_failure do |capture|
  ASCCredentials.with_private_key_tempfile(raw_pem) do |path|
    capture.call(path)
    raise 'injected failure'
  end
end

api_key = {
  key_id: 'NEWKEY1234',
  issuer_id: 'issuer-for-test',
  key: raw_pem
}
json_path = nil
ASCCredentials.with_api_key_json_tempfile(api_key) do |path|
  json_path = path
  assert(File.exist?(path), 'API-key JSON tempfile was not created')
  assert((File.stat(path).mode & 0o777) == 0o600, 'API-key JSON tempfile mode is not 0600')
  assert(
    JSON.parse(File.binread(path)) == {
      'key_id' => 'NEWKEY1234',
      'issuer_id' => 'issuer-for-test',
      'key' => raw_pem
    },
    'API-key JSON tempfile did not preserve the hash'
  )
  assert(
    File.expand_path(path).start_with?("#{File.expand_path(Dir.tmpdir)}/"),
    'API-key JSON tempfile is outside TMPDIR'
  )
end
assert(!File.exist?(json_path), 'successful API-key JSON block left its tempfile')

assert_deleted_after_failure do |capture|
  ASCCredentials.with_api_key_json_tempfile(api_key) do |path|
    capture.call(path)
    raise 'injected failure'
  end
end

puts 'PASS: ASC credential decode and tempfile lifecycle'
