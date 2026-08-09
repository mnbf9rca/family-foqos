require "fileutils"
require "securerandom"

module ArchiveStorage
  def self.replace_directory(source:, destination:, logger: ->(message) { warn(message) })
    Dir.glob("#{destination}.tmp-*").each { |path| FileUtils.rm_rf(path) }
    stale_backups = Dir.glob("#{destination}.backup-*")
    if !File.exist?(destination) && !stale_backups.empty?
      recovery = stale_backups.max_by { |path| [File.mtime(path), path] }
      File.rename(recovery, destination)
      logger.call("Archive backup recovered: #{recovery}")
    end
    stale_backups.each { |path| FileUtils.rm_rf(path) } if File.exist?(destination)

    suffix = "#{Process.pid}-#{SecureRandom.hex(6)}"
    temporary = "#{destination}.tmp-#{suffix}"
    backup = "#{destination}.backup-#{suffix}"

    begin
      FileUtils.cp_r(source, temporary)
      if File.exist?(destination)
        File.rename(destination, backup)
        logger.call("Archive backup created: #{backup}")
      end
      File.rename(temporary, destination)
      FileUtils.rm_rf(backup)
    rescue Exception
      if File.exist?(backup) && !File.exist?(destination)
        File.rename(backup, destination)
        logger.call("Archive backup restored: #{backup}")
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
