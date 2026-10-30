# Stops a spec run that would load C extensions older than their sources
# (test-infra-1, 2026-10-30): a stale `.so` loads fine and fails specs for
# C changes it doesn't have (9 false failures after a merge on 2026-10-29,
# a broken build passing on 2026-10-06).  The rake spec tasks compile first;
# this covers plain `bundle exec rspec`.  An extension is stale when a file
# in its ext/ directory, or a shared header its depend file lists, is newer
# than its built library, or the library is missing.
# MB_SOUND_STALE_EXT=run runs anyway.
require 'rbconfig'

module StaleExtensions
  ROOT = File.expand_path('../..', __dir__)

  module_function

  # The extension directories (each holding an extconf.rb).
  def ext_dirs(root = ROOT)
    Dir[File.join(root, '{ext,gems/*/ext}/**/extconf.rb')].map { |f| File.dirname(f) }.sort
  end

  # The built library for an extension directory: .../ext/mb/sound/fast_x
  # -> .../lib/mb/sound/fast_x.so (fast_sound in lib/mb, mb-term's in its gem).
  def library(dir)
    dir.sub(%r{/ext/(mb/.*)\z}) { "/lib/#{$1}.#{RbConfig::CONFIG['DLEXT']}" }
  end

  # The files an extension's build reads: its own directory's files and the
  # headers outside it that its depend file lists.
  def inputs(dir)
    own = Dir[File.join(dir, '**', '*')].select { |f| File.file?(f) }
    depend = File.join(dir, 'depend')
    shared = File.exist?(depend) ? File.read(depend).scan(%r{\$\(srcdir\)/(\S+)}).flatten.map { |p| File.expand_path(p, dir) } : []
    (own + shared).uniq.select { |f| File.exist?(f) }
  end

  # [[library, reason], ...] for missing or stale libraries.
  def problems(root = ROOT)
    ext_dirs(root).filter_map do |dir|
      lib = library(dir)
      rel = lib.delete_prefix("#{root}/")
      next [rel, 'not built'] unless File.exist?(lib)

      built = File.mtime(lib)
      newer = inputs(dir).select { |f| File.mtime(f) > built }
      next if newer.empty?

      [rel, "older than #{newer.map { |f| f.delete_prefix("#{root}/") }.first(3).join(', ')}#{newer.length > 3 ? " and #{newer.length - 3} more" : ''}"]
    end
  end

  def check!(root = ROOT)
    return if ENV['MB_SOUND_STALE_EXT'] == 'run'

    found = problems(root)
    return if found.empty?

    abort "spec_helper: #{found.length} C extension#{found.length == 1 ? ' is' : 's are'} out of date; " \
          "run `bundle exec rake -f Rakefile compile` first (MB_SOUND_STALE_EXT=run runs anyway):\n" +
          found.first(10).map { |l, why| "  #{l}: #{why}" }.join("\n") + (found.length > 10 ? "\n  and #{found.length - 10} more" : '')
  end
end
