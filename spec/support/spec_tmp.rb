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
  ROOT = Dir.mktmpdir('mb-sound-spec-')

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
    @spec_tmp_dir ||= Dir.mktmpdir('ex-', ROOT)
    File.join(@spec_tmp_dir, name)
  end
end

RSpec.configure do |config|
  config.include SpecTmp
end
