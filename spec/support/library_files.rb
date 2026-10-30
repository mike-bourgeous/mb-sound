# Loads every lib/mb/sound file for guards that look at every class or
# kernel (node traits, the graph sweep's class guard, the kernels guard).
# Files whose loading changes the process are left out, each with its
# reason; a guard spec here fails a new lib/ file that does so without being
# listed (2026-10-30: requiring mb/sound/dsl from node_traits_spec extended
# the spec process's top-level object, so bin/plot_noise.rb's own top-level
# `take` lost to the DSL's forwarder in a later fork_script example).
module LibraryFiles
  ROOT = File.expand_path('..', __dir__)
  LIB = File.join(File.dirname(ROOT), 'lib')

  # Files not to require, with why.
  SKIP = {
    'mb/sound/dsl.rb' => 'requiring it extends the top-level object with the console commands (the plain-song-file DSL)',
    'mb/sound/filter/four_pole/make_tuning.rb' => 'a generator script that writes the tuning tables when run',
  }.freeze

  # Every lib/mb/sound file except SKIP, sorted.
  def self.paths
    Dir[File.join(LIB, 'mb/sound/**/*.rb')].sort.reject { |f| SKIP.key?(f.delete_prefix("#{LIB}/")) }
  end

  # Requires every file of .paths.
  def self.require_all
    paths.each { |f| require f }
  end
end
