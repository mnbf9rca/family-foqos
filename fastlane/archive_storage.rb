require "fileutils"
require "securerandom"

module ArchiveStorage
  def self.replace_directory(source:, destination:, logger: ->(message) { warn(message) })
    Dir.glob("#{destination}.{tmp,backup}-*").each { |path| FileUtils.rm_rf(path) }

    suffix = "#{Process.pid}-#{SecureRandom.hex(6)}"
    temporary = "#{destination}.tmp-#{suffix}"
    backup = "#{destination}.backup-#{suffix}"
    backup_created = false

    begin
      FileUtils.cp_r(source, temporary)
      if File.exist?(destination)
        File.rename(destination, backup)
        backup_created = true
        logger.call("Archive backup created: #{backup}")
      end
      File.rename(temporary, destination)
      FileUtils.rm_rf(backup) if backup_created
    rescue Exception
      if backup_created && File.exist?(backup) && !File.exist?(destination)
        File.rename(backup, destination)
      end
      raise
    ensure
      FileUtils.rm_rf(temporary)
    end
  end

  def self.upload_dsyms(tag:, prerelease:, title:, notes:, asset:)
    create_args = ["gh", "release", "create", tag]
    create_args << "--prerelease" if prerelease
    create_args += ["--title", title, "--notes", notes, asset]

    begin
      yield(create_args)
    rescue
      yield(["gh", "release", "upload", tag, asset, "--clobber"])
    end
  end
end
