# frozen_string_literal: true

require 'fileutils'

module ArchiveStorage
  def self.create_dsym_zip(archive:, destination:)
    source = File.join(archive, 'dSYMs')
    raise ArgumentError, "Archive dSYMs not found: #{source}" unless File.directory?(source)

    FileUtils.rm_f(destination)
    yield(source, destination)
    raise "dSYM zip was not created: #{destination}" unless File.file?(destination)

    destination
  end

  def self.upload_dsyms(tag:, prerelease:, title:, notes:, asset:)
    create_args = ['gh', 'release', 'create', tag]
    create_args << '--prerelease' if prerelease
    create_args += ['--title', title, '--notes', notes, asset]

    begin
      yield(create_args)
    rescue StandardError
      yield(['gh', 'release', 'upload', tag, asset, '--clobber'])
    end
  end
end
