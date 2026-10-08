require 'mkmf'

# This require line ensures that the narray gem spec is loaded when installing this extension
require 'numo/narray'

na = Gem.loaded_specs['numo-narray-alt'] || Gem.loaded_specs['numo-narray']
raise "Could not find the numo-narray Gem; try running with Bundler" if na.nil?
raise 'Could not find narray.h' unless find_header('numo/narray.h', File.join(na.extension_dir, 'numo'))

# Helpers and kernels shared with the other purpose-specific extensions
$INCFLAGS << " -I#{File.expand_path('../include', __dir__)}"

# The same flags as fast_sound and fast_synth (no -ffp-contract option), so
# the oscillator kernels shared through mb_osc_shapes.h and mb_bl_osc.h
# compile to the same arithmetic as theirs on every compiler.  The
# arithmetic ops write each product and sum as its own statement, so no
# compiler may contract them into FMAs either way (matching fast_arithmetic,
# which is built with -ffp-contract=off).
with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/sound/fast_plan')
end
