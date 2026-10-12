require 'mkmf'

# FastRecipe: graph recipe support that needs the VM's debug inspector API
# (see MB::Sound::GraphNode::Recipe.trace_locals).  No numeric kernels, so
# no narray headers or -ffp-contract flags.
have_header('ruby/debug.h') or raise 'ruby/debug.h is required'

with_cflags("#{$CFLAGS} -O2 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/sound/fast_recipe')
end
