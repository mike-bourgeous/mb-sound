require 'mkmf'

# This require line ensures that the narray gem spec is loaded when installing this extension
require 'numo/narray'

# Used numo-pocketfft as a reference for finding narray.h
# https://github.com/yoshoku/numo-pocketfft/blob/1ab489b165d4cde06b6d3a443ed9bfbc8e5c69d0/ext/numo/pocketfft/extconf.rb
# https://stackoverflow.com/questions/9322078/programmatically-determine-gems-path-using-bundler
na = Gem.loaded_specs['numo-narray-alt'] || Gem.loaded_specs['numo-narray']
raise "Could not find the numo-narray Gem; try running with Bundler" if na.nil?
raise 'Could not find narray.h' unless find_header('numo/narray.h', File.join(na.extension_dir, 'numo'))

# mb-term's grid struct (mb_term_grid.h): FastUI::Grid subclasses its native
# grid and composes plot canvases into the cells.  The installed gem's
# headers, else the copy in this repository (gems/mb-term).
term = Gem.loaded_specs['mb-term']
term_include = [term && File.join(term.full_gem_path, 'ext/mb/term/include'), File.expand_path('../../../../gems/mb-term/ext/mb/term/include', __dir__)]
  .compact.find { |d| File.file?(File.join(d, 'mb_term_grid.h')) }
raise 'Could not find mb_term_grid.h (the mb-term gem)' unless term_include
$INCFLAGS << " -I#{term_include}"

# -ffp-contract=off: specs compare the kernels with their Ruby mirrors in
# MB::Sound::Plot (Geometry.decimate_ruby, Raster#polyline_ruby,
# Text::Surface#area_ruby, Text::Cells) for exact equality, so clang (the
# default on macOS) must not fuse multiplies and adds into FMAs.
with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -ffp-contract=off -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/sound/fast_ui')
end
