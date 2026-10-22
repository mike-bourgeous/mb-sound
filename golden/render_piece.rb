# Renders one block piece of the golden set (golden/set.rb) to a file, in a
# process of its own (rake golden:check runs it; script pieces run their
# scripts instead):
#   bundle exec ruby -Ilib golden/render_piece.rb NAME OUT.flac
require 'mb/sound/sound_guard'

name, out = ARGV
abort 'usage: golden/render_piece.rb NAME OUT.flac' unless name && out
set = MB::Sound::SoundGuard::GoldenSet.load
set.select([name]).first.render_here(out)
