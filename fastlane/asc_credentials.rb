require "base64"
require "json"
require "openssl"
require "tempfile"

module ASCCredentials
  class CredentialError < StandardError; end

  def self.decode_private_key(encoded)
    decoded = Base64.strict_decode64(encoded)
    OpenSSL::PKey.read(decoded)
    decoded
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    raise CredentialError, "ASC private key is not valid base64-encoded PEM"
  end

  def self.with_private_key_tempfile(raw_pem, &block)
    with_sensitive_tempfile("asc-auth-key", ".p8", raw_pem, &block)
  end

  def self.with_api_key_json_tempfile(api_key, &block)
    with_sensitive_tempfile("asc-api-key", ".json", JSON.generate(api_key), &block)
  end

  def self.with_sensitive_tempfile(basename, extension, contents)
    Tempfile.create([basename, extension]) do |file|
      file.chmod(0o600)
      file.binmode
      file.write(contents)
      file.flush
      yield file.path
    end
  end
  private_class_method :with_sensitive_tempfile
end
