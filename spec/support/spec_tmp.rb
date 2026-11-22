require 'fileutils'
require 'tmpdir'

# Temporary files for specs, isolated so that several spec processes can run
# at once and each run starts from empty directories.
#
# Each spec process gets a randomly named directory under Dir.tmpdir, removed
# when the process exits (set KEEP_SPEC_TMP=1 to keep it and print its path).
# Within it, each example (or before(:all) block) gets its own empty
# directory the first time it calls #tmp_path.
module SpecTmp
  # A new empty directory under +parent+ named +prefix+ and digits only.
  # Dir.mktmpdir's random suffix has letters, and code that reads meaning
  # from folder names saw words in it: LoopInfo, which reads three folders
  # above a file, took a temp folder for a one-shot's ("...-fx3k...", "hit",
  # "sd") about one run in thirty (sample_acid_spec, fixes-18).
  def self.mkdir_digits(parent, prefix)
    loop do
      path = File.join(parent, "#{prefix}#{Process.pid}-#{rand(10**12)}")
      Dir.mkdir(path, 0o700)
      return path
    rescue Errno::EEXIST
      next
    end
  end

  ROOT = mkdir_digits(Dir.tmpdir, 'mb-sound-spec-')

  owner = Process.pid
  at_exit do
    # Forked children inherit at_exit blocks; only the creator cleans up.
    next unless Process.pid == owner

    if ENV['KEEP_SPEC_TMP'] == '1'
      warn "Spec temporary files kept in #{ROOT}"
    else
      FileUtils.remove_entry(ROOT, true)
    end
  end

  # Returns a path for +name+ in an empty directory unique to the current
  # example, creating the directory on first use.  In a before(:all) block
  # the directory is shared by the group's examples (RSpec copies the
  # instance variable into each example).
  def tmp_path(name)
    @spec_tmp_dir ||= SpecTmp.mkdir_digits(ROOT, 'ex-')
    File.join(@spec_tmp_dir, name)
  end
end

RSpec.configure do |config|
  config.include SpecTmp
end
