require 'mkmf'

# This require line ensures that the narray gem spec is loaded when installing this extension
require 'numo/narray'

# Used numo-pocketfft as a reference for finding narray.h
# https://github.com/yoshoku/numo-pocketfft/blob/1ab489b165d4cde06b6d3a443ed9bfbc8e5c69d0/ext/numo/pocketfft/extconf.rb
# https://stackoverflow.com/questions/9322078/programmatically-determine-gems-path-using-bundler
#
# Documented here: https://stackoverflow.com/questions/45924206/ruby-native-extension-use-other-c-extension-gem/79952482#79952482
na = Gem.loaded_specs['numo-narray-alt'] || Gem.loaded_specs['numo-narray']
raise "Could not find the numo-narray Gem; try running with Bundler" if na.nil?

extdir = na.extension_dir
raise "Could not find narray.h under #{extdir}" unless find_header('numo/narray.h', File.join(extdir, 'numo'))

with_cflags("#{$CFLAGS} -O3 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=c99 -D_XOPEN_SOURCE -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/fast_sound')
end
