require 'mkmf'

# This require line ensures that the narray gem spec is loaded when installing this extension
require 'numo/narray'

# Used numo-pocketfft as a reference for finding narray.h
# https://github.com/yoshoku/numo-pocketfft/blob/1ab489b165d4cde06b6d3a443ed9bfbc8e5c69d0/ext/numo/pocketfft/extconf.rb
# https://stackoverflow.com/questions/9322078/programmatically-determine-gems-path-using-bundler
na = Gem.loaded_specs['numo-narray']
raise "Could not find the numo-narray Gem; try running with Bundler" if na.nil?
raise 'Could not find narray.h' unless find_header('numo/narray.h', File.join(na.extension_dir, 'numo'))

with_cflags("#{$CFLAGS} -O3 -Wall -Wextra #{ENV['EXTRACFLAGS']} -std=c99 -D_XOPEN_SOURCE=700 -D_ISOC99_SOURCE -D_GNU_SOURCE") do
  create_makefile('mb/fast_sound')
end
