require 'mkmf'

# mb_term_grid.h (shared with extensions that draw into grids directly)
$INCFLAGS << " -I#{File.expand_path('../include', __dir__)}"

# -ffp-contract=off as in mb-sound's extensions (no floating point here
# today; specs compare every method with MB::Term::Cells for exact equality)
with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -ffp-contract=off -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/term/fast_term')
end
